# Plan y diseño — Fase 4 (Grabación de micrófono) + implementación adelantada de la interfaz completa

> Documento autosuficiente: se puede ejecutar leyendo solo esto más
> `01-funcional.md`, `02-diseno-tecnico.md` y `03-faseado.md`.

## 1. Objetivo y alcance

Cerrar la Fase 4 de `docs/03-faseado.md` (CU-02, grabación de micrófono) y,
adelantándose al faseado original, **implementar ya toda la interfaz**
(Fases 3, 4 y los huecos de vista de Fases 5–6) en una sola pasada, porque el
contrato Python (Fase 1) y el núcleo Swift (Fase 2) ya están cerrados y
verificados — no hay razón para seguir bloqueando la UI.

Se excluye deliberadamente el pulido fino de Fase 6 (atajos de teclado,
estados vacíos elaborados, revisión exhaustiva de modo oscuro): la UI queda
**funcional y conectada de extremo a extremo**, no pulida a nivel de detalle
visual. Eso se deja como iteración posterior.

## 2. Punto de partida verificado

- Fase 1 cerrada: `Resources/transcriptor_local.py` implementa el protocolo
  completo `@@PHASE/@@PROGRESS/@@INFO/@@DONE/@@ERROR`, `argparse` con
  `--input --output-dir --model --json --keep-audio`, `HF_TOKEN` por entorno,
  `result.json` con el shape `{language, duration, segments}`.
- Fase 2 cerrada: `PythonPipelineService`, `KeychainService`, `SettingsStore`,
  `PythonEnvironmentDetector`, `RequirementsChecker`, modelos
  (`Transcript`, `TranscriptSegment`, `PipelinePhase`, `WhisperModel`,
  `RequirementCheck`) y exportadores (`TxtExporter`, `SrtExporter`), todos
  con tests.
- Fase 3 (UI) **no se había empezado**: `MainView.swift` es un placeholder
  ("Hello The Transcriptor"); `Views/Components/` está vacío; no existe
  `AppState.swift` ni `AudioRecorderService.swift`.
- Regla 1 del faseado ("ningún trabajo de UI hasta cerrar Fase 1") queda
  satisfecha — se puede proceder.

## 3. Huecos de diseño no resueltos por `02-diseno-tecnico.md` y decisiones tomadas aquí

`02-diseno-tecnico.md` especifica el *qué* (§2 estructura, §4.2 servicio de
grabación, §5 máquina de estados) pero no fija algunos detalles de cableado.
Decisiones para esta implementación:

1. **`AppPhase` es un enum nuevo**, distinto de `PipelinePhase` (que son solo
   las 4 subfases del script). Vive en `Models/AppState.swift` junto a la
   clase `AppState`.
2. **Observación mixta**: `AppState` es `@Observable` (como
   `PythonPipelineService`, con quien interactúa más), y contiene una
   instancia de `SettingsStore` (`ObservableObject`) como propiedad simple —
   las vistas que necesiten `SettingsStore` lo obtienen vía
   `appState.settings` y lo declaran `@ObservedObject` donde haga falta
   binding bidireccional (p. ej. `SettingsView`).
3. **Puente `PythonPipelineService.Event` → `AppPhase`**: vive en un método
   `AppState.runPipeline(input:)` que arranca una `Task`, consume el
   `AsyncStream<Event>` y traduce:
   - `.phase(p)` / `.progress(n)` / `.downloadingModels` →
     `.processing(p, progress:, downloading:)` (progress y downloading son
     opcionales/acumulativos, no se resetean entre eventos salvo cambio de
     fase).
   - `.done(url)` → decodifica `Transcript` desde el JSON en `url`
     (`JSONDecoder`, no hay decodificador integrado en el servicio) y pasa a
     `.result(transcript)`.
   - `.failed(error)` → `.error(error)`.
4. **Construcción de `PipelineSettings`**: un método privado en `AppState`
   combina `SettingsStore` (modelo, `deleteAudioAfter` invertido a
   `keepAudio`), `KeychainService().token()` (hfToken) y la URL del script
   copiado a Application Support (`PythonPipelineService.applicationSupportDirectory()`
   + `"transcriptor_local.py"`) — ninguna fuente única tiene todo.
