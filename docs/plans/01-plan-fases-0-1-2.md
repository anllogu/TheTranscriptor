# Plan de ejecución — Fases 0, 1 y 2 (paralelizado)

> Documento autosuficiente: un agente por pista debe poder ejecutar su parte
> leyendo solo este documento más `01-funcional.md`, `02-diseno-tecnico.md` y
> `03-faseado.md`.

## 1. Objetivo y alcance

Cerrar las Fases 0 (Cimientos), 1 (Contrato con el script Python) y 2
(Núcleo Swift sin UI) de `docs/03-faseado.md` en una sola sesión orquestada,
en paralelo entre agentes en lugar de secuencialmente.

**Hito final:** repo compilable con `xcodebuild -scheme TheTranscriptor
build`, servicios Swift de la Fase 2 con tests en verde, y
`transcriptor_local.py` real funcionando contra el contrato §3 con los 3
tipos de audio de fixture (CU-01 a CU-04, según aplique en cada pista).

**Cambio respecto al faseado original:** el script Python **no existe
todavía** — no hay CLI previa que auditar. La tarea 1.1 pasa de "auditar y
adaptar" a **"implementar de cero contra el contrato §3.1"**. El resto de
Fase 1 (1.2–1.5) se mantiene igual.

## 2. Insight que habilita el paralelismo

