#!/bin/zsh
set -euo pipefail

# Empaqueta The Transcriptor en Release y la instala en /Applications.
#
#   ./install.sh                  # compila, instala y abre la app
#   ./install.sh --no-open        # instala sin abrirla
#   ./install.sh --dest ~/Apps    # instala en otra carpeta
#
# Nota: NO se activan Hardened Runtime ni App Sandbox (ver project.yml).
# El shim de dylibs de ffmpeg depende de DYLD_LIBRARY_PATH, que dyld ignora
# con Hardened Runtime activo.

cd "$(dirname "$0")"

APP_NAME="TheTranscriptor.app"
BUNDLE_ID="com.allosa.TheTranscriptor"
DEST_DIR="/Applications"
OPEN_AFTER=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_AFTER=0; shift ;;
    --dest) DEST_DIR="${2:?--dest necesita una ruta}"; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

DEST_DIR="${DEST_DIR/#\~/$HOME}"
DEST_APP="$DEST_DIR/$APP_NAME"

if [ ! -d "$DEST_DIR" ]; then
  echo "La carpeta de destino no existe: $DEST_DIR" >&2
  exit 1
fi

# 1. Regenerar el proyecto (el .xcodeproj está gitignoreado)
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Generando el proyecto Xcode"
  xcodegen generate
elif [ ! -d "TheTranscriptor.xcodeproj" ]; then
  echo "Falta xcodegen y no hay .xcodeproj. Instálalo con: brew install xcodegen" >&2
  exit 1
else
  echo "==> xcodegen no encontrado; uso el .xcodeproj existente"
fi

# 2. Compilar en Release
echo "==> Compilando en Release"
xcodebuild -project TheTranscriptor.xcodeproj \
           -scheme TheTranscriptor \
           -configuration Release \
           build

BUILD_SETTINGS=$(xcodebuild -project TheTranscriptor.xcodeproj \
                            -scheme TheTranscriptor \
                            -configuration Release \
                            -showBuildSettings 2>/dev/null)

BUILT_DIR=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
VERSION=$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
SRC_APP="$BUILT_DIR/$APP_NAME"

if [ ! -d "$SRC_APP" ]; then
  echo "No se encontró la app compilada en: $SRC_APP" >&2
  exit 1
fi

# 3. Cerrar la copia instalada si está corriendo
if pgrep -f "$DEST_APP/Contents/MacOS/" >/dev/null 2>&1; then
  echo "==> Cerrando la instancia en ejecución"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$DEST_APP/Contents/MacOS/" >/dev/null 2>&1 || break
    /bin/sleep 0.5
  done
fi

# 4. Instalar (reemplazando la copia anterior)
if [ -e "$DEST_APP" ]; then
  if [ ! -d "$DEST_APP/Contents/MacOS" ]; then
    echo "El destino existe pero no parece un bundle de app: $DEST_APP" >&2
    echo "Bórralo a mano y vuelve a lanzar el script." >&2
    exit 1
  fi
  echo "==> Eliminando la versión anterior en $DEST_APP"
  rm -rf "$DEST_APP"
fi

echo "==> Instalando en $DEST_APP"
ditto "$SRC_APP" "$DEST_APP"

echo "==> Instalada The Transcriptor ${VERSION:-?} en $DEST_APP"

if [ "$OPEN_AFTER" -eq 1 ]; then
  open "$DEST_APP"
fi

cat <<'EOF'

Recuerda, la primera vez:
  1. Requisitos: si falla "Paquetes", usa "Configurar automáticamente"
     (crea un venv en ~/Library/Application Support/TheTranscriptor/venv)
     o apunta a tu intérprete en Ajustes → Ruta Python.
  2. Token de Hugging Face en Ajustes, aceptando las condiciones de
     pyannote/speaker-diarization-3.1 y pyannote/segmentation-3.0.
  3. Permisos: micrófono, "Grabación de audio del sistema" (modo reunión) y
     Acceso a disco completo si vas a importar de Notas de voz
     (este último exige reiniciar la app).
EOF