5. **`RequirementsChecker` es síncrono/bloqueante** (usa `usleep` en bucles
   de espera de subproceso) → se invoca desde `AppState` con
   `Task.detached(priority: .utility)` para no congelar la UI; el resultado
   se vuelve a `AppPhase.checkingRequirements` en el `MainActor`.
6. **Owner del WAV grabado vs. `work/<UUID>/` del pipeline**: son
   directorios distintos. `AudioRecorderService` escribe el WAV en
   `Application Support/TheTranscriptor/recordings/<UUID>.wav` (no en
   `work/`, que es exclusivo del pipeline). Al pulsar "usar esta grabación"
   ese WAV se pasa como `input` a `PythonPipelineService.run`, que copia/gestiona
   su propio `work/<UUID>/` para la conversión — no se borra el WAV grabado
   hasta que el pipeline termina con éxito (y solo si `deleteAudioAfter` está
   activo, igual que con archivos soltados). Cancelar la grabación (4.4)
   borra el WAV de `recordings/` directamente porque nunca entró al pipeline.

## 4. Diseño detallado — `AudioRecorderService` (Fase 4, tarea 4.1)

```swift
@Observable
final class AudioRecorderService {
    enum State: Equatable { case idle, recording, paused }
    enum RecorderError: Error, Equatable { case permissionDenied, engineFailure(String) }

    private(set) var state: State = .idle
    private(set) var level: Float = 0        // 0...1, ~20 Hz
    private(set) var elapsed: TimeInterval = 0
    private(set) var outputURL: URL?

    func requestPermission() async -> Bool
    func start() throws -> URL          // crea recordings/<UUID>.wav, instala tap
    func pause()                        // quita el tap, deja el AVAudioFile abierto
    func resume() throws                // reinstala el tap
    func stop() -> URL?                 // cierra el archivo, devuelve la ruta final
    func cancelAndDelete()              // detiene, cierra y borra el WAV
}
```

Puntos críticos de implementación (motivo: son los fallos típicos de
`AVAudioEngine` y por qué el contrato exige WAV 16 kHz mono):

- **El formato del input node NO es 16 kHz.** `inputNode.inputFormat(forBus: 0)`
  refleja el hardware (normalmente 44.1/48 kHz). Instalar el tap pidiendo un
  formato distinto al del hardware falla o produce silencio — el tap se
  instala **con el formato nativo**, y la conversión ocurre después, buffer a
  buffer, con `AVAudioConverter` hacia un `AVAudioFormat` de 16 kHz
  mono/Int16 (LPCM), escribiendo cada buffer convertido en un
  `AVAudioFile` ya abierto en modo escritura con ese formato de destino.
  Escribir el buffer del hardware directamente en el archivo de 16 kHz
  (sin convertir) es el bug más común — hay que evitarlo explícitamente.
- **Nivel**: RMS del buffer de entrada (antes o después de convertir, da
  igual mientras sea consistente) → dBFS → normalizado 0–1 con clamping;
  publicado como propiedad `@Observable` actualizada como máximo a ~20 Hz
  (throttle simple por timestamp, no en cada buffer de audio que llega mucho
  más rápido) para que `AudioLevelMeter` no repinte más de lo necesario.
- **Pausa/reanudar**: pausa = `inputNode.removeTap(onBus: 0)` sin cerrar el
  `AVAudioFile` (el archivo WAV permite escritura incremental; cerrarlo y
  reabrirlo perdería el estado). Reanudar = volver a instalar el tap con el
  mismo `AVAudioConverter`/formato.
- **Permiso**: `AVCaptureDevice.requestAccess(for: .audio)` antes de
  `start()`; si `.denied` ya conocido (`AVCaptureDevice.authorizationStatus`),
  no se re-pide (Apple no vuelve a mostrar el diálogo) — se expone
  `RecorderError.permissionDenied` para que la vista ofrezca el enlace a
  Ajustes del Sistema (tarea 4.3).
- **Cancelar**: para el motor, cierra el archivo y `FileManager.removeItem`
  sobre el WAV — verificable en disco (tarea 4.4).

## 5. Diseño de vistas nuevas (todas las Views que faltaban)