La Regla 1 del faseado ("ningún trabajo de UI/Fase 3+ empieza hasta cerrar
Fase 1, porque el contrato del script es la interfaz de todo lo demás") no
exige que el **script real** exista antes de empezar Fase 2 — exige que el
**contrato** esté cerrado. El contrato (`02-diseno-tecnico.md §3`) ya está
escrito y congelado. Por tanto:

- La Fase 2 (Swift) se desarrolla contra el contrato documentado, no contra
  el script real.
- Para el único punto de Fase 2 que necesita un proceso real que hablar
  (`PythonPipelineService`, tarea 2.1), se usa un **script Python fake de
  test** que emite exactamente la secuencia del contrato — no el pipeline
  ML real.
- La integración final entre el script real (pista B) y `PythonPipelineService`
  (pista C) se valida en un **gate de convergencia** al final, no al principio.

Esto permite que las pistas B y C corran a la vez tras cerrar la pista A.

## 3. Modelo de orquestación: 3 pistas paralelas

### Pista A — Cimientos (Fase 0)

Arranca primero; las otras dos pistas dependen de su salida (repo + proyecto
Xcode). Duración estimada: minutos, no horas.

- `git init` + `.gitignore` (patrones Xcode: `.build/`, `DerivedData/`,
  `*.xcuserstate`; patrones Python: `__pycache__/`, `*.pyc`, `.venv/`).
- Proyecto Xcode vía XcodeGen (`project.yml`, §6): target macOS 14, Swift
  5.9+, App Sandbox **deshabilitado**, `NSMicrophoneUsageDescription`
  presente en el Info.plist generado.
- Estructura de carpetas `Views/`, `Models/`, `Services/`, `Resources/` con
  placeholders mínimos (según §2).
- Verificar `xcodebuild -scheme TheTranscriptor build` en verde con un
  "Hello The Transcriptor" mínimo.
- Tarea 0.4 (`CLAUDE.md` con comandos de build/convenciones) **ya está
  hecha** — el `CLAUDE.md` del repo ya cumple el criterio de aceptación
  ("un agente nuevo puede compilar solo con leerlo"). Se marca como
  completada, no se repite.

### Pista B — Script Python (Fase 1, redefinida)

Depende solo de que exista `Resources/` (pista A). No depende de la pista C.

- Escribir `Resources/transcriptor_local.py` de cero:
  - `argparse` con la firma exacta del contrato: `--input --output-dir
    --model --json [--keep-audio]` (§3.1).
  - Pipeline: ffmpeg (normalización) → faster-whisper (transcripción) →
    pyannote-audio (diarización) → merge de segmentos por hablante.
  - Protocolo de progreso por stdout con `flush=True` en cada línea (§3.2):
    `@@PHASE:…`, `@@PROGRESS:n`, `@@INFO:downloading_models` (para **ambas**
    descargas, whisper y pyannote/HF), `@@DONE:<path>`, `@@ERROR:<msg>`.
  - `result.json` (§3.3) además del `.txt`, con segmentos hablante+texto.
  - Token de Hugging Face leído **solo** de la variable de entorno
    `HF_TOKEN` — nunca de argumentos.
  - `--keep-audio` opcional: si no se pasa, se borra el original; si se
    pasa, sobrevive.
- Probar manualmente con 3 audios reales: nota de voz `.m4a`, `.mp4` de
  Zoom, `.wav`. Guardar los tres como fixtures en `Tests/Fixtures/`.
- Cada ejecución debe documentarse (comando usado, stdout completo,
  `result.json` resultante) como evidencia del criterio de aceptación.

### Pista C — Núcleo Swift (Fase 2)

Depende de que el proyecto XcodeGen compile (pista A). No depende del script
real de la pista B.

- **2.1 `PythonPipelineService`** (§4.1): `Process` + pipes async
  (`AsyncStream`), lectura continua de stdout **y** stderr desde el inicio
  (evitar deadlock por buffer lleno), parser de líneas `@@` (ignorar líneas
  sin `@@`), cancelación vía SIGTERM → SIGKILL a los 5 s, workdir en
  `~/Library/Application Support/TheTranscriptor/work/<UUID>/`, limpieza de
  huérfanos al arranque.
  - Para el test de integración **sin esperar a la pista B**: crear
    `Tests/Fixtures/fake_pipeline.py`, un script Python mínimo que emite la
    secuencia `@@PHASE/@@PROGRESS/@@INFO/@@DONE` del contrato y escribe un
    `result.json` de ejemplo. El test dirige `PythonPipelineService` contra
    este fake, verificando parseo de eventos, cancelación y limpieza de
    workdir.
- **2.2** `KeychainService` (§4.3) + `SettingsStore` (§4.5). Unit tests con
  un `service` de Keychain dedicado a test (no contaminar el Keychain real
  de la app). Independiente del resto.
- **2.3** `PythonEnvironmentDetector` + `RequirementsChecker` (§4.4), cada
  check con timeout. Debe detectar el intérprete Python correcto y dar
  resultado en los 4 checks en la máquina de desarrollo. Independiente del
  resto.
- **2.4** Modelos: `TranscriptSegment`, `Transcript` (+`speakerNames`),
  `PipelinePhase`, `WhisperModel`, `RequirementCheck`; `Decodable` para
  `result.json`. Unit tests de decoding. **Debe cerrarse antes que 2.1 y
  2.5**, que dependen de estos tipos.
- **2.5** `TxtExporter` y `SrtExporter` (§5), funciones puras `Transcript →
  String`. Unit tests con un transcript de ejemplo; el `.srt` generado debe
  validarse abriéndolo en un reproductor (VLC).

## 4. Grafo de dependencias y orden de arranque

```
A (Fase 0)
 └─▶ B (Fase 1)         — script real, en paralelo con C
 └─▶ C (Fase 2)
       2.4 ──▶ 2.1
       2.4 ──▶ 2.5
       2.2  (independiente)
       2.3  (independiente)
```

- **A arranca primero** (minutos): B y C necesitan el repo git y la
  estructura de carpetas; C además necesita que el proyecto XcodeGen
  compile antes de poder correr tests.
- **B ∥ C** tras cerrar A: no hay dependencia de datos entre ellas porque C
  usa `fake_pipeline.py`, no el script real.
- Dentro de C: 2.4 (modelos) debe cerrarse antes de 2.1 y 2.5, que
  consumen esos tipos. 2.2 y 2.3 no dependen de nada dentro de la pista.

### Gate de convergencia (final)

Cuando B y C han cerrado, correr un **test de integración E2E** que sustituye
`fake_pipeline.py` por el `transcriptor_local.py` real:

- `PythonPipelineService` ejecuta el script real con un fixture real de la
  pista B.
- La secuencia de eventos `@@` observada coincide con la esperada y
  `result.json` se decodifica correctamente con los modelos de 2.4.
- `--keep-audio` se respeta (verificado en disco).
- Cancelar a mitad de ejecución mata el proceso Python real (verificado con
  `ps`/Activity Monitor) y limpia el workdir.

Este gate es lo que cierra formalmente la Regla 1 del faseado: el trabajo de
Fase 2 se validó contra el contrato desde el principio, y aquí se demuestra
que el contrato y la implementación real coinciden.

## 5. Tabla de tareas

| Id | Pista | Entrada | Salida | Aceptación |
|---|---|---|---|---|
| 0.1 | A | — | Repo git + `.gitignore` | `git status` limpio, sin artefactos de build trackeados |
| 0.2 | A | `project.yml` (XcodeGen) | Proyecto Xcode generado | `xcodebuild -scheme TheTranscriptor build` en verde con "Hello The Transcriptor" |
| 0.3 | A | — | `Views/ Models/ Services/ Resources/` con placeholders | Estructura según §2 |
| 0.4 | A | — | — | **Ya cumplido** por el `CLAUDE.md` existente — no repetir |
| 1.1 | B | Contrato §3.1 | `transcriptor_local.py` con argparse completo | Ejecutable a mano con la firma exacta del contrato |
| 1.2 | B | 1.1 | Protocolo `@@` por stdout, `flush=True` | Con un audio de prueba, stdout muestra la secuencia completa incl. `@@INFO:downloading_models` para ambas descargas |
| 1.3 | B | 1.2 | `result.json` (§3.3) + token vía `HF_TOKEN` | JSON válido con segmentos hablante+texto |
| 1.4 | B | 1.1 | `--keep-audio` | El archivo original sobrevive con el flag; se borra sin él |
| 1.5 | B | 1.1–1.4 | 3 fixtures (`.m4a`/`.mp4`/`.wav`) en `Tests/Fixtures/` | 3 ejecuciones correctas documentadas |
| 2.1 | C | 0.2, 2.4, `fake_pipeline.py` | `PythonPipelineService` | Test de integración contra el fake: secuencia de eventos correcta; cancelación mata el proceso |
| 2.2 | C | 0.2 | `KeychainService` + `SettingsStore` | Unit tests con Keychain de test |
| 2.3 | C | 0.2 | `PythonEnvironmentDetector` + `RequirementsChecker` | Detecta intérprete correcto; los 4 checks dan resultado en este Mac |
| 2.4 | C | 0.2, §3.3 | Modelos + `Decodable` de `result.json` | Unit tests de decoding |
| 2.5 | C | 2.4 | `TxtExporter` + `SrtExporter` | Unit tests con transcript de ejemplo; `.srt` validado en VLC |
| Gate | B+C | 1.5, 2.1 | Integración E2E script real ↔ servicio | Secuencia + `result.json` + `--keep-audio` + cancelación, todo contra el script real |

## 6. Reglas

- **Contrato §3 congelado:** cualquier cambio a la firma CLI, al protocolo
  `@@` o al formato de `result.json` requiere actualizar
  `docs/02-diseno-tecnico.md §3` primero y avisar a la otra pista antes de
  seguir.
- Cada tarea de las pistas A y C termina con `xcodebuild build`/`test` en
  verde. Las tareas de la pista B terminan con una ejecución manual
  documentada (comando, stdout, artefactos generados).
- Convenciones de nombre: producto "The Transcriptor"; identificadores de
  código, target/scheme, bundle id y paths usan `TheTranscriptor`.
- El token HF nunca viaja como argumento de proceso, ni se guarda en
  UserDefaults ni se loguea — solo Keychain (`KeychainService`) y variable
  de entorno `HF_TOKEN` al invocar el script.
- Nadie modifica `transcriptor_local.py` fuera de la pista B sin pasar por
  la regla del contrato congelado de arriba.

## 7. Checklist de cierre

- [x] 0.1 — repo git inicializado, `.gitignore` correcto
- [x] 0.2 — `xcodebuild build` en verde
- [x] 0.3 — estructura de carpetas según §2
- [x] 0.4 — `CLAUDE.md` ya cumple el criterio (heredado)
- [x] 1.1 — `transcriptor_local.py` con CLI del contrato
- [x] 1.2 — protocolo `@@` completo, incl. descarga de modelos
- [x] 1.3 — `result.json` + `HF_TOKEN`
- [x] 1.4 — `--keep-audio` funcional
- [x] 1.5 — 3 fixtures documentadas (sintéticas vía `say`, no grabaciones reales del usuario — ver `Tests/Fixtures/README.md`)
- [x] 2.1 — `PythonPipelineService` con test de integración (fake)
- [x] 2.2 — `KeychainService` + `SettingsStore` con unit tests
- [x] 2.3 — `PythonEnvironmentDetector` + `RequirementsChecker`
- [x] 2.4 — modelos + decoding de `result.json` con unit tests
- [x] 2.5 — `TxtExporter` + `SrtExporter` con unit tests y `.srt` validado
- [x] Gate — integración E2E script real ↔ `PythonPipelineService` (verificado manualmente contra `transcriptor_local.py` real + venv + HF_TOKEN; no forma parte de la suite de tests permanente por depender de red/credenciales locales)
