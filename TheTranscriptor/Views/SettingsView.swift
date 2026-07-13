import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    private let keychainService = KeychainService()
    private let detector = PythonEnvironmentDetector()

    @State private var hfToken: String = ""
    @State private var detectedPath: String?

    var body: some View {
        Form {
            Section("Transcripción") {
                Picker("Modelo Whisper", selection: whisperModelBinding) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Toggle("Borrar audio original tras procesar", isOn: deleteAudioBinding)
            }

            Section("Hugging Face") {
                SecureField("Token de acceso", text: $hfToken)
                    .onSubmit(saveToken)
                Button("Guardar token") { saveToken() }
                Button("Eliminar token", role: .destructive) {
                    keychainService.deleteToken()
                    hfToken = ""
                }
            }

            Section("Intérprete Python") {
                TextField("Ruta manual (opcional)", text: pythonPathBinding)
                if let detectedPath {
                    Text("Autodetectado: \(detectedPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Autodetectar") {
                        detectedPath = detector.detectPythonPath()
                    }
                    Button("Examinar…") {
                        browseForPython()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            hfToken = keychainService.token() ?? ""
        }
    }

    private var whisperModelBinding: Binding<WhisperModel> {
        Binding(
            get: { appState.settings.getWhisperModel() },
            set: { appState.settings.setWhisperModel($0) }
        )
    }

    private var deleteAudioBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.deleteAudioAfter },
            set: { appState.settings.deleteAudioAfter = $0 }
        )
    }

    private var pythonPathBinding: Binding<String> {
        Binding(
            get: { appState.settings.pythonPath },
            set: { appState.settings.pythonPath = $0 }
        )
    }

    private func saveToken() {
        guard !hfToken.isEmpty else { return }
        try? keychainService.setToken(hfToken)
    }

    private func browseForPython() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.pythonPath = url.path
        }
    }
}
