#!/usr/bin/env python3
"""Minimal fake pipeline used by PythonPipelineServiceTests.

Mimics the stdout protocol described in docs/02-diseno-tecnico.md §3 without
any of the real ML dependencies (faster-whisper / pyannote). Accepts the same
CLI surface as the real transcriptor_local.py so the Swift service can be
exercised end to end.
"""
import argparse
import json
import os
import sys
import time


def emit(line: str) -> None:
    print(line, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--keep-audio", action="store_true")
    parser.add_argument(
        "--slow",
        action="store_true",
        help="Sleep for several seconds mid-run so tests can exercise cancellation.",
    )
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    emit("@@PHASE:CONVERTING")
    time.sleep(0.05)

    emit("@@PHASE:TRANSCRIBING")
    time.sleep(0.05)
    emit("@@PROGRESS:50")
    time.sleep(5.0 if args.slow else 0.05)

    # Library noise without the @@ prefix must be ignored by the parser.
    print("ruido de libreria", flush=True)

    emit("@@INFO:downloading_models")
    time.sleep(0.05)

    emit("@@PHASE:DIARIZING")
    time.sleep(0.05)

    emit("@@PHASE:MERGING")
    time.sleep(0.05)

    result = {
        "language": "es",
        "duration": 12.5,
        "segments": [
            {"start": 0.0, "end": 4.2, "speaker": "SPEAKER_00", "text": "Hola, esto es una prueba."},
            {"start": 4.2, "end": 9.8, "speaker": "SPEAKER_01", "text": "Y esto es una respuesta."},
        ],
    }
    result_path = os.path.join(args.output_dir, "result.json")
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump(result, f)

    if not args.keep_audio:
        try:
            os.remove(args.input)
        except OSError:
            pass

    emit(f"@@DONE:{result_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
