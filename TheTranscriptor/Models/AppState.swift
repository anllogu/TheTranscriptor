import Foundation

enum AppPhase {
    case checkingRequirements([RequirementCheck])
    case idle
    case recording
    case processing(PipelinePhase, progress: Int?, downloading: Bool)
    case result(HistoryEntry)
    case error(PipelineError)
}

enum RecordingMode {
    case microphone
    case meeting
}

@Observable
final class AppState {
    var phase: AppPhase = .idle
    var recordingMode: RecordingMode = .microphone
    let settings: SettingsStore
    let recorder: AudioRecorderService
    let meetingRecorder: MeetingRecorderService

    var isSettingUpPython = false
    var setupLog: [String] = []

    private let pipelineService: PythonPipelineService
    private let keychainService: KeychainService
    private let requirementsChecker: RequirementsChecker
    private let historyStore: HistoryStore
    private var pipelineTask: Task<Void, Never>?
    private var currentInput: URL?
    private var currentModel: WhisperModel?
    private var currentIsMeeting = false

    init(
        settings: SettingsStore = SettingsStore(),
        pipelineService: PythonPipelineService = PythonPipelineService(),
        keychainService: KeychainService = KeychainService(),
        requirementsChecker: RequirementsChecker = RequirementsChecker(),
        historyStore: HistoryStore = .shared,
        recorder: AudioRecorderService = AudioRecorderService(),
        meetingRecorder: MeetingRecorderService? = nil
    ) {
        self.settings = settings
        self.pipelineService = pipelineService
        self.keychainService = keychainService
        self.requirementsChecker = requirementsChecker
        self.historyStore = historyStore
        self.recorder = recorder
        // Comparte el mismo AudioRecorderService para no crear un segundo
        // AVAudioEngine en el arranque (los modos micro/reunión no son
        // concurrentes).
        self.meetingRecorder = meetingRecorder ?? MeetingRecorderService(mic: recorder)
    }

    // MARK: - Aprovisionamiento automático de Python

    func runAutomaticPythonSetup() {
        guard !isSettingUpPython else { return }
        isSettingUpPython = true
        setupLog = []
        Task {
            let stream = PythonSetupService().setup()
            for await event in stream {
                await handle(setupEvent: event)
            }
        }
    }

    @MainActor
    private func handle(setupEvent: PythonSetupService.Event) {
        switch setupEvent {
        case .log(let line):
            setupLog.append(line)
        case .done(let pythonPath):
            settings.pythonPath = pythonPath
            isSettingUpPython = false
            checkRequirements()
        case .failed(let message):
            setupLog.append("Error: \(message)")
            isSettingUpPython = false
        }
    }

    // MARK: - Requisitos

    func checkRequirements() {
        let pythonPath = settings.pythonPath.isEmpty ? nil : settings.pythonPath
        let token = keychainService.token()
        phase = .checkingRequirements([])
        Task.detached(priority: .utility) { [requirementsChecker] in
            let results = requirementsChecker.checkRequirements(
                pythonPath: pythonPath,
                huggingFaceToken: token
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if results.allSatisfy(\.status.isOk) {
                    self.phase = .idle
                } else {
                    self.phase = .checkingRequirements(results)
                }
            }
        }
    }

    // MARK: - Grabación

    func beginRecording() {
        phase = .recording
    }

    func beginRecording(mode: RecordingMode = .microphone) {
        recordingMode = mode
        phase = .recording
    }

    func cancelRecording() {
        switch recordingMode {
        case .microphone:
            recorder.cancelAndDelete()
        case .meeting:
            meetingRecorder.cancelAndDelete()
        }
        phase = .idle
    }

    func finishRecording() {
        switch recordingMode {
        case .microphone:
            guard let url = recorder.stop() else {
                phase = .idle
                return
            }
            runPipeline(input: url)
        case .meeting:
            guard let result = meetingRecorder.stop() else {
                phase = .idle
                return
            }
            runMeetingPipeline(result: result)
        }
    }

    // MARK: - Pipeline

    func runPipeline(input: URL) {
        guard let scriptPath = bundledScriptURL() else {
            phase = .error(PipelineError(message: "No se encontró el script Python embebido.", stderrTail: []))
            return
        }

        let model = settings.getWhisperModel()
        let pipelineSettings = PipelineSettings(
            pythonPath: resolvedPythonPath(),
            scriptPath: scriptPath,
            model: model,
            keepAudio: !settings.deleteAudioAfter,
            hfToken: keychainService.token()
        )

        currentInput = input
        currentModel = model
        currentIsMeeting = false
        phase = .processing(.converting, progress: nil, downloading: false)

        pipelineTask?.cancel()
        pipelineTask = Task { [pipelineService] in
            let stream = pipelineService.run(input: input, settings: pipelineSettings)
            for await event in stream {
                await handle(event: event)
            }
        }
    }

