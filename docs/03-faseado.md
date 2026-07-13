# The Transcriptor — Faseado de proyecto (desarrollo con agentes)

Cada fase produce algo ejecutable y verificable. Las tareas están redactadas
para ser el prompt de un agente: entrada, salida y criterio de aceptación
explícitos. Referencias: `01-funcional.md` (CU-xx) y `02-diseno-tecnico.md` (§).

---

## Fase 0 — Cimientos (½ día)

**Objetivo:** repo compilable con estructura y script validado.

| Tarea | Descripción | Aceptación |
|---|---|---|
| 0.1 | `git init`, `.gitignore` (Xcode/Python), colocar `transcriptor_local.py` real en `Resources/` | Script real en el repo |
| 0.2 | Crear proyecto Xcode (o XcodeGen `project.yml`, §6): target macOS 14, Swift 5.9, sandbox eliminado, `NSMicrophoneUsageDescription` | `xcodebuild build` en verde con "Hello The Transcriptor" |
| 0.3 | Carpetas `Views/ Models/ Services/ Resources/` con placeholders | Estructura según §2 |
| 0.4 | `CLAUDE.md` con comandos de build/test y convenciones | Un agente nuevo puede compilar solo con leerlo |

## Fase 1 — Contrato con el script Python (1 día) ⚠️ ruta crítica

**Objetivo:** adaptar el script al contrato §3 **antes** de escribir UI.

| Tarea | Descripción | Aceptación |
|---|---|---|
| 1.1 | Auditar la CLI actual del script; añadir argparse: `--input --output-dir --model --json --keep-audio` (§3.1) sin tocar la lógica ML | Ejecutable a mano con la firma del contrato |
| 1.2 | Emitir protocolo `@@PHASE/@@PROGRESS/@@INFO/@@DONE/@@ERROR` por stdout con `flush=True` (§3.2); detectar descarga de modelos (HF y whisper) para `@@INFO:downloading_models` | Con un audio de prueba, stdout muestra la secuencia completa |
| 1.3 | Generar `result.json` (§3.3) además del `.txt`; token HF leído de `HF_TOKEN` | JSON válido con segmentos hablante+texto |
| 1.4 | Hacer opcional el borrado del original (`--keep-audio`) | El archivo sobrevive con el flag |
| 1.5 | Probar manualmente con: nota de voz `.m4a`, `.mp4` de Zoom, `.wav`; guardar los audios como fixtures | 3 ejecuciones correctas documentadas |

## Fase 2 — Núcleo Swift sin UI (1–2 días)

**Objetivo:** servicios probados por test/CLI antes de conectar vistas.
Paralelizable entre agentes: 2.1 ∥ 2.2 ∥ 2.3.

| Tarea | Descripción | Aceptación |
|---|---|---|
| 2.1 | `PythonPipelineService` (§4.1): Process, pipes async, parser `@@`, cancelación, workdir en App Support, limpieza de huérfanos | Test de integración: procesa un fixture y emite la secuencia de eventos esperada; cancelación mata el proceso |
| 2.2 | `KeychainService` (§4.3) + `SettingsStore` (§4.5) | Unit tests (Keychain con service de test) |
| 2.3 | `PythonEnvironmentDetector` + `RequirementsChecker` (§4.4) con timeouts | En este Mac detecta el intérprete correcto y los 4 checks dan resultado |
| 2.4 | Modelos: `TranscriptSegment`, `Transcript` (+`speakerNames`), `PipelinePhase`, `WhisperModel`, `RequirementCheck`; decodificación de `result.json` | Unit tests de decoding |
| 2.5 | `TxtExporter` y `SrtExporter` (§5) | Unit tests con transcript de ejemplo, SRT validado en un reproductor |

## Fase 3 — Flujo principal con archivo (1–2 días)

**Objetivo:** primer flujo E2E usable: soltar archivo → resultado. (CU-01, 03, 04 parcial)

