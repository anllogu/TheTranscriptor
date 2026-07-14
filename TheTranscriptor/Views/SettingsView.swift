import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    private let keychainService = KeychainService()
    private let detector = PythonEnvironmentDetector()

    @State private var hfToken: String = ""
    @State private var detectedPath: String?
    @State private var tokenSaveMessage: String?

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
                    tokenSaveMessage = "Token eliminado"
                    LogStore.shared.append("Token HF eliminado del Keychain", source: "settings")
                }
                if let tokenSaveMessage {
                    Text(tokenSaveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Historial") {
                Picker("Mantener transcripciones", selection: historyRetentionBinding) {
                    ForEach(Self.retentionOptions, id: \.self) { days in
                        Text(Self.retentionDisplayName(days)).tag(days)
                    }
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
            LogStore.shared.append(
                hfToken.isEmpty ? "Ajustes: no hay token HF guardado en el Keychain" : "Ajustes: token HF cargado desde el Keychain (\(hfToken.count) caracteres)",
                source: "settings"
            )
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

    private var historyRetentionBinding: Binding<Int> {
        Binding(
            get: { appState.settings.historyRetentionDays },
            set: { appState.settings.historyRetentionDays = $0 }
        )
    }

    private static let retentionOptions = [0, 7, 30, 90, 365]

    private static func retentionDisplayName(_ days: Int) -> String {
        switch days {
        case 0: return "Ilimitado"
        case 7: return "7 días"
        case 30: return "30 días"
        case 90: return "90 días"
        case 365: return "365 días"
        default: return "\(days) días"
        }
    }

    private func saveToken() {
        guard !hfToken.isEmpty else {
            LogStore.shared.append("Guardar token HF: campo vacío, no se guarda nada", source: "settings")
            return
        }
        do {
            try keychainService.setToken(hfToken)
            let verified = keychainService.token()
            if verified == hfToken {
                tokenSaveMessage = "Token guardado ✓"
                LogStore.shared.append("Token HF guardado y verificado en el Keychain (\(hfToken.count) caracteres)", source: "settings")
            } else {
                tokenSaveMessage = "⚠️ Guardado pero la verificación no coincide"
                LogStore.shared.append("Token HF: setToken no lanzó error pero la relectura no coincide con lo escrito", source: "settings")
            }
        } catch {
            tokenSaveMessage = "⚠️ Error al guardar: \(error)"
            LogStore.shared.append("Token HF: fallo al guardar en Keychain: \(error)", source: "settings")
        }
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
