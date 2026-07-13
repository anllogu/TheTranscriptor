import AppKit
import SwiftUI

struct RequirementsView: View {
    @Environment(AppState.self) private var appState

    let checks: [RequirementCheck]

    private var packagesMissing: Bool {
        checks.contains { $0.name.hasPrefix("Paquetes") && !$0.status.isOk }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Comprobando requisitos")
                .font(.title2.bold())

            if checks.isEmpty {
                ProgressView("Verificando ffmpeg, Python y paquetes…")
            } else {
                List(checks) { check in
                    HStack(alignment: .top) {
                        Image(systemName: check.status.isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.status.isOk ? .green : .red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.name).font(.headline)
                            if case .missing(let instruction) = check.status {
                                Text(instruction)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(6)
                            }
                        }
                    }
                }

                if appState.isSettingUpPython {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView("Configurando entorno Python…")
                        ScrollView {
                            Text(appState.setupLog.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }

                HStack {
                    Button("Reintentar") {
                        appState.checkRequirements()
                    }
                    .disabled(appState.isSettingUpPython)

                    if packagesMissing {
                        Button("Configurar automáticamente") {
                            appState.runAutomaticPythonSetup()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isSettingUpPython)
                    }

                    Button("Ajustes…") {
                        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            }
        }
        .padding()
    }
}
