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
@@PROGRESS:42              # opcional, 0–100 dentro de la fase
@@PHASE:DIARIZING
@@INFO:downloading_models  # solo si va a descargar de HF → la UI cambia el badge
@@PROGRESS:17              # heurística: 0-50 ~ paso "segmentation", 50-100 ~ "embeddings"
                           # de pyannote (vía su Hook); no es un % real de pipeline completo
@@INFO:diarizing_step:<nombre> # pasos internos sin progreso medible (p.ej. clustering)
@@PHASE:MERGING
@@DONE:<ruta_result.json>
@@ERROR:<mensaje breve>   # y exit code ≠ 0; detalle completo por stderr
```

`@@PROGRESS` se reinicia (nueva escala 0–100) en cada `@@PHASE`; el lado
Swift (`AppState.handle(event:)`) descarta el progreso anterior al recibir
una nueva fase — antes se arrastraba, así que al entrar en `DIARIZING` la UI
seguía mostrando el `100%` que había dejado `TRANSCRIBING`, pareciendo
terminado/colgado cuando la diarización acababa de empezar.

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

### 3.4 Modo dos pistas (grabación de reunión)

Para grabar reuniones online (micro + audio del sistema, CU-09) el script
admite una invocación alternativa con **dos pistas separadas**:

```
python3 transcriptor_local.py \
    --input-mic <mic.wav> --input-system <system.wav> \
    [--mic-offset <seg>] [--system-offset <seg>] \
    --output-dir <dir_resultados> \
    --model <...> --json [--keep-audio]
```

- La pista de **micrófono** se transcribe y se etiqueta ENTERA como
  `SPEAKER_00` (voz local = "Yo"), sin diarización.
- La pista del **sistema** pasa por el flujo completo de una pista
  (transcribe → pyannote → merge) para separar varios interlocutores
  remotos; sus etiquetas de pyannote se **renumeran** a `SPEAKER_01`,
  `SPEAKER_02`, … por orden de aparición para no colisionar con el micro.
- A cada pista se le suma su offset (`--mic-offset`/`--system-offset`, en
  segundos, relativos al inicio común de la grabación) antes de fusionar.
- Ambas listas de segmentos se **fusionan ordenadas por `start`** en un único
  `result.json` con el mismo formato de §3.3. El resultado es una sola
  transcripción/entrada de historial, idéntica a cualquier otra.
- Requiere `HF_TOKEN` (usa pyannote sobre la pista del sistema). `--input` es
  mutuamente excluyente con `--input-mic`/`--input-system`.

Los nombres amables ("Yo"/"Interlocutor N") no los produce el script: se
pre-cargan en `Transcript.speakerNames` desde Swift
(`AppState.defaultMeetingSpeakerNames`) al crear el `HistoryEntry`.

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
(Bool, default `false` — el original se conserva salvo que el usuario active
el borrado explícitamente), `pythonPath` (String), `historyRetentionDays`
(Int, default `0` = sin límite; ver §4.6). El token **no** pasa por aquí.

### 4.6 `HistoryStore` e Historial de transcripciones

Al terminar cada transcripción (`AppState.decodeAndShowResult`), además de
mostrar el resultado se persiste automáticamente un `HistoryEntry`:

```swift
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let sourceFileName: String
    let sourceAudioPath: String?   // puede no existir ya; no se copia el audio
    let whisperModel: String
    var transcript: Transcript
}
```

`HistoryStore` (`@Observable`, singleton `HistoryStore.shared`, mismo
patrón que `LogStore.shared`) guarda **un fichero JSON por entrada** en
`Application Support/TheTranscriptor/history/<uuid>.json`. Deliberadamente
en una carpeta separada de `work/`, que
`PythonPipelineService.purgeOrphanedWorkDirs()` vacía entera en cada
arranque — el historial debe sobrevivir a reinicios de la app.
`applyRetentionPolicy(retentionDays:)` purga entradas más antiguas que el
ajuste de retención; se invoca tras cada guardado y una vez al arrancar,
junto a `purgeOrphanedWorkDirs()`.

`Transcript` pasa de una síntesis automática de `Codable` (que excluía
`speakerNames` de sus `CodingKeys`, ya que `result.json` del script nunca
trae ese campo) a una implementación manual de `init(from:)` que decodifica
`speakerNames` con `decodeIfPresent(...) ?? [:]` — compatible con
`result.json` (sin la clave) y necesaria para que el historial conserve los
renombres de hablante hechos por el usuario.

La UI vive en una ventana aparte ("Historial", `Window(id: "history")`),
mismo patrón que "Registro de depuración": `NavigationSplitView` con lista
de entradas y detalle (misma estructura de lista de segmentos que
`ResultView`, con "Eliminar del historial" en vez de "Nueva
transcripción").

### 4.7 `SystemAudioRecorderService` y `MeetingRecorderService`

Grabación de reunión (CU-09): captura simultánea de micrófono y audio del
sistema como **dos pistas separadas** que alimentan el modo dos pistas del
script (§3.4).

- **`SystemAudioRecorderService`** captura TODO el audio de salida del
  sistema con *Core Audio process taps* (`AudioHardwareCreateProcessTap` +
  `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, macOS 14.4+)
  montados sobre un *aggregate device* privado — sin dispositivo virtual ni
  extensión de kernel. El *aggregate* se vincula al **dispositivo de salida
  por defecto real** (`kAudioHardwarePropertyDefaultOutputDevice` →
  `kAudioAggregateDeviceMainSubDeviceKey`) para que herede su reloj y formato;
  sin esto la captura solo era fiable con los altavoces integrados y quedaba
  en silencio con cascos, USB o Bluetooth. Un listener de
  `kAudioHardwarePropertyDefaultOutputDevice` reconstruye tap + aggregate +
  converter si el usuario cambia de salida a mitad de grabación (sin cerrar el
  WAV). Un `AudioDeviceIOProc` recibe los buffers del tap, los
  convierte a WAV mono 16 kHz PCM16 (mismo contrato de audio que
  `AudioRecorderService`) y calcula el nivel RMS. `muteBehavior = .unmuted`
  para que el usuario siga oyendo la reunión. Vuelca diagnóstico (dispositivo
  de salida, formato del tap, frames escritos) a `LogStore` (⌘L).
