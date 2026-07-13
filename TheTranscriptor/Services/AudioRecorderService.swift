import AVFoundation
import Foundation

@Observable
final class AudioRecorderService {
    enum State: Equatable {
        case idle, recording, paused
    }

    enum RecorderError: Error, Equatable {
        case permissionDenied
        case engineFailure(String)
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var outputURL: URL?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var startDate: Date?
    private var pausedElapsed: TimeInterval = 0
    private var lastLevelUpdate: Date = .distantPast
    private var elapsedTickTask: Task<Void, Never>?

    private static let targetSampleRate: Double = 16_000

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    @discardableResult
    func start() throws -> URL {
        let url = Self.recordingsDirectory()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.engineFailure("No se pudo crear el formato de destino")
        }

        do {
            // commonFormat/interleaved deben coincidir con destinationFormat: si no,
            // AVAudioFile.processingFormat difiere del formato de los buffers que
            // le pasamos y write(from:) lanza en el primer buffer grabado.
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: destinationFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw RecorderError.engineFailure(error.localizedDescription)
        }

        outputFormat = destinationFormat
        outputURL = url
        pausedElapsed = 0
        startDate = Date()

        try installTapAndStart()

        state = .recording
        startElapsedTicking()
        return url
    }

    func pause() {
        guard state == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
        stopElapsedTicking()
        if let startDate {
            pausedElapsed += Date().timeIntervalSince(startDate)
        }
        elapsed = pausedElapsed
        startDate = nil
        state = .paused
    }

    func resume() throws {
        guard state == .paused else { return }
        try installTapAndStart()
        startDate = Date()
        state = .recording
        startElapsedTicking()
    }

    @discardableResult
    func stop() -> URL? {
        guard state != .idle else { return outputURL }
        stopElapsedTicking()
        if state == .recording {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        if let startDate {
            pausedElapsed += Date().timeIntervalSince(startDate)
        }
        elapsed = pausedElapsed
        startDate = nil
        state = .idle
        let finishedURL = outputURL
        audioFile = nil
        converter = nil
        return finishedURL
    }

    func cancelAndDelete() {
        _ = stop()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsed = 0
        level = 0
    }

    private func startElapsedTicking() {
        elapsedTickTask?.cancel()
        elapsedTickTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .recording {
                if let startDate = self.startDate {
                    self.elapsed = self.pausedElapsed + Date().timeIntervalSince(startDate)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopElapsedTicking() {
        elapsedTickTask?.cancel()
        elapsedTickTask = nil
    }

    // MARK: - Private

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        guard let destinationFormat = outputFormat else {
            throw RecorderError.engineFailure("Formato de destino no inicializado")
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: destinationFormat) else {
            throw RecorderError.engineFailure("No se pudo crear el conversor de audio")
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, hardwareFormat: hardwareFormat, destinationFormat: destinationFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecorderError.engineFailure(error.localizedDescription)
        }
    }

    private func process(buffer: AVAudioPCMBuffer, hardwareFormat: AVAudioFormat, destinationFormat: AVAudioFormat) {
        updateLevel(from: buffer)

        guard let converter, let audioFile else { return }

        let ratio = destinationFormat.sampleRate / hardwareFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error == nil, outBuffer.frameLength > 0 {
            try? audioFile.write(from: outBuffer)
        }
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) >= 0.05 else { return }
        lastLevelUpdate = now

        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            sum += samples[i] * samples[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let dbfs = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (dbfs + 60) / 60))
        // El tap corre en el hilo de audio real-time; publicar en MainActor
        // porque `level` es @Observable y lo lee la UI.
        Task { @MainActor [weak self] in
            self?.level = normalized
        }
    }

    static func recordingsDirectory() -> URL {
        let dir = PythonPipelineService.applicationSupportDirectory()
            .appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
