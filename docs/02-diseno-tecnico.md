# The Transcriptor — Diseño Técnico

**Versión:** 0.1 · **Fecha:** 2026-07-12
**Stack:** Swift 5.9+, SwiftUI, macOS 14+, App Sandbox **desactivado**

## 1. Decisiones de arquitectura

| # | Decisión | Justificación |
|---|---|---|
| A1 | Envolver el script Python con `Process` en vez de portar el ML a Swift | El pipeline ya funciona; se reutiliza tal cual |
| A2 | App Sandbox desactivado | Necesita lanzar procesos externos, micrófono y FS libre; uso personal fuera de la MAS |
| A3 | Script embebido en `Resources/` y copiado a Application Support en el primer arranque | La app es autocontenida; el bundle es de solo lectura, así que se ejecuta la copia |
| A4 | Comunicación app→script por argumentos CLI; script→app por **stdout con protocolo de líneas** | Simple, depurable, sin sockets ni IPC |
| A5 | Token HF vía variable de entorno (`HF_TOKEN`) al proceso hijo | Los argumentos CLI son visibles en `ps aux` |
| A6 | Salida estructurada del script en JSON (un archivo de resultado) además del .txt | La UI necesita segmentos tipados (inicio, fin, hablante, texto), no parsear texto libre |
| A7 | Concurrencia con `async/await` + `AsyncStream` para stdout; estado global en `@Observable` | Swift moderno, sin Combine innecesario |

## 2. Estructura del proyecto Xcode

```
TheTranscriptor/
├── TheTranscriptorApp.swift        # @main, inyección de AppState y servicios
├── Info.plist                        # NSMicrophoneUsageDescription
├── Views/
│   ├── MainView.swift                # Enrutado por AppState.phase (switch)
│   ├── DropZoneView.swift            # Drag&drop + fileImporter + botón grabar
│   ├── RecordingView.swift           # Controles + medidor de nivel + cronómetro
│   ├── ProcessingView.swift          # Fase actual, progreso, cancelar
│   ├── ResultView.swift              # Lista de segmentos, renombrado, exportar
│   ├── SettingsView.swift            # Scene Settings estándar de macOS
│   ├── RequirementsView.swift        # Checklist ✓/✗ con instrucciones
│   └── Components/
│       ├── PrivacyBadge.swift        # Indicador 🔒 / ⚠️ permanente
│       ├── AudioLevelMeter.swift     # Barra/onda de nivel
│       └── SegmentRow.swift          # Fila timestamp+hablante+texto
├── Models/
│   ├── AppState.swift                # @Observable: fase de la app, resultado, error
│   ├── TranscriptSegment.swift       # struct Codable: start, end, speaker, text
│   ├── Transcript.swift              # [segmentos] + speakerNames: [String: String]
│   ├── PipelinePhase.swift           # enum: converting/transcribing/diarizing/merging
│   ├── WhisperModel.swift            # enum tiny…large-v3 + descripción
│   └── RequirementCheck.swift        # enum requisito + estado + instrucción
├── Services/
│   ├── PythonPipelineService.swift   # Process + protocolo stdout (núcleo)
│   ├── AudioRecorderService.swift    # AVAudioEngine, WAV 16 kHz mono, niveles
│   ├── KeychainService.swift         # get/set/delete token HF (Security.framework)
│   ├── SettingsStore.swift           # UserDefaults tipado (@AppStorage keys)
│   ├── RequirementsChecker.swift     # ffmpeg, python, paquetes
│   ├── PythonEnvironmentDetector.swift # autodetección de intérpretes
│   └── Exporters/
│       ├── TxtExporter.swift
│       └── SrtExporter.swift
└── Resources/
    └── transcriptor_local.py         # script embebido (Copy Bundle Resources)
```

## 3. Contrato con el script Python

### 3.1 Invocación (adaptar el script a esta interfaz)

```
python3 transcriptor_local.py \
    --input <ruta_audio> \
    --output-dir <dir_resultados> \
    --model <tiny|base|small|medium|large-v3> \
    --json \                 # además del .txt, emite result.json
    [--keep-audio]           # NO borrar el original (interruptor desactivado)
```