- **`MeetingRecorderService`** coordina el micrófono
  (`AudioRecorderService`, **reutilizando la misma instancia** que el modo
  solo-micro para no crear un segundo `AVAudioEngine` en el arranque) y
  `SystemAudioRecorderService`, arrancándolos a la vez y registrando el
  instante de inicio de cada pista para derivar los offsets de §3.4.
  Devuelve `(micURL, systemURL, micOffset, systemOffset)` a
  `AppState.runMeetingPipeline`. No soporta pausa/reanudación (se graba de
  corrido para no desincronizar las pistas). **Grabar por altavoces provoca
  eco** (la voz del interlocutor que sale por el altavoz se cuela en el micro y
  se transcribe duplicada); la UI (`RecordingView`/`DropZoneView`) recomienda
  cascos, que lo eliminan por completo. Se intentó la cancelación de eco de
  macOS (`AVAudioInputNode.setVoiceProcessingEnabled(true)`) pero **entra en
  conflicto con el process tap del sistema** (ambos pelean por el HAL / el
  dispositivo de salida por defecto: el tap deja de entregar frames y se
  disparan cambios de dispositivo espurios), así que queda descartada por ahora;
  la reducción de eco por software es una mejora futura.
- Permisos: micrófono (`AVCaptureDevice`, key `NSMicrophoneUsageDescription`) +
  "Grabación de audio del sistema" (TCC). Este último **exige la key
  `NSAudioCaptureUsageDescription` en el Info.plist** (declarada en
  `project.yml`); sin ella macOS no muestra el prompt y el process tap entrega
  **buffers en silencio (todo ceros)** aunque el IOProc dispare con normalidad
  (el contador de frames crece pero el nivel se queda a 0). El prompt lo dispara
  el sistema al crear el tap la primera vez, una vez presente la key. Si la
  captura de sistema falla de forma dura, `RecordingView` muestra una pantalla
  que enlaza a Ajustes del Sistema; el caso de "capta silencio" (permiso no
  concedido) se diagnostica con el registro ⌘L (fuente `sysaudio`). Requiere App
  Sandbox y Hardened Runtime desactivados (ya lo están).

## 5. Modelo de estado y navegación

```swift
enum AppPhase {
    case checkingRequirements([RequirementCheck])
    case idle                    // DropZone + botón grabar
    case recording
    case processing(PipelinePhase, progress: Int?, downloading: Bool)
    case result(HistoryEntry)
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
