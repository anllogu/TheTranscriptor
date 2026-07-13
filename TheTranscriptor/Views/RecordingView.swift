import AppKit
import SwiftUI

struct RecordingView: View {
    @Environment(AppState.self) private var appState

    @State private var permissionDenied = false
    @State private var errorMessage: String?

    private var recorder: AudioRecorderService { appState.recorder }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if permissionDenied {
                permissionDeniedView
            } else {
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

            Spacer()
        }
        .task {
            await beginIfNeeded()
        }
    }

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

    private func beginIfNeeded() async {
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

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