| Tarea | Descripción | Aceptación |
|---|---|---|
| 3.1 | `AppState` + `MainView` con switch de fases (§5) | Navegación entre estados con datos simulados |
| 3.2 | `DropZoneView`: drag&drop (`.dropDestination`), `fileImporter`, filtrado de UTTypes (.m4a/.mp4/.mov/.wav) | Rechaza formatos no soportados con mensaje |
| 3.3 | `ProcessingView`: fase actual, spinner/da progreso, botón cancelar conectado | Fases visibles en vivo con un audio real |
| 3.4 | `ResultView` v1: lista de segmentos con timestamps y colores por hablante | Transcripción real legible con ≥2 hablantes |
| 3.5 | Pantalla de error con stderr plegado y "Reintentar" | Forzando fallo (token malo), la UI lo explica |

**Hito:** demo E2E — arrastrar una nota de voz y leer la transcripción diarizada.

## Fase 4 — Grabación de micrófono (1–2 días)

**Objetivo:** CU-02 completo.

| Tarea | Descripción | Aceptación |
|---|---|---|
| 4.1 | `AudioRecorderService` (§4.2): WAV 16 kHz mono incremental, pausa/reanudar, permiso | WAV grabado que el pipeline procesa sin conversión |
| 4.2 | `RecordingView` + `AudioLevelMeter`: iniciar/pausar/detener, nivel a ~20 fps, cronómetro | Medidor reacciona a la voz; detener encadena con el flujo de la Fase 3 |
| 4.3 | Flujo de permiso denegado con enlace a Ajustes del Sistema | Comprobado revocando el permiso |
| 4.4 | Cancelar grabación borra el WAV temporal | Verificado en disco |

## Fase 5 — Ajustes, requisitos y privacidad (1 día)

**Objetivo:** CU-05, CU-06, CU-07.

| Tarea | Descripción | Aceptación |
|---|---|---|
| 5.1 | `SettingsView` (Scene `Settings`): modelo Whisper con descripciones, token HF (SecureField→Keychain), interruptor de borrado, ruta Python con Autodetectar/Examinar | Cambios persisten; token verificado en Keychain Access, ausente de UserDefaults |
| 5.2 | `RequirementsView` en primer arranque y desde Ajustes; bloqueo suave hasta checks 1–3 en verde (CU-06) | Con ffmpeg renombrado, muestra instrucción copiable en lugar de fallar |
| 5.3 | `PrivacyBadge` permanente 🔒/⚠️ conectado a `@@INFO:downloading_models` + popover explicativo (CU-07) | Badge cambia durante una descarga real de modelos |
| 5.4 | Borrado del original respetando el interruptor; limpieza de temporales en éxito/error/cancelación/arranque | Auditoría del filesystem tras cada camino |

## Fase 6 — Exportación y pulido final (1 día)

| Tarea | Descripción | Aceptación |
|---|---|---|
| 6.1 | Renombrado inline de hablantes propagado a toda la vista y exportaciones (CU-04) | SPEAKER_00→"Angel" en UI, portapapeles, .txt y .srt |
| 6.2 | Botones copiar / exportar .txt / exportar .srt con `NSSavePanel` | Archivos abren correctamente (TextEdit, VLC para SRT) |
| 6.3 | Pulido: atajos (⌘N nueva, ⌘, ajustes, ⌘C copiar), estados vacíos, modo oscuro, tamaños de ventana | Revisión visual completa |
| 6.4 | Pruebas E2E de regresión: los 3 fixtures + grabación en vivo + cancelaciones | Checklist E2E documentada en verde |

---

## Resumen y reglas de trabajo con agentes

- **Duración estimada:** 6–9 días de agente efectivos. Ruta crítica: 0 → 1 → 2.1 → 3.
- **Paralelismo:** dentro de Fase 2 (2.1–2.5 independientes); Fase 4 puede
  solaparse con Fase 5 (tocan servicios distintos).
- **Regla 1:** ningún trabajo de UI (Fase 3+) empieza hasta cerrar la Fase 1 —
  el contrato del script es la interfaz de todo lo demás.
- **Regla 2:** cada tarea termina con `xcodebuild build` (y `test` si aplica)
  en verde; el criterio de aceptación de la tabla es el "definition of done"
  que el agente debe demostrar, no solo afirmar.
- **Regla 3:** los agentes no modifican `transcriptor_local.py` fuera de la
  Fase 1 sin actualizar el contrato en `02-diseno-tecnico.md §3`.
