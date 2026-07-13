import SwiftUI

struct ProcessingView: View {
    @Environment(AppState.self) private var appState

    let phase: PipelinePhase
    let progress: Int?
    let downloading: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: progress.map { Double($0) / 100 })
                .progressViewStyle(.circular)
                .controlSize(.large)

            Text(phase.displayName)
                .font(.title3.bold())

            if let progress {
                Text("\(progress)%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if downloading {
                Label("Descargando modelos…", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
            }

            Button("Cancelar") {
                appState.cancelPipeline()
                appState.reset()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                PrivacyBadge(isDownloading: downloading)
            }
        }
    }
}
