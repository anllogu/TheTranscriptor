import Foundation

enum AppPhase {
    case checkingRequirements([RequirementCheck])
    case idle
    case recording
    case processing(PipelinePhase, progress: Int?, downloading: Bool)
    case result(Transcript)
    case error(PipelineError)
}

@Observable
final class AppState {
    var phase: AppPhase = .idle
    let settings: SettingsStore
    let recorder: AudioRecorderService

    var isSettingUpPython = false
    var setupLog: [String] = []

    private let pipelineService: PythonPipelineService
    private let keychainService: KeychainService
    private let requirementsChecker: RequirementsChecker
    private var pipelineTask: Task<Void, Never>?

    init(
        settings: SettingsStore = SettingsStore(),
        pipelineService: PythonPipelineService = PythonPipelineService(),
        keychainService: KeychainService = KeychainService(),
        requirementsChecker: RequirementsChecker = RequirementsChecker(),
        recorder: AudioRecorderService = AudioRecorderService()
    ) {
        self.settings = settings
        self.pipelineService = pipelineService
        self.keychainService = keychainService
        self.requirementsChecker = requirementsChecker
        self.recorder = recorder
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
                // El token HF es opcional (solo hace falta para modelos con gating);
                // el bloqueo suave (CU-06) es únicamente sobre ffmpeg/Python/paquetes.
                let blocking = results.filter { $0.name != "Token Hugging Face" }
                if blocking.allSatisfy(\.status.isOk) {
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

    func cancelRecording() {
        recorder.cancelAndDelete()
        phase = .idle
    }

    func finishRecording() {
        guard let url = recorder.stop() else {
            phase = .idle
            return
        }
        runPipeline(input: url)
    }

    // MARK: - Pipeline

    func runPipeline(input: URL) {
        guard let scriptPath = bundledScriptURL() else {
            phase = .error(PipelineError(message: "No se encontró el script Python embebido.", stderrTail: []))
            return
        }

        let pipelineSettings = PipelineSettings(
            pythonPath: resolvedPythonPath(),
            scriptPath: scriptPath,
            model: settings.getWhisperModel(),
            keepAudio: !settings.deleteAudioAfter,
            hfToken: keychainService.token()
        )

        phase = .processing(.converting, progress: nil, downloading: false)

        pipelineTask?.cancel()
        pipelineTask = Task { [pipelineService] in
            let stream = pipelineService.run(input: input, settings: pipelineSettings)
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
            if case .processing(_, let progress, let downloading) = phase {
                phase = .processing(p, progress: progress, downloading: downloading)
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
            let transcript = try JSONDecoder().decode(Transcript.self, from: data)
            phase = .result(transcript)
        } catch {
            phase = .error(PipelineError(message: "No se pudo leer el resultado: \(error.localizedDescription)", stderrTail: []))
        }
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
