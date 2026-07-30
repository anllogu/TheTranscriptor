import AppKit
import SwiftUI

struct RecordingView: View {
    @Environment(AppState.self) private var appState

    @State private var permissionDenied = false
    @State private var systemPermissionFailed = false
    @State private var errorMessage: String?

    private var isMeeting: Bool { appState.recordingMode == .meeting }
    private var recorder: AudioRecorderService { appState.recorder }
    private var meeting: MeetingRecorderService { appState.meetingRecorder }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if permissionDenied {
                permissionDeniedView
            } else if systemPermissionFailed {
                systemPermissionView
            } else if isMeeting {
                meetingContent
            } else {
                microphoneContent
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

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

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
                levelRow(title: "Sistema (altavoces)", level: meeting.systemLevel)
            }
            .padding(.horizontal, 40)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

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

    // MARK: - Arranque

    private func beginIfNeeded() async {
        if isMeeting {
            guard meeting.state == .idle else { return }
            let granted = await meeting.requestMicrophonePermission()
            guard granted else {
                permissionDenied = true
                return
            }
            do {
                try meeting.start()
            } catch MeetingRecorderService.RecorderError.systemAudioFailed {
                systemPermissionFailed = true
            } catch {
                errorMessage = "No se pudo iniciar la grabación: \(error.localizedDescription)"
            }
        } else {
            guard recorder.state == .idle else { return }
            let granted = await recorder.requestPermission()
            guard granted else {
                permissionDenied = true
                return
            }
            do {
                try recorder.start()
            } catch {
                errorMessage = "No se pudo iniciar la grabación: \(error.localizedDescription)"
            }
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
