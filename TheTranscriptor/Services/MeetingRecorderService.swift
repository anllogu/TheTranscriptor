import AVFoundation
import Foundation

/// Coordina la grabación de una reunión: micrófono (`AudioRecorderService`) y
/// audio del sistema (`SystemAudioRecorderService`) a la vez, cada uno a su
/// propio WAV mono 16 kHz. Registra el instante de arranque de cada pista para
/// derivar los *offsets* que el script usa al fusionar (§3.4).
///
/// No soporta pausa/reanudación (a diferencia del modo solo-micro): una
/// reunión se graba de corrido para no desincronizar las dos pistas.
@Observable
final class MeetingRecorderService {
    enum State: Equatable {
        case idle, recording
    }

    enum RecorderError: Error {
        case microphonePermissionDenied
        case systemAudioFailed(Error)
        case microphoneFailed(Error)
    }

    struct Result: Equatable {
        let micURL: URL
        let systemURL: URL
        let micOffset: Double
        let systemOffset: Double
    }

    private(set) var state: State = .idle

    let mic: AudioRecorderService
    let system: SystemAudioRecorderService

    init(
        mic: AudioRecorderService = AudioRecorderService(),
        system: SystemAudioRecorderService = SystemAudioRecorderService()
    ) {
        self.mic = mic
        self.system = system
    }

    private var micStart: Date?
    private var systemStart: Date?

    var micLevel: Float { mic.level }
    var systemLevel: Float { system.level }
    var elapsed: TimeInterval { mic.elapsed }

    func requestMicrophonePermission() async -> Bool {
        await mic.requestPermission()
    }

    func start() throws {
        micStart = Date()
        do {
            try mic.start()
        } catch {
            throw RecorderError.microphoneFailed(error)
        }

        systemStart = Date()
        do {
            try system.start()
        } catch {
            // Si el audio del sistema falla (p. ej. permiso TCC no concedido),
            // no dejamos el micro grabando a medias.
            mic.cancelAndDelete()
            micStart = nil
            systemStart = nil
            throw RecorderError.systemAudioFailed(error)
        }

        state = .recording
    }

    func stop() -> Result? {
        guard state == .recording else { return nil }
        state = .idle

        let micURL = mic.stop()
        let systemURL = system.stop()

        guard let micURL, let systemURL, let micStart, let systemStart else {
            // Estado inconsistente: limpiar lo que haya quedado.
            mic.cancelAndDelete()
            system.cancelAndDelete()
            return nil
        }

        let reference = min(micStart, systemStart)
        let micOffset = micStart.timeIntervalSince(reference)
        let systemOffset = systemStart.timeIntervalSince(reference)

        self.micStart = nil
        self.systemStart = nil

        return Result(
            micURL: micURL,
            systemURL: systemURL,
            micOffset: micOffset,
            systemOffset: systemOffset
        )
    }

    func cancelAndDelete() {
        mic.cancelAndDelete()
        system.cancelAndDelete()
        micStart = nil
        systemStart = nil
        state = .idle
    }
}