    func runMeetingPipeline(result: MeetingRecorderService.Result) {
        guard let scriptPath = bundledScriptURL() else {
            phase = .error(PipelineError(message: "No se encontró el script Python embebido.", stderrTail: []))
            return
        }

        let model = settings.getWhisperModel()
        let pipelineSettings = PipelineSettings(
            pythonPath: resolvedPythonPath(),
            scriptPath: scriptPath,
            model: model,
            keepAudio: !settings.deleteAudioAfter,
            hfToken: keychainService.token()
        )

        currentInput = result.micURL
        currentModel = model
        currentIsMeeting = true
        phase = .processing(.converting, progress: nil, downloading: false)

        pipelineTask?.cancel()
        pipelineTask = Task { [pipelineService] in
            let stream = pipelineService.run(
                dualTrack: result.micURL,
                system: result.systemURL,
                micOffset: result.micOffset,
                systemOffset: result.systemOffset,
                settings: pipelineSettings
            )
            for await event in stream {
                await handle(event: event)
            }
        }
    }

    func cancelPipeline() {
        pipelineService.cancel()
    }

    func retry() {
        phase = .idle
    }

    func reset() {
        phase = .idle
    }

    @MainActor
    private func handle(event: PythonPipelineService.Event) {
        switch event {
        case .phase(let p):
            // Progress is per-phase (whisper vs. pyannote each emit their own
            // @@PROGRESS from 0); carrying over the previous phase's value
            // made a DIARIZING start show a stale 100% left over from
            // TRANSCRIBING, looking finished/stuck when it had barely begun.
            if case .processing(_, _, let downloading) = phase {
                phase = .processing(p, progress: nil, downloading: downloading)
            } else {
                phase = .processing(p, progress: nil, downloading: false)
            }
        case .progress(let n):
            if case .processing(let p, _, let downloading) = phase {
                phase = .processing(p, progress: n, downloading: downloading)
            }
        case .downloadingModels:
            if case .processing(let p, let progress, _) = phase {
                phase = .processing(p, progress: progress, downloading: true)
            }
        case .done(let resultURL):
            decodeAndShowResult(from: resultURL)
        case .failed(let error):
            phase = .error(error)
        }
    }

    private func decodeAndShowResult(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var transcript = try JSONDecoder().decode(Transcript.self, from: data)
            if currentIsMeeting {
                transcript.speakerNames = Self.defaultMeetingSpeakerNames(for: transcript)
            }
            let entry = HistoryEntry(
                sourceFileName: currentIsMeeting
                    ? "Reunión"
                    : (currentInput?.lastPathComponent ?? "audio"),
                sourceAudioPath: currentIsMeeting ? nil : currentInput?.path,
                whisperModel: (currentModel ?? settings.getWhisperModel()).rawValue,
                transcript: transcript
            )
            // Guardado best-effort: si falla (disco lleno, permisos, etc.)
            // no debe impedir que el usuario vea/exporte el resultado.
            historyStore.save(entry)
            phase = .result(entry)
        } catch {
            phase = .error(PipelineError(message: "No se pudo leer el resultado: \(error.localizedDescription)", stderrTail: []))
        }
    }

    /// Nombres por defecto para una grabación de reunión: la pista de micro
    /// (SPEAKER_00) es "Yo" y cada voz remota distinta (SPEAKER_01, …) se
    /// numera "Interlocutor 1", "Interlocutor 2", … por orden de aparición.
    /// El usuario puede renombrarlos después como en cualquier transcripción.
    static func defaultMeetingSpeakerNames(for transcript: Transcript) -> [String: String] {
        var names: [String: String] = [:]
        var seen = Set<String>()
        var interlocutorIndex = 1
        for segment in transcript.segments {
            let speaker = segment.speaker
            guard !seen.contains(speaker) else { continue }
            seen.insert(speaker)
            if speaker == "SPEAKER_00" {
                names[speaker] = "Yo"
            } else {
                names[speaker] = "Interlocutor \(interlocutorIndex)"
                interlocutorIndex += 1
            }
        }
        return names
    }

    // MARK: - Helpers

    private func bundledScriptURL() -> URL? {
        Bundle.main.url(forResource: "transcriptor_local", withExtension: "py")
    }

    private func resolvedPythonPath() -> String {
        if !settings.pythonPath.isEmpty {
            return settings.pythonPath
        }
        return PythonEnvironmentDetector().detectPythonPath() ?? "/usr/bin/python3"
    }
}
