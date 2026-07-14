# The Transcriptor — Especificación Funcional

**Versión:** 0.1 · **Fecha:** 2026-07-12 · **Plataforma:** macOS 14+ (Sonoma), SwiftUI

## 1. Visión

App nativa de macOS que envuelve un pipeline Python existente de transcripción
(faster-whisper) + diarización de hablantes (pyannote-audio). **Todo el
procesamiento ocurre en local**; la única excepción es la descarga inicial de
los modelos desde Hugging Face. Uso personal, fuera de la Mac App Store.

## 2. Actores y contexto

- **Usuario único** (el propietario del Mac). Sin cuentas, sin login, sin telemetría.
- **Dependencias externas del sistema:** intérprete de Python con
  `faster-whisper` y `pyannote.audio`, y `ffmpeg` en el PATH o ruta conocida.

## 3. Casos de uso

### CU-01 · Transcribir un archivo existente
1. El usuario arrastra un archivo a la ventana o pulsa "Seleccionar archivo…".
2. Formatos aceptados: `.m4a`, `.mp4`, `.mov`, `.wav` (notas de voz de iPhone,
   grabaciones de Zoom/Meet/Teams). Cualquier otro formato se rechaza con
   mensaje claro.
3. La app muestra la vista de progreso (CU-03) y lanza el pipeline.
4. Al terminar, se muestra la vista de resultado (CU-04).

**Errores:** archivo ilegible, sin audio, o pipeline fallido → pantalla de error
con la salida de stderr del script plegada bajo un disclosure ("Ver detalles").

### CU-02 · Grabar desde el micrófono
1. Botón "Grabar" en la pantalla principal. En el primer uso, macOS pide
   permiso de micrófono (descripción en `NSMicrophoneUsageDescription`).
2. Controles: **Iniciar / Pausar / Reanudar / Detener**.
3. Durante la grabación: medidor de nivel en tiempo real (barra u onda) y
   cronómetro `mm:ss`.
4. Al detener, la app guarda un WAV temporal (16 kHz mono, formato que espera
   el pipeline) y entra en el flujo de CU-01 automáticamente.
5. Si el usuario cancela la grabación, el WAV temporal se borra de inmediato.

**Errores:** permiso denegado → pantalla explicativa con botón que abre
Ajustes del Sistema → Privacidad → Micrófono.

### CU-03 · Ver progreso del procesamiento
- La app lee stdout del script en streaming y traduce sus marcas de fase a
  texto de UI: "Convirtiendo audio…", "Transcribiendo…", "Diarizando…",
  "Uniendo resultados…".
- Barra de progreso indeterminada por fase; si el script emite porcentaje,
  se muestra determinada.
- Botón **Cancelar**: termina el proceso Python (SIGTERM, luego SIGKILL a los
  5 s) y limpia temporales.
- La primera vez que se usan los modelos de pyannote, la fase de diarización
  incluye la descarga desde Hugging Face: la UI lo indica explícitamente
  ("Descargando modelos de Hugging Face — única conexión a internet de la app").

### CU-04 · Ver y editar el resultado
- Lista desplazable de segmentos: `[hh:mm:ss–hh:mm:ss] HABLANTE: texto`.
- Cada hablante (`SPEAKER_00`, `SPEAKER_01`, …) recibe automáticamente un
  color distinto y estable de una paleta predefinida (mín. 8 colores).
- **Renombrar hablante:** clic en la etiqueta → campo editable inline. El
  renombrado se aplica a todos los segmentos de ese hablante y es solo local
  (se guarda junto a la transcripción, nunca sale de la máquina).
- **Exportar:**
  - Copiar todo al portapapeles (texto plano con nombres ya aplicados).
  - Guardar como `.txt` (mismo formato que genera el script, con nombres).
  - Guardar como `.srt` (subtítulos numerados; el nombre del hablante como
    prefijo de línea: `Angel: …`).
- Botón "Nueva transcripción" vuelve a la pantalla principal.

### CU-05 · Ajustes
| Ajuste | Tipo | Valor por defecto | Almacenamiento |
|---|---|---|---|
| Modelo Whisper | selector: tiny/base/small/medium/large-v3 | `small` | UserDefaults |
| Token Hugging Face | campo seguro | vacío | **Keychain** |
| Borrar audio al terminar | interruptor | **desactivado** | UserDefaults |
| Intérprete de Python | ruta + botón "Autodetectar" y "Examinar…" | autodetectado | UserDefaults |