Entorno del proceso: `HF_TOKEN=<token>` (si existe), `PATH` ampliado con
`/opt/homebrew/bin:/usr/local/bin` (las apps GUI no heredan el PATH del shell).

> **⚠️ Suposición a validar:** no dispongo del script real; si su CLI actual
> difiere, se añade en la Fase 1 una capa de argumentos compatible
> (argparse) sin tocar la lógica interna. El borrado del original debe pasar
> a ser opcional (`--keep-audio`) porque hoy es incondicional.

### 3.2 Protocolo de progreso por stdout

El script emite líneas con prefijo parseable (añadir `print` en los puntos de
fase existentes; `flush=True` obligatorio):

```
@@PHASE:CONVERTING
@@PHASE:TRANSCRIBING
@@PROGRESS:42            # opcional, 0–100 dentro de la fase
@@PHASE:DIARIZING
@@INFO:downloading_models # solo si va a descargar de HF → la UI cambia el badge
@@PHASE:MERGING
@@DONE:<ruta_result.json>
@@ERROR:<mensaje breve>   # y exit code ≠ 0; detalle completo por stderr
```

Cualquier línea sin `@@` se ignora (logs de las librerías). Esto hace el
protocolo robusto frente al ruido de faster-whisper/pyannote.

### 3.3 Formato de `result.json`

```json
{
  "language": "es",
  "duration": 1834.2,
  "segments": [
    { "start": 0.0, "end": 4.2, "speaker": "SPEAKER_00", "text": "Hola…" }
  ]
}
```

## 4. Servicios — diseño detallado

### 4.1 `PythonPipelineService`

```swift
@Observable final class PythonPipelineService {
    enum Event { case phase(PipelinePhase), progress(Int),
                 downloadingModels, done(URL), failed(PipelineError) }

    func run(input: URL, settings: PipelineSettings) -> AsyncStream<Event>
    func cancel()
}
```

- `Process` con `executableURL` = intérprete configurado; `arguments` según §3.1.
- `standardOutput`/`standardError` → `Pipe`; lectura incremental con
  `FileHandle.bytes.lines` (AsyncSequence) en una `Task` desatendida.
- Parser del protocolo `@@` → emite `Event` en el stream; stderr se acumula
  en un buffer circular (últimas ~200 líneas) para la pantalla de error.
- `cancel()`: `terminate()` (SIGTERM); si a los 5 s sigue vivo,
  `kill(pid, SIGKILL)`. `terminationHandler` limpia temporales siempre.
- El WAV temporal y `output-dir` viven en
  `~/Library/Application Support/TheTranscriptor/work/<UUID>/`; el
  directorio se borra al terminar (éxito, error o cancelación). Al arrancar
  la app se purga cualquier `work/*` huérfano.
- Primer arranque: copia `Resources/transcriptor_local.py` a
  `Application Support/TheTranscriptor/` (se re-copia si el hash difiere,
  para que las actualizaciones de la app actualicen el script).

### 4.2 `AudioRecorderService`

- `AVAudioEngine` + `installTap(onBus:)` sobre el input node.
- Conversión en vivo a **16 kHz mono Float32→Int16** con `AVAudioConverter`,
  escritura incremental con `AVAudioFile` (WAV/LPCM) — el formato que
  esperan whisper/pyannote, evita depender de ffmpeg para la grabación.
- Nivel: RMS→dBFS por buffer, publicado a 20 Hz vía propiedad `@Observable`
  (`level: Float` 0–1 ya normalizado) para `AudioLevelMeter`.
- Pausa = detener el tap sin cerrar el archivo; reanudar = reinstalar tap.
- Permiso: `AVCaptureDevice.requestAccess(for: .audio)` antes de arrancar.

### 4.3 `KeychainService`

- `SecItemAdd/CopyMatching/Update/Delete` con
  `kSecClassGenericPassword`, service `"com.allosa.TheTranscriptor"`,
  account `"huggingface-token"`, `kSecAttrAccessibleWhenUnlocked`.
- API: `func token() -> String?`, `func setToken(_:) throws`, `func deleteToken()`.

### 4.4 `PythonEnvironmentDetector` y `RequirementsChecker`

