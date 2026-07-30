#!/usr/bin/env python3
"""transcriptor_local.py — pipeline local de transcripción + diarización.

Contrato: docs/02-diseno-tecnico.md §3. Implementa:

    ffmpeg (normalización) -> faster-whisper (transcripción)
        -> pyannote-audio (diarización) -> merge por hablante

Invocación (modo una pista):

    python3 transcriptor_local.py \
        --input <ruta_audio> \
        --output-dir <dir_resultados> \
        --model <tiny|base|small|medium|large-v3> \
        [--language <auto|es|en>] \
        --json \
        [--keep-audio]

Invocación (modo dos pistas — grabación de reunión, §3.4):

    python3 transcriptor_local.py \
        --input-mic <mic.wav> --input-system <system.wav> \
        [--mic-offset <seg>] [--system-offset <seg>] \
        --output-dir <dir_resultados> \
        --model <...> [--language <auto|es|en>] --json [--keep-audio]

    En modo dos pistas la pista de micrófono se transcribe y se etiqueta ENTERA
    como SPEAKER_00 (voz local = "Yo", sin diarización), y la pista del sistema
    pasa por el flujo completo (transcribe -> pyannote -> merge) para separar
    varios interlocutores remotos; sus etiquetas se renumeran a SPEAKER_01,
    SPEAKER_02, ... por orden de aparición para no colisionar con el micrófono.
    Ambas listas de segmentos se fusionan ordenadas por 'start' (tras aplicar
    los offsets por pista). Requiere HF_TOKEN (usa pyannote sobre el sistema).
    El result.json resultante tiene EXACTAMENTE el mismo formato que el modo de
    una pista (§3.3).

Protocolo de progreso por stdout (líneas con flush=True SIEMPRE):

    @@PHASE:CONVERTING
    @@PHASE:TRANSCRIBING
    @@PROGRESS:42
    @@PHASE:DIARIZING
    @@INFO:downloading_models
    @@PROGRESS:17                  (0-50 ~ paso "segmentation", 50-100 ~ "embeddings";
                                     heurística, no un % real de pipeline completo)
    @@INFO:diarizing_step:<nombre> (pasos internos sin progreso medible, p.ej. clustering)
    @@PHASE:MERGING
    @@DONE:<ruta_result.json>
    @@ERROR:<mensaje breve>   (y exit code != 0; detalle completo por stderr)

@@PROGRESS siempre se reinicia (nueva escala 0-100) al cambiar de @@PHASE:
transcribing y diarizing tienen cada una su propia noción de "42%", no son
acumulativas.

El token de Hugging Face se lee EXCLUSIVAMENTE de la variable de entorno
HF_TOKEN — nunca de argumentos CLI (visibles en `ps aux`).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import traceback
import uuid

MODEL_CHOICES = ["tiny", "base", "small", "medium", "large-v3"]

# Códigos de idioma admitidos por --language. "auto" (o el argumento ausente)
# deja que faster-whisper autodetecte el idioma; cualquier otro valor lo fuerza,
# lo que mejora la exactitud cuando la autodetección se equivoca (p. ej. audio en
# español detectado como euskera). Ver contrato §3.
LANGUAGE_CHOICES = ["auto", "es", "en"]


def emit(line: str) -> None:
    """Imprime una línea del protocolo @@ con flush inmediato."""
    print(line, flush=True)


def emit_phase(phase: str) -> None:
    emit(f"@@PHASE:{phase}")


def emit_progress(pct: int) -> None:
    pct = max(0, min(100, int(pct)))
    emit(f"@@PROGRESS:{pct}")


def emit_info(info: str) -> None:
    emit(f"@@INFO:{info}")


def emit_done(result_path: str) -> None:
    emit(f"@@DONE:{result_path}")


def emit_error(message: str) -> None:
    # Mensaje breve por stdout (protocolo); el detalle completo va a stderr
    # por separado (ver main()).
    short = message.strip().splitlines()[0] if message.strip() else "error desconocido"
    emit(f"@@ERROR:{short}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="transcriptor_local.py",
        description="Transcripción + diarización local (faster-whisper + pyannote-audio).",
    )
    parser.add_argument("--input", required=False, help="Ruta al archivo de audio de entrada (modo una pista)")
    parser.add_argument(
        "--input-mic",
        dest="input_mic",
        required=False,
        help="Modo dos pistas: ruta al audio del micrófono (voz local = 'Yo')",
    )
    parser.add_argument(
        "--input-system",
        dest="input_system",
        required=False,
        help="Modo dos pistas: ruta al audio del sistema (voces remotas, diarizadas)",
    )
    parser.add_argument(
        "--mic-offset",
        dest="mic_offset",
        type=float,
        default=0.0,
        help="Desplazamiento en segundos a sumar a los tiempos de la pista de micrófono",
    )
    parser.add_argument(
        "--system-offset",
        dest="system_offset",
        type=float,
        default=0.0,
        help="Desplazamiento en segundos a sumar a los tiempos de la pista del sistema",
    )
    parser.add_argument("--output-dir", required=True, help="Directorio de resultados")
    parser.add_argument(
        "--model",
        required=True,
        choices=MODEL_CHOICES,
        help="Modelo whisper a usar",
    )
    parser.add_argument(
        "--language",
        required=False,
        default="auto",
        choices=LANGUAGE_CHOICES,
        help=(
            "Idioma de entrada. 'auto' (por defecto) autodetecta; un código "
            "ISO (es, en) lo fuerza para mejorar la exactitud."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="emit_json",
        help="Además del .txt, emite result.json",
    )
    parser.add_argument(
        "--keep-audio",
        action="store_true",
        help="No borrar el archivo de audio original al terminar",
    )
    return parser.parse_args(argv)


def convert_to_wav(input_path: str, work_dir: str) -> str:
    """Normaliza el audio de entrada a WAV 16kHz mono PCM16 con ffmpeg."""
    emit_phase("CONVERTING")
    out_path = os.path.join(work_dir, f"normalized_{uuid.uuid4().hex}.wav")
    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        input_path,
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        out_path,
    ]
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg falló (exit {proc.returncode}) al convertir el audio:\n{proc.stderr}"
        )
    if not os.path.exists(out_path):
        raise RuntimeError("ffmpeg no produjo el archivo WAV esperado")
    return out_path


def transcribe(
    wav_path: str, model_name: str, language: str | None = None
) -> tuple[str, float, list[dict]]:
    """Transcribe con faster-whisper. Devuelve (idioma, duración, segmentos).

    Si `language` es None o "auto", faster-whisper autodetecta el idioma; si es
    un código ISO (p. ej. "es"), lo fuerza para mejorar la exactitud."""
    emit_phase("TRANSCRIBING")

    # faster-whisper descarga el modelo la primera vez que se instancia;
    # no hay un hook de progreso de descarga expuesto por la librería, así
    # que emitimos @@INFO:downloading_models antes de instanciar cuando el
    # modelo todavía no está cacheado localmente.
    if not _whisper_model_cached(model_name):
        emit_info("downloading_models")

    from faster_whisper import WhisperModel

    whisper_model = WhisperModel(model_name, device="auto", compute_type="auto")

    forced_language = language if language and language != "auto" else None
    segments_iter, info = whisper_model.transcribe(
        wav_path, beam_size=5, language=forced_language
    )

    duration = float(info.duration) if info.duration else 0.0
    language = info.language or "es"

    segments: list[dict] = []
    for seg in segments_iter:
        segments.append(
            {
                "start": float(seg.start),
                "end": float(seg.end),
                "text": seg.text.strip(),
            }
        )
        if duration > 0:
            pct = int(min(seg.end, duration) / duration * 100)
            emit_progress(pct)

    return language, duration, segments


def _whisper_model_cached(model_name: str) -> bool:
    """Heurística: ¿ya existe el modelo en la caché local de HF/faster-whisper?"""
    try:
        from huggingface_hub import scan_cache_dir

        cache_info = scan_cache_dir()
        needle = f"whisper-{model_name}" if not model_name.startswith("whisper") else model_name
        for repo in cache_info.repos:
            if needle in repo.repo_id or model_name in repo.repo_id:
                return True
        return False
    except Exception:
        # Si no se puede determinar, asumimos que no está cacheado y avisamos
        # de todas formas (mejor un falso "descargando" que silencio).
        return False


# pyannote no expone un % global de progreso, solo completed/total por paso
# interno del pipeline (segmentation, embeddings, clustering, ...) vía su
# sistema de Hook. Los dos pasos que escalan con la duración del audio -y
# que dominan el tiempo real en audio largo- son segmentation y embeddings;
# los mapeamos a los tramos 0-50%/50-100% de @@PROGRESS. El resto de pasos
# (típicamente instantáneos) solo se registran como @@INFO para dejar
# constancia de que el proceso sigue vivo, sin mover el porcentaje.
_DIARIZE_STEP_SPANS = {
    "segmentation": (0, 50),
    "embeddings": (50, 100),
}


class _DiarizationProgressHook:
    """Hook duck-tipado que pyannote llama como `hook(step_name, step_artifact,
    file=..., total=..., completed=...)` (ver `Pipeline.setup_hook` en
    pyannote.audio.core.pipeline) — no hereda de una clase base porque
    pyannote no expone ninguna."""

    def __call__(self, step_name, step_artifact, file=None, total=None, completed=None):
        span = _DIARIZE_STEP_SPANS.get(step_name)
        if span and total and completed is not None:
            lo, hi = span
            emit_progress(lo + int(completed / total * (hi - lo)))
        else:
            emit_info(f"diarizing_step:{step_name}")


def diarize(wav_path: str, hf_token: str | None) -> list[dict]:
    """Diariza con pyannote-audio. Devuelve lista de turnos {start, end, speaker}."""
    emit_phase("DIARIZING")

    if not hf_token:
        raise RuntimeError(
            "Falta HF_TOKEN: la diarización requiere un token de Hugging Face "
            "con acceso al modelo gated pyannote/speaker-diarization-3.1. "
            "Define la variable de entorno HF_TOKEN."
        )

    if not _pyannote_model_cached():
        emit_info("downloading_models")

    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=hf_token,
    )
    if pipeline is None:
        raise RuntimeError(
            "No se pudo cargar pyannote/speaker-diarization-3.1: revisa que "
            "el token HF_TOKEN tenga acceso aceptado a las condiciones del "
            "modelo en huggingface.co."
        )

    output = pipeline(wav_path, hook=_DiarizationProgressHook())

    # Versiones recientes de pyannote.audio (>=4) devuelven un DiarizeOutput
    # con la Annotation bajo .speaker_diarization / .exclusive_speaker_diarization
    # (esta última sin solapes, mejor para casar con segmentos de whisper).
    # Versiones antiguas devolvían directamente una Annotation con .itertracks().
    if hasattr(output, "itertracks"):
        annotation = output
    else:
        annotation = getattr(output, "exclusive_speaker_diarization", None) or getattr(
            output, "speaker_diarization"
        )

    turns: list[dict] = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({"start": float(turn.start), "end": float(turn.end), "speaker": speaker})
    return turns


def _pyannote_model_cached() -> bool:
    try:
        from huggingface_hub import scan_cache_dir

        cache_info = scan_cache_dir()
        for repo in cache_info.repos:
            if "speaker-diarization" in repo.repo_id or "pyannote" in repo.repo_id:
                return True
        return False
    except Exception:
        return False


def merge_segments(
    whisper_segments: list[dict], diarization_turns: list[dict]
) -> list[dict]:
    """Asigna hablante a cada segmento de whisper por solapamiento temporal.

    Si no hay turnos de diarización (p.ej. no se ejecutó diarización),
    todos los segmentos se etiquetan como SPEAKER_00.
    """
    emit_phase("MERGING")

    merged: list[dict] = []
    for seg in whisper_segments:
        speaker = _speaker_for_segment(seg, diarization_turns)
        merged.append(
            {
                "start": seg["start"],
                "end": seg["end"],
                "speaker": speaker,
                "text": seg["text"],
            }
        )
    return merged


def _speaker_for_segment(seg: dict, turns: list[dict]) -> str:
    if not turns:
        return "SPEAKER_00"

    best_speaker = None
    best_overlap = -1.0
    for turn in turns:
        overlap = min(seg["end"], turn["end"]) - max(seg["start"], turn["start"])
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = turn["speaker"]

    if best_speaker is None or best_overlap <= 0:
        # Sin solapamiento con ningún turno: usar el turno más cercano.
        mid = (seg["start"] + seg["end"]) / 2
        best_speaker = min(
            turns, key=lambda t: min(abs(mid - t["start"]), abs(mid - t["end"]))
        )["speaker"]

    return best_speaker


def write_txt(segments: list[dict], txt_path: str) -> None:
    lines = []
    for seg in segments:
        lines.append(f"[{seg['speaker']}] {seg['text']}")
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def write_result_json(
    language: str, duration: float, segments: list[dict], json_path: str
) -> None:
    result = {"language": language, "duration": duration, "segments": segments}
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


def _apply_offset(segments: list[dict], offset: float) -> None:
    """Suma `offset` (segundos) a los tiempos de cada segmento in-place."""
    if not offset:
        return
    for seg in segments:
        seg["start"] = seg["start"] + offset
        seg["end"] = seg["end"] + offset


def _relabel_speakers(segments: list[dict], start_index: int) -> None:
    """Renumera las etiquetas de hablante a SPEAKER_<start_index+n> por orden
    de primera aparición, in-place. Evita colisiones con la pista de micro."""
    mapping: dict[str, str] = {}
    next_index = start_index
    for seg in segments:
        original = seg["speaker"]
        if original not in mapping:
            mapping[original] = f"SPEAKER_{next_index:02d}"
            next_index += 1
        seg["speaker"] = mapping[original]


def run_dual_track(args: argparse.Namespace, hf_token: str | None) -> str:
    """Pipeline de dos pistas (grabación de reunión). Devuelve la ruta del
    resultado (result.json o result.txt). Ver contrato §3.4."""
    output_dir = os.path.abspath(args.output_dir)

    mic_path = os.path.abspath(args.input_mic)
    system_path = os.path.abspath(args.input_system)

    # --- Pista de micrófono: transcripción sin diarización, todo SPEAKER_00 ---
    mic_wav = convert_to_wav(mic_path, output_dir)
    try:
        mic_language, mic_duration, mic_segments = transcribe(mic_wav, args.model, args.language)
    finally:
        if os.path.exists(mic_wav):
            try:
                os.remove(mic_wav)
            except OSError:
                pass
    for seg in mic_segments:
        seg["speaker"] = "SPEAKER_00"
    _apply_offset(mic_segments, args.mic_offset)

    # --- Pista del sistema: transcripción + diarización pyannote ---
    system_wav = convert_to_wav(system_path, output_dir)
    try:
        system_language, system_duration, system_whisper = transcribe(system_wav, args.model, args.language)
        system_turns = diarize(system_wav, hf_token)
    finally:
        if os.path.exists(system_wav):
            try:
                os.remove(system_wav)
            except OSError:
                pass
    system_segments = merge_segments(system_whisper, system_turns)
    # Renumerar SPEAKER_00+ de pyannote a SPEAKER_01+ para no pisar el micro.
    _relabel_speakers(system_segments, start_index=1)
    _apply_offset(system_segments, args.system_offset)

    # --- Fusión por tiempo en una sola transcripción ---
    emit_phase("MERGING")
    merged = sorted(mic_segments + system_segments, key=lambda s: s["start"])

    language = mic_language or system_language or "es"
    duration = max(
        [s["end"] for s in merged] + [mic_duration, system_duration, 0.0]
    )

    txt_path = os.path.join(output_dir, "result.txt")
    write_txt(merged, txt_path)

    result_path = txt_path
    if args.emit_json:
        json_path = os.path.join(output_dir, "result.json")
        write_result_json(language, duration, merged, json_path)
        result_path = json_path

    # Limpieza de los audios originales (respeta --keep-audio).
    if not args.keep_audio:
        for original in (mic_path, system_path):
            if os.path.exists(original):
                try:
                    os.remove(original)
                except OSError as exc:
                    print(f"Aviso: no se pudo borrar el audio original: {exc}", file=sys.stderr)

    return result_path


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    hf_token = os.environ.get("HF_TOKEN")  # SOLO desde entorno, nunca CLI

    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    dual_track = bool(args.input_mic or args.input_system)

    if dual_track:
        # Validación de argumentos de modo dos pistas.
        if not (args.input_mic and args.input_system):
            emit_error("El modo dos pistas requiere --input-mic y --input-system")
            print("Faltan --input-mic/--input-system", file=sys.stderr)
            return 1
        if args.input:
            emit_error("--input no puede combinarse con --input-mic/--input-system")
            print("--input es incompatible con el modo dos pistas", file=sys.stderr)
            return 1
        for label, path in (("micrófono", args.input_mic), ("sistema", args.input_system)):
            if not os.path.isfile(os.path.abspath(path)):
                emit_error(f"El archivo de {label} no existe: {path}")
                print(f"Archivo de {label} no encontrado: {path}", file=sys.stderr)
                return 1
        try:
            result_path = run_dual_track(args, hf_token)
            emit_done(result_path)
            return 0
        except Exception as exc:  # noqa: BLE001 - capturar todo y reportar
            emit_error(str(exc))
            traceback.print_exc(file=sys.stderr)
            return 1

    if not args.input:
        emit_error("Falta --input (o --input-mic/--input-system para modo dos pistas)")
        print("No se indicó --input", file=sys.stderr)
        return 1

    input_path = os.path.abspath(args.input)

    if not os.path.isfile(input_path):
        emit_error(f"El archivo de entrada no existe: {input_path}")
        print(f"Archivo de entrada no encontrado: {input_path}", file=sys.stderr)
        return 1

    wav_path = None
    try:
        wav_path = convert_to_wav(input_path, output_dir)

        language, duration, whisper_segments = transcribe(wav_path, args.model, args.language)

        diarization_turns = diarize(wav_path, hf_token)

        merged = merge_segments(whisper_segments, diarization_turns)

        txt_path = os.path.join(output_dir, "result.txt")
        write_txt(merged, txt_path)

        result_path = txt_path
        if args.emit_json:
            json_path = os.path.join(output_dir, "result.json")
            write_result_json(language, duration, merged, json_path)
            result_path = json_path

        emit_done(result_path)
        return 0

    except Exception as exc:  # noqa: BLE001 - queremos capturar todo y reportar
        emit_error(str(exc))
        traceback.print_exc(file=sys.stderr)
        return 1

    finally:
        # Limpieza: WAV normalizado temporal siempre se borra.
        if wav_path and os.path.exists(wav_path):
            try:
                os.remove(wav_path)
            except OSError:
                pass

        # El audio original solo se borra si NO se pidió --keep-audio,
        # y solo si el pipeline llegó a producir algo utilizable de él
        # (se borra siempre que no haya --keep-audio, según contrato §3.1:
        # "NO borrar el original" es el comportamiento con el flag activo).
        if not args.keep_audio and os.path.exists(input_path):
            try:
                os.remove(input_path)
            except OSError as exc:
                print(f"Aviso: no se pudo borrar el audio original: {exc}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
