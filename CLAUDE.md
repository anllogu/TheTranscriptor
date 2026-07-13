# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**The Transcriptor** — native macOS 14+ app (Swift 5.9+, pure SwiftUI, no third-party UI deps) that wraps an existing Python pipeline (faster-whisper + pyannote-audio) for fully local audio transcription with speaker diarization. Personal use, outside the Mac App Store, App Sandbox disabled. UI language and all docs are **Spanish** — keep them that way.

**Current state: docs-only, pre-implementation.** The source of truth lives in `docs/`:

- `docs/01-funcional.md` — functional spec (use cases referenced as CU-xx)
- `docs/02-diseno-tecnico.md` — technical design (sections referenced as §N)
- `docs/03-faseado.md` — phased plan written as agent tasks with explicit acceptance criteria

Naming convention: display/product name is "The Transcriptor"; code identifiers, Xcode target/scheme, bundle id and paths use `TheTranscriptor` (e.g. `com.allosa.TheTranscriptor`, `~/Library/Application Support/TheTranscriptor/`).

## Build & test

The Xcode project doesn't exist yet (created in Fase 0, ideally via XcodeGen `project.yml` so the `.xcodeproj` is regenerable from text). Once it exists:

```sh
xcodebuild -scheme TheTranscriptor build
xcodebuild -scheme TheTranscriptor test
```

Every task must end with a green build (and tests where applicable); acceptance criteria in `03-faseado.md` must be **demonstrated**, not just asserted.

## Architecture (big picture)

The app never does ML itself — it launches the embedded Python script with `Process` and talks to it over a line protocol. **The script contract (§3 of the technical doc) is the interface everything else depends on:**

- **App → script:** CLI args `--input --output-dir --model --json [--keep-audio]`. The HF token goes via the `HF_TOKEN` env var, **never** as an argument (visible in `ps`), never in UserDefaults or logs — Keychain only (`KeychainService`).
- **Script → app:** stdout lines `@@PHASE:…`, `@@PROGRESS:n`, `@@INFO:downloading_models`, `@@DONE:<path>`, `@@ERROR:<msg>` (with `flush=True`). Lines without `@@` are ignored (library noise). Typed result in `result.json` (§3.3); stderr is buffered for the error screen.
- The script ships in `Resources/transcriptor_local.py` and is copied to Application Support on first launch (bundle is read-only); it re-copies when the hash changes.

Swift side:

- **State machine, not navigation:** `AppState.phase` (`@Observable` enum: checkingRequirements / idle / recording / processing / result / error) drives a `switch` in `MainView`. No NavigationStack.
- **Concurrency:** async/await + `AsyncStream` for pipeline events; read stdout *and* stderr pipes continuously from process start (full pipe buffers deadlock the child). Cancel = SIGTERM, then SIGKILL after 5 s.
- **Layout:** `Views/`, `Models/`, `Services/` per §2. Core service is `PythonPipelineService`; exporters (`TxtExporter`, `SrtExporter`) are pure `Transcript → String` functions and unit-tested.
- Speaker renames live in `Transcript.speakerNames` (`"SPEAKER_00" → "Angel"`); original segment data is never mutated.

## Hard rules (from docs/03-faseado.md)

1. No UI work (Fase 3+) starts until the Python script contract (Fase 1) is closed — the contract is the interface for everything else.
2. Don't modify `transcriptor_local.py` outside Fase 1 without updating the contract in `docs/02-diseno-tecnico.md §3`.
3. Privacy: zero network requests from the app itself; the only network use is the Python process downloading models from Hugging Face on first run (surfaced in the UI via the privacy badge).
4. Temp files (recording WAVs, work dirs `App Support/TheTranscriptor/work/<UUID>/`) are always cleaned up — on success, error, cancel, and orphan purge at launch. The original audio file is only deleted when the "Borrar audio" setting is on.

## Gotchas

- GUI apps don't inherit the shell PATH: extend the child process env with `/opt/homebrew/bin:/usr/local/bin`, and detect python/ffmpeg via `/bin/zsh -lc` (§4.4).
- Requirement checks (ffmpeg, python, packages) each run with a 10 s timeout; the app soft-blocks transcription until they pass but must never fail silently.