Autodetección (en orden, primero que valide gana):
1. Ruta guardada por el usuario.
2. `.venv/bin/python3` o `venv/bin/python3` junto al script si el usuario lo indicó.
3. `~/.pyenv/shims/python3`, `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`.
4. Salida de `/bin/zsh -lc "which -a python3"` (captura PATH real del usuario).

Validación de cada candidato y requisitos (cada check con timeout de 10 s):
- Python: `<py> -c "import sys; print(sys.version)"` → exit 0.
- Paquetes: `<py> -c "import faster_whisper, pyannote.audio"` → exit 0
  (si falla, el mensaje distingue cuál falta parseando stderr).
- ffmpeg: buscar en `/opt/homebrew/bin`, `/usr/local/bin` y `which ffmpeg`
  vía zsh de login; validar con `ffmpeg -version`.

Resultado: `[RequirementCheck]` con `.ok / .missing(instrucción)` que
`RequirementsView` pinta con comandos copiables.

### 4.5 `SettingsStore`

`@AppStorage`-backed: `whisperModel` (String raw), `deleteAudioAfter`
(Bool, default `true`), `pythonPath` (String). El token **no** pasa por aquí.

## 5. Modelo de estado y navegación

```swift
enum AppPhase {
    case checkingRequirements([RequirementCheck])
    case idle                    // DropZone + botón grabar
    case recording
    case processing(PipelinePhase, progress: Int?, downloading: Bool)
    case result(Transcript)
    case error(PipelineError)
}

@Observable final class AppState { var phase: AppPhase = .idle … }
```

`MainView` hace `switch appState.phase` → subvista. Sin NavigationStack:
es una máquina de estados lineal, más simple y adecuada aquí.

**Renombrado de hablantes:** `Transcript.speakerNames: [String: String]`
(`"SPEAKER_00" → "Angel"`). Las vistas y exportadores resuelven
`displayName(for:)`; los datos originales no se mutan. Colores:
`speakerColor(index:)` sobre paleta fija de 8, asignada por orden de aparición.

**Exportadores:** puros (`Transcript → String`), triviales de testear.
SRT: índice secuencial, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, texto con prefijo
`Nombre: `. Guardado con `NSSavePanel` (sin sandbox no hay restricciones).

## 6. Configuración del proyecto

- **Capabilities:** App Sandbox **eliminado** del target (sin entitlement
  `com.apple.security.app-sandbox`). Hardened Runtime opcional desactivado
  (app personal sin notarizar) — si se activa en el futuro, no bloquea
  `Process` ni el micrófono con el usage description presente.
- **Info.plist:** `NSMicrophoneUsageDescription` = "The Transcriptor usa el
  micrófono para grabar audio que se transcribe íntegramente en este Mac;
  nada se envía a internet."
- **Firma:** "Sign to Run Locally" o Apple Development.
- **Generación del proyecto:** proyecto Xcode nativo. Recomendado añadir
  **XcodeGen** (`project.yml`) o Tuist para que los agentes puedan regenerar
  el `.xcodeproj` de forma determinista desde texto; alternativa mínima:
  crear el proyecto una vez a mano y que los agentes solo toquen fuentes.
- **Build/test por CLI:** `xcodebuild -scheme TheTranscriptor build` y
  `xcodebuild test` (unit tests de exportadores, parser de protocolo,
  KeychainService con service de test).

## 7. Riesgos técnicos

| Riesgo | Mitigación |
|---|---|
| CLI real del script distinto al contrato §3.1 | Fase 1 valida/adapta el script antes de escribir Swift |
| PATH vacío en apps GUI → no encuentra ffmpeg/python | PATH ampliado explícito + detección vía `zsh -lc` (§4.4) |
| pyannote requiere aceptar condiciones del modelo en HF | RequirementsView enlaza a las páginas del modelo; error de descarga se detecta y explica |
| Buffers de Pipe llenos si no se lee stdout/stderr → deadlock del hijo | Lectura asíncrona continua de ambos pipes desde el arranque del proceso |
| Grabaciones muy largas (RAM/disco) | Escritura incremental a disco; sin límite artificial, aviso de espacio <2 GB |
| Modelo Whisper no descargado aún (faster-whisper también descarga la 1ª vez) | El badge de privacidad también se activa con `@@INFO:downloading_models` emitido por el script en ambos casos |
