import AVFoundation
import CoreAudio
import Foundation

/// Captura TODO el audio de salida del sistema (altavoces) usando *Core Audio
/// process taps* (`AudioHardwareCreateProcessTap`, macOS 14.4+) sobre un
/// *aggregate device* privado — sin dispositivo virtual ni extensión de
/// kernel. Escribe la pista a un WAV mono 16 kHz PCM16, mismo contrato de
/// audio que `AudioRecorderService` para que el script lo consuma igual.
///
/// Es la mitad "sistema" de la grabación de reunión (§3.4); la mitad "micro"
/// la sigue aportando `AudioRecorderService`. `MeetingRecorderService`
/// coordina ambas.
@Observable
final class SystemAudioRecorderService {
    enum State: Equatable {
        case idle, recording
    }

    enum RecorderError: Error, Equatable {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case formatUnavailable
        case converterUnavailable
        case ioProcFailed(OSStatus)
        case fileCreationFailed(String)
        case startFailed(OSStatus)
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0
    private(set) var outputURL: URL?

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var lastLevelUpdate: Date = .distantPast

    private static let targetSampleRate: Double = 16_000

    @discardableResult
    func start() throws -> URL {
        let url = AudioRecorderService.recordingsDirectory()
            .appendingPathComponent("system-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.formatUnavailable
        }
        outputFormat = destinationFormat

        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: destinationFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw RecorderError.fileCreationFailed(error.localizedDescription)
        }

        try createTap()
        try readTapInputFormat()
        try createAggregateDevice()

        guard let inputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: destinationFormat) else {
            cleanupCoreAudio()
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        try installIOProc()

        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanupCoreAudio()
            throw RecorderError.startFailed(status)
        }

        outputURL = url
        state = .recording
        return url
    }

    @discardableResult
    func stop() -> URL? {
        guard state == .recording else { return outputURL }
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        cleanupCoreAudio()
        audioFile = nil
        converter = nil
        state = .idle
        level = 0
        return outputURL
    }

    func cancelAndDelete() {
        _ = stop()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    // MARK: - Core Audio setup

    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        // No silenciar la salida: el usuario debe seguir oyendo la reunión.
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "TheTranscriptor System Tap"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw RecorderError.tapCreationFailed(status)
        }
        tapID = newTapID
    }

    private func readTapInputFormat() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanupCoreAudio()
            throw RecorderError.formatUnavailable
        }
        inputFormat = format
    }

    private func createAggregateDevice() throws {
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "TheTranscriptor Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapID.tapUID ?? aggregateUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            cleanupCoreAudio()
            throw RecorderError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID
    }

    private func installIOProc() throws {
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggregateID,
            nil
        ) { [weak self] _, inInputData, _, _, _ in
            self?.process(bufferList: inInputData)
        }
        guard status == noErr, let newProcID else {
            cleanupCoreAudio()
            throw RecorderError.ioProcFailed(status)
        }
        ioProcID = newProcID
    }

    private func cleanupCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        inputFormat = nil
    }

    // MARK: - Audio processing

    private func process(bufferList: UnsafePointer<AudioBufferList>) {
        guard let inputFormat,
              let converter,
              let audioFile,
              let outputFormat else { return }

        let mutableList = UnsafeMutablePointer(mutating: bufferList)
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: mutableList,
            deallocator: nil
        ), inBuffer.frameLength > 0 else { return }

        updateLevel(from: inBuffer)

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
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
        Task { @MainActor [weak self] in
            self?.level = normalized
        }
    }
}

private extension AudioObjectID {
    /// UID (CFString) del process tap, expuesto en `kAudioTapPropertyUID`.
    var tapUID: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (uid as String) : nil
    }
}
