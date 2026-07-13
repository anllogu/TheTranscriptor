# Fixtures de audio — Tarea 1.5

## Origen de los fixtures

**Estos 3 audios son sintéticos, generados con `say` (macOS) + `ffmpeg`, no
grabaciones reales del usuario.** No hubo acceso a notas de voz de iPhone ni
grabaciones de Zoom reales durante esta sesión. Se documenta como desviación
explícita del criterio original ("3 audios reales"): se priorizó validar el
contrato §3 punta a punta (incl. transcripción y diarización reales contra
los modelos de Hugging Face) sobre esperar a fixtures reales. Si en el futuro
se sustituyen por grabaciones reales, basta con repetir las ejecuciones de
abajo con los nuevos archivos.

- `nota_voz.m4a` — un solo hablante (voz "Mónica" es_ES), simula nota de voz.
- `reunion_zoom.mp4` — dos hablantes alternando (voces "Mónica"/"Paulina"),
  vídeo negro estático 320×240 1fps + audio, simula grabación de Zoom.
- `audio_prueba.wav` — un solo hablante (voz "Paulina" es_ES), formato WAV directo.

## Ejecuciones documentadas (2026-07-12)

Script real: `Resources/transcriptor_local.py`. Intérprete:
`.venv-script/bin/python3` (Python 3.11.14, venv gestionado con `uv`,
`faster-whisper` + `pyannote.audio` instalados). `HF_TOKEN` exportado en el
entorno con acceso aceptado a `pyannote/speaker-diarization-3.1`,
`pyannote/segmentation-3.0` y `pyannote/speaker-diarization-community-1`
(dependencias gated encadenadas del pipeline de diarización).

### 1. `nota_voz.m4a` (con `--keep-audio`)

```
python3 Resources/transcriptor_local.py --input nota_voz.m4a --output-dir <dir> --model tiny --json --keep-audio
```

stdout:
```
@@PHASE:CONVERTING
@@PHASE:TRANSCRIBING
@@PROGRESS:37
@@PROGRESS:99
@@PHASE:DIARIZING
@@PHASE:MERGING
@@DONE:<dir>/result.json
```
Exit code: 0. Original conservado (verificado en disco). `result.json`:
idioma `es`, 2 segmentos, 1 hablante (`SPEAKER_00`), texto reconocible
("Hola, esto es una nota de voz de prueba...").

### 2. `reunion_zoom.mp4` (sin `--keep-audio`)

```
python3 Resources/transcriptor_local.py --input reunion_zoom.mp4 --output-dir <dir> --model tiny --json
```

stdout:
```
@@PHASE:CONVERTING
@@PHASE:TRANSCRIBING
@@PROGRESS:39
@@PROGRESS:82
@@PROGRESS:100
@@PHASE:DIARIZING
@@PHASE:MERGING
@@DONE:<dir>/result.json
```
Exit code: 0. Original **borrado** correctamente (verificado en disco, sin
`--keep-audio`). `result.json`: idioma `es`, 3 segmentos, **2 hablantes
distintos detectados** (`SPEAKER_00`/`SPEAKER_01`), confirmando diarización
real funcionando (los límites de segmento no coinciden exactamente con los
turnos de habla porque whisper segmenta por frase, no por hablante — es una
limitación esperada del merge por solapamiento, no un fallo del contrato).

### 3. `audio_prueba.wav` (con `--keep-audio`)

```
python3 Resources/transcriptor_local.py --input audio_prueba.wav --output-dir <dir> --model tiny --json --keep-audio
```

stdout:
```
@@PHASE:CONVERTING
@@PHASE:TRANSCRIBING
@@PROGRESS:99
@@PHASE:DIARIZING
@@PHASE:MERGING
@@DONE:<dir>/result.json
```
Exit code: 0. Original conservado. `result.json` y `.txt` generados
correctamente, 1 segmento, 1 hablante.

## Bugs de compatibilidad de versión corregidos durante estas pruebas

El contrato §3 no cambió; se corrigieron dos incompatibilidades de la
versión instalada de `pyannote.audio` (>=4) respecto a la API que el script
asumía inicialmente:

1. `Pipeline.from_pretrained(..., use_auth_token=...)` → el kwarg se llama
   ahora `token=`.
2. El pipeline ya no devuelve una `Annotation` directamente sino un
   `DiarizeOutput` con `.speaker_diarization` / `.exclusive_speaker_diarization`.
   Se usa `.exclusive_speaker_diarization` (sin solapes) cuando está
   disponible, con fallback a `.itertracks()` directo para compatibilidad
   con versiones antiguas.

## Pendiente

- Sustituir por audios reales del usuario si se quiere cumplir el criterio
  original al pie de la letra.
- Validar con audios más largos (>1h) para robustez de memoria/rendimiento
  (fuera de alcance de esta sesión).
