import AppKit
import SwiftUI

struct RecordingView: View {
    @Environment(AppState.self) private var appState

    private var isMeeting: Bool { appState.recordingMode == .meeting }
    private var recorder: AudioRecorderService { appState.recorder }
    private var meeting: MeetingRecorderService { appState.meetingRecorder }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch appState.recordingStartError {
            case .microphonePermissionDenied:
                permissionDeniedView
            case .systemAudioFailed:
                systemPermissionView
            case .startFailed(let message):
                startFailedView(message)
            case .none:
                if isMeeting {
                    meetingContent
                } else {
                    microphoneContent
                }
            }

            Spacer()
        }
        .task {
            await beginIfNeeded()
        }
    }

    // MARK: - Modo micrófono

    private var microphoneContent: some View {
        VStack(spacing: 24) {
            Text(timeLabel(recorder.elapsed))
                .font(.system(size: 40, weight: .bold, design: .monospaced))

            AudioLevelMeter(level: recorder.level)
                .padding(.horizontal, 40)

            HStack(spacing: 16) {
                if recorder.state == .recording {
                    Button("Pausar") { recorder.pause() }
                        .buttonStyle(.bordered)
                } else if recorder.state == .paused {
                    Button("Reanudar") { try? recorder.resume() }
                        .buttonStyle(.bordered)
                }

                Button("Detener") {
                    appState.finishRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.state == .idle)

                Button("Cancelar") {
                    appState.cancelRecording()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Modo reunión (micro + sistema)

    private var meetingContent: some View {
        VStack(spacing: 24) {
            Label("Grabando reunión", systemImage: "person.wave.2.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(timeLabel(meeting.elapsed))
                .font(.system(size: 40, weight: .bold, design: .monospaced))

            VStack(spacing: 12) {
                levelRow(title: "Tú (micrófono)", level: meeting.micLevel)
                levelRow(title: "Sistema (salida de audio)", level: meeting.systemLevel)
            }
            .padding(.horizontal, 40)

            Label(
                "Para mejores resultados usa cascos. Con altavoces, la voz del interlocutor puede colarse por el micro y aparecer duplicada en la transcripción.",
                systemImage: "headphones"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            HStack(spacing: 16) {
                Button("Detener") {
                    appState.finishRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(meeting.state == .idle)

                Button("Cancelar") {
                    appState.cancelRecording()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func levelRow(title: String, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            AudioLevelMeter(level: level)
        }
    }

    // MARK: - Permisos

    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Permiso de micrófono denegado")
                .font(.title3.bold())
            Text("The Transcriptor necesita acceso al micrófono para grabar. Actívalo en Ajustes del Sistema.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Abrir Ajustes del Sistema") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Volver") {
                appState.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    private var systemPermissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("No se pudo capturar el audio del sistema")
                .font(.title3.bold())
            Text("Para grabar reuniones, The Transcriptor necesita el permiso de \"Grabación de audio del sistema\". Actívalo en Ajustes del Sistema y vuelve a intentarlo.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Abrir Ajustes del Sistema") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Volver") {
                appState.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    private func startFailedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("No se pudo iniciar la grabación")
                .font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .foregroundStyle(.secondary)
            Button("Volver") {
                appState.reset()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Arranque

    private func beginIfNeeded() async {
        // Si la grabación ya está en marcha (p. ej. iniciada desde el icono de
        // la bandeja y la ventana se abre después), no rearrancar: la vista
        // solo refleja el estado. El arranque real vive en AppState.
        if isMeeting {
            guard meeting.state == .idle, appState.recordingStartError == nil else { return }
        } else {
            guard recorder.state == .idle, appState.recordingStartError == nil else { return }
        }
        await appState.startRecording(mode: appState.recordingMode)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