| Vista | Responsabilidad | Se conecta a |
|---|---|---|
| `AppState` (Models) | Máquina de estados + orquestación | `PythonPipelineService`, `AudioRecorderService`, `SettingsStore`, `KeychainService`, `RequirementsChecker` |
| `MainView` | `switch appState.phase` → subvista | `AppState` |
| `DropZoneView` | Drag&drop (`.dropDestination`) + `fileImporter`, filtro UTType `.m4a/.mp4/.mov/.wav`, botón "Grabar" | `AppState.phase = .recording` / `.runPipeline(input:)` |
| `RecordingView` | Iniciar/pausar/detener, cronómetro, `AudioLevelMeter` | `AudioRecorderService` |
| `ProcessingView` | Fase actual (`PipelinePhase.displayName`), progreso, botón cancelar | `AppState.phase == .processing`, `PythonPipelineService.cancel()` |
| `ResultView` | Lista de `SegmentRow`, renombrado inline, copiar/exportar | `Transcript`, `TxtExporter`, `SrtExporter`, `NSSavePanel` |
| `SettingsView` (Scene `Settings`) | Modelo Whisper, token HF, borrado, ruta Python | `SettingsStore`, `KeychainService`, `PythonEnvironmentDetector` |
| `RequirementsView` | Checklist ✓/✗ con instrucciones copiables | `RequirementCheck` list en `AppState` |
| `Components/PrivacyBadge` | 🔒/⚠️ conectado a `downloadingModels` | `AppState.phase` |
| `Components/AudioLevelMeter` | Barra reactiva a `level` | `AudioRecorderService.level` |
| `Components/SegmentRow` | timestamp + hablante + texto + renombrado | `TranscriptSegment`, `Transcript.displayName` |
| Pantalla de error | stderr plegable + "Reintentar" | `.error(PipelineError)` |

`AppPhase` (nuevo, en `Models/AppState.swift`):

```swift
enum AppPhase {
    case checkingRequirements([RequirementCheck])
    case idle
    case recording
    case processing(PipelinePhase, progress: Int?, downloading: Bool)
    case result(Transcript)
    case error(PipelineError)
}
```

## 6. Orden de construcción (dependencias)

1. `AppState.swift` + `AppPhase` — todo lo demás conmuta sobre esto.
2. Puente `Event → AppPhase` dentro de `AppState` (decodificación de
   `result.json`, construcción de `PipelineSettings`).
3. `MainView` con el `switch`.
4. Componentes hoja: `SegmentRow`, `PrivacyBadge`, `AudioLevelMeter`.
5. Vistas contenedoras: `DropZoneView`, `ProcessingView`, `ResultView`,
   `RequirementsView`, `SettingsView`, `RecordingView` (+ pantalla de error).
6. `AudioRecorderService` (núcleo de Fase 4) y su cableado en `AppState` +
   `RecordingView`.
7. `xcodegen generate` → `xcodebuild build` → `xcodebuild test` → smoke test
   con `/run`.

## 7. Criterios de aceptación

- Fase 4 (tabla de `03-faseado.md`):
  - 4.1: WAV grabado por `AudioRecorderService` procesable por el pipeline
    sin conversión previa (16 kHz mono).
  - 4.2: `RecordingView` + `AudioLevelMeter` reaccionan a voz real; detener
    encadena con el flujo de Fase 3 (`.processing`).
  - 4.3: permiso denegado → enlace a Ajustes del Sistema, verificado
    revocando el permiso.
  - 4.4: cancelar grabación borra el WAV temporal, verificado en disco.
- Interfaz completa: `xcodebuild -scheme TheTranscriptor build` y `test` en
  verde; navegación entre todas las fases con datos simulados y con el
  pipeline real contra los fixtures existentes.

## 8. Límite de verificación de esta sesión

Sin micrófono real accesible por el agente ni forma de conducir una app
macOS nativa de extremo a extremo por herramientas de navegador, esta sesión
puede demostrar: build verde, tests verdes, y arranque de la app
(`/run`) confirmando que la interfaz renderiza y navega. La grabación real
de voz, el permiso de micrófono y la transcripción end-to-end con audio real
requieren verificación manual del usuario en su Mac.