- El token de HF nunca se escribe en UserDefaults, logs ni texto plano; se
  pasa al proceso hijo vía variable de entorno, no como argumento (los
  argumentos son visibles en `ps`).
- Junto al selector de modelo, texto orientativo de tamaño/velocidad
  (p. ej. "large-v3: máxima calidad, ~3 GB, lento sin GPU").

### CU-06 · Comprobación de requisitos (primer arranque y bajo demanda)
Al primer arranque (y desde Ajustes → "Comprobar requisitos") la app verifica:
1. `ffmpeg` accesible (PATH o rutas típicas de Homebrew).
2. Intérprete de Python válido (ejecuta `python3 --version`).
3. Paquetes `faster_whisper` y `pyannote.audio` importables en ese intérprete.
4. Token de HF configurado (necesario para la descarga inicial de los modelos
   gated de pyannote; sin él, la diarización falla en pleno pipeline con un
   error críptico en vez de un aviso claro).

Cada requisito se muestra con ✓/✗ y, si falta, instrucciones concretas y
copiables (`brew install ffmpeg`, `pip install faster-whisper pyannote.audio`,
pasos para crear el token de HF, aceptar las condiciones de
`pyannote/speaker-diarization-3.1` y `pyannote/segmentation-3.0`, y pegarlo
en Ajustes). La app no permite iniciar una transcripción hasta que los
cuatro requisitos estén en verde, pero nunca falla silenciosamente.

### CU-07 · Indicador de privacidad
- Elemento permanente en la interfaz (pie de ventana o cabecera):
  - Estado normal: 🔒 **"Procesando 100 % en local — nada sale de este Mac"**.
  - Durante la descarga inicial de modelos: ⚠️ **"Descargando modelos desde
    Hugging Face (única conexión de red de la app)"**.
- Tooltip/popover que explica la política: el audio nunca se sube, el borrado
  automático del original, y que los renombres de hablantes son locales.

### CU-08 · Historial de transcripciones
- Cada transcripción completada se registra automáticamente en un
  historial persistente (no requiere acción del usuario) — transcripción
  completa (segmentos, idioma, duración, renombres de hablante) más
  metadatos: fichero de origen, fecha, modelo Whisper usado. **No se copia
  el audio original**: si el fichero de origen ya no existe (se borró o se
  movió), la entrada sigue disponible para consulta/exportación, solo sin
  acceso al audio.
- Se accede desde una ventana aparte ("Historial", menú o atajo de
  teclado), con lista de entradas a la izquierda y detalle a la derecha —
  mismo patrón que "Registro de depuración".
- Acciones disponibles por entrada: ver segmentos agrupados por hablante,
  renombrar hablantes (persiste inmediatamente), copiar, exportar a
  `.txt`/`.srt`, eliminar del historial, y "Mostrar en Finder" si el audio
  original todavía existe en su ruta.
- Retención configurable en Ajustes (ilimitado por defecto o purga
  automática pasados 7/30/90/365 días).

## 4. Requisitos no funcionales

- **Privacidad:** cero peticiones de red desde la propia app; la única red la
  hace el proceso Python al descargar modelos la primera vez.
- **Limpieza de temporales:** WAVs de grabación y de conversión se borran al
  terminar, cancelar o fallar; si "Borrar audio automáticamente" está activo,
  también el archivo original importado (nunca sin el interruptor activo, y
  nunca el original si el usuario lo desactivó).
- **Robustez:** cierre de la app durante un proceso → el proceso hijo se
  termina y los temporales se limpian en el siguiente arranque.
- **Rendimiento UI:** la lectura de stdout y el proceso corren fuera del hilo
  principal; la UI permanece fluida durante transcripciones largas (>1 h de audio).
- **Idioma de la UI:** español (estructura preparada para localización).
- **Sin dependencias de UI de terceros;** Swift 5.9+, SwiftUI puro.

## 5. Fuera de alcance (v1)

- Distribución en Mac App Store, notarización, sandbox.
- Edición del texto de los segmentos (solo renombrar hablantes).
- Reimplementación del ML en Swift (WhisperKit, etc.).
