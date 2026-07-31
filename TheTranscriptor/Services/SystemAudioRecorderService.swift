import AVFoundation
import CoreAudio
import Foundation

/// Captura TODO el audio de salida del sistema (el dispositivo de salida por
/// defecto: altavoces, cascos, USB o Bluetooth) usando *Core Audio
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
    private var tapUUID: UUID?
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var lastLevelUpdate: Date = .distantPast

    // Diagnóstico (se vuelca a LogStore / ⌘L).
    private var framesWritten: Int64 = 0
    private var ioProcFired: Bool = false
    private var lastDiagLog: Date = .distantPast

    // Línea de tiempo fiel: instante de reloj de pared del arranque de la
    // captura. El *process tap* del sistema no entrega buffers durante el
    // silencio (ni el inicial ni los huecos intermedios), así que su WAV se
    // acortaría y quedaría descuadrado respecto a la pista del micro. Antes de
    // escribir cada buffer se rellena con silencio el hueco entre la posición
    // esperada (según el tiempo transcurrido) y lo realmente escrito, para que
    // ambas pistas compartan el mismo origen temporal (§3.4/§4.7).
    private var timelineStartHostTime: Date?
    // Umbral (en segundos) por debajo del cual NO se rellena: absorbe el jitter
    // normal de latencia de callback; solo se rellenan silencios reales.
    private static let silenceGapThresholdSeconds: Double = 0.25

    // Serializa la reconstrucción de la captura cuando cambia el dispositivo
    // de salida por defecto durante la grabación.
    private let coreAudioQueue = DispatchQueue(label: "com.allosa.TheTranscriptor.systemaudio")
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

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

        framesWritten = 0
        try buildCapture()

        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanupCoreAudio()
            throw RecorderError.startFailed(status)
        }

        timelineStartHostTime = Date()
        outputURL = url
        state = .recording
        ioProcFired = false
        addDefaultOutputListener()
        scheduleIOProcProbe()
        return url
    }

    /// Comprueba ~1.5 s después de arrancar si el IOProc del tap ha llegado a
    /// dispararse. Si no, el problema es de captura (permiso TCC no concedido o
    /// aggregate mal formado), no de conversión — se registra en ⌘L.
    private func scheduleIOProcProbe() {
        coreAudioQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.state == .recording else { return }
            if self.ioProcFired {
                self.log("IOProc del tap activo (\(self.framesWritten) frames escritos hasta ahora)")
            } else {
                self.log("AVISO: el IOProc del tap NO se ha disparado; probable permiso 'Grabación de audio del sistema' no concedido o aggregate sin audio")
            }
        }
    }

    /// Construye (o reconstruye) el pipeline de Core Audio: tap global +
    /// aggregate device vinculado al dispositivo de salida por defecto real +
    /// converter al formato de destino + IOProc. No arranca la captura.
    private func buildCapture() throws {
        try createTap()
        try readTapInputFormat()
        try createAggregateDevice()

        guard let inputFormat, let outputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            cleanupCoreAudio()
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        try installIOProc()
    }

    @discardableResult
    func stop() -> URL? {
        guard state == .recording else { return outputURL }
        removeDefaultOutputListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        cleanupCoreAudio()
        audioFile = nil
        converter = nil
        state = .idle
        level = 0
        timelineStartHostTime = nil
        log("captura del sistema detenida (frames escritos: \(framesWritten))")
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
        // Fijar un UUID propio y usarlo como sub-tap UID del aggregate (más
        // fiable que releer kAudioTapPropertyUID, que a veces devuelve un valor
        // que el aggregate no reconoce y deja la lista de taps vacía → silencio).
        let uuid = UUID()
        description.uuid = uuid
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
        tapUUID = uuid
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
        log("formato del tap: \(Int(format.sampleRate)) Hz, \(format.channelCount) canal(es)")
    }

    private func createAggregateDevice() throws {
        let outputID = defaultOutputDeviceID()
        let outputUID = deviceUID(outputID)
        log("dispositivo de salida por defecto: \(deviceName(outputID) ?? "?") [UID: \(outputUID ?? "?")]")

        guard let tapUUID else {
            cleanupCoreAudio()
            throw RecorderError.aggregateCreationFailed(OSStatus(kAudioHardwareUnspecifiedError))
        }
        guard let outputUID else {
            // Sin dispositivo de salida real no hay reloj para el aggregate y
            // el tap no entrega audio: abortar con error claro.
            log("error: no se pudo obtener el UID del dispositivo de salida por defecto")
            cleanupCoreAudio()
            throw RecorderError.aggregateCreationFailed(OSStatus(kAudioHardwareBadDeviceError))
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "TheTranscriptor Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            // El aggregate se ancla al dispositivo de salida REAL (altavoces,
            // cascos, USB, Bluetooth…) como main sub-device Y en la sub-device
            // list, para que herede su reloj/formato y el tap entregue audio.
            // Sin la sub-device list poblada el IOProc no recibía datos y la
            // pista del sistema quedaba en silencio con cualquier dispositivo.
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
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
        tapUUID = nil
        inputFormat = nil
    }

    // MARK: - Seguimiento del dispositivo de salida

    private func addDefaultOutputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.log("cambio de dispositivo de salida por defecto detectado; reconstruyendo captura")
            self?.rebuildCapture()
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            coreAudioQueue,
            block
        )
    }

    private func removeDefaultOutputListener() {
        guard let defaultOutputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            coreAudioQueue,
            defaultOutputListener
        )
        self.defaultOutputListener = nil
    }

    /// Reconstruye tap + aggregate + converter tras un cambio de dispositivo de
    /// salida, sin cerrar el `AVAudioFile` en curso (la pista continúa). Se
    /// ejecuta en serie en `coreAudioQueue`; `AudioDeviceStop` garantiza que el
    /// IOProc no se invoca durante el intercambio.
    private func rebuildCapture() {
        coreAudioQueue.async { [weak self] in
            guard let self, self.state == .recording else { return }
            if self.aggregateID != AudioObjectID(kAudioObjectUnknown), let proc = self.ioProcID {
                AudioDeviceStop(self.aggregateID, proc)
            }
            self.cleanupCoreAudio()
            do {
                try self.buildCapture()
                let status = AudioDeviceStart(self.aggregateID, self.ioProcID)
                if status == noErr {
                    self.log("captura del sistema reconstruida sobre el nuevo dispositivo")
                } else {
                    self.log("error al rearrancar la captura tras el cambio (status \(status))")
                }
            } catch {
                self.log("no se pudo reconstruir la captura del sistema: \(error)")
            }
        }
    }

    private func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func deviceUID(_ id: AudioObjectID) -> String? {
        guard id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (uid as String) : nil
    }

    private func deviceName(_ id: AudioObjectID) -> String? {
        guard id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : nil
    }

    private func log(_ message: String) {
        Task { @MainActor in
            LogStore.shared.append(message, source: "sysaudio")
        }
    }

    @MainActor
    private func emitDiagnostics(frames: Int64, level: Float) {
        LogStore.shared.append(
            String(format: "captura del sistema: %lld frames, nivel %.2f", frames, level),
            source: "sysaudio"
        )
    }

    // MARK: - Audio processing

    private func process(bufferList: UnsafePointer<AudioBufferList>) {
        ioProcFired = true
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
            fillSilenceGapIfNeeded(nextBufferOutputFrames: Int64(outBuffer.frameLength))
            try? audioFile.write(from: outBuffer)
            framesWritten += Int64(outBuffer.frameLength)
            logDiagnosticsIfNeeded()
        }
    }

    /// Rellena con silencio el hueco entre lo que *debería* haberse escrito
    /// (según el tiempo transcurrido de reloj de pared) y lo realmente escrito,
    /// justo antes de volcar el siguiente buffer de datos. Durante el sonido
    /// continuo `framesWritten` avanza al ritmo de las muestras (precisión de
    /// audio) y el hueco queda por debajo del umbral → no se rellena; solo se
    /// inyecta silencio ante paradas reales del *tap* (silencio inicial o huecos
    /// intermedios), que es donde se perdía la línea de tiempo.
    private func fillSilenceGapIfNeeded(nextBufferOutputFrames: Int64) {
        guard let timelineStartHostTime, let outputFormat else { return }
        let outRate = outputFormat.sampleRate
        let elapsed = Date().timeIntervalSince(timelineStartHostTime)
        let expectedStartFrames = Int64((elapsed - Double(nextBufferOutputFrames) / outRate) * outRate)
        let thresholdFrames = Int64(Self.silenceGapThresholdSeconds * outRate)
        let gap = Self.silenceGapFrames(
            expectedStartFrames: expectedStartFrames,
            writtenFrames: framesWritten,
            thresholdFrames: thresholdFrames
        )
        guard gap > 0 else { return }
        writeSilence(outputFrames: gap)
        framesWritten += gap
        LogStore.shared.append(
            String(format: "relleno de silencio: %lld frames (%.2fs) para mantener la línea de tiempo",
                   gap, Double(gap) / outRate),
            source: "sysaudio"
        )
    }

    /// Frames de silencio a insertar: la diferencia entre la posición esperada y
    /// la escrita, ignorando huecos por debajo del umbral (jitter de callback).
    /// Función pura para poder testear la lógica sin Core Audio.
    static func silenceGapFrames(expectedStartFrames: Int64, writtenFrames: Int64, thresholdFrames: Int64) -> Int64 {
        let gap = expectedStartFrames - writtenFrames
        return gap >= thresholdFrames ? gap : 0
    }

    /// Escribe `outputFrames` muestras a cero en el WAV de salida (mono Int16
    /// intercalado), troceando en bloques para no reservar buffers gigantes.
    private func writeSilence(outputFrames: Int64) {
        guard outputFrames > 0, let audioFile, let outputFormat else { return }
        var remaining = outputFrames
        let chunk: AVAudioFrameCount = 16_000
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: n) else { break }
            buffer.frameLength = n
            if let channel = buffer.int16ChannelData {
                memset(channel[0], 0, Int(n) * MemoryLayout<Int16>.size)
            }
            try? audioFile.write(from: buffer)
            remaining -= Int64(n)
        }
    }

    private func logDiagnosticsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastDiagLog) >= 2 else { return }
        lastDiagLog = now
        let frames = framesWritten
        let currentLevel = level
        Task { @MainActor [weak self] in
            self?.emitDiagnostics(frames: frames, level: currentLevel)
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
