import SwiftUI

struct ErrorView: View {
    @Environment(AppState.self) private var appState

    let error: PipelineError

    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text(error.message)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if !error.stderrTail.isEmpty {
                DisclosureGroup("Detalles técnicos", isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.stderrTail.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .frame(maxWidth: 460)
            }

            Button("Reintentar") {
                appState.retry()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)

            Spacer()
        }
        .padding()
    }
}
