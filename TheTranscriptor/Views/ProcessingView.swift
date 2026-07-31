import SwiftUI

struct ProcessingView: View {
    private enum StepStatus {
        case pending
        case active
        case done
    }

    @Environment(AppState.self) private var appState

    let phase: PipelinePhase
    let progress: Int?
    let downloading: Bool
    let currentAction: String?

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

            if let currentAction, !currentAction.isEmpty {
                Label(currentAction, systemImage: "gearshape.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(PipelinePhase.allCases, id: \.self) { step in
                    let status = status(for: step)
                    HStack(spacing: 10) {
                        Image(systemName: iconName(for: status))
                            .foregroundStyle(color(for: status))
                        Text(step.checklistTitle)
                            .font(.callout.weight(status == .active ? .semibold : .regular))
                            .foregroundStyle(status == .pending ? .secondary : .primary)
                    }
                }
            }
            .frame(maxWidth: 260, alignment: .leading)

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

    private func status(for step: PipelinePhase) -> StepStatus {
        guard
            let currentIndex = PipelinePhase.allCases.firstIndex(of: phase),
            let stepIndex = PipelinePhase.allCases.firstIndex(of: step)
        else {
            return .pending
        }

        if stepIndex < currentIndex { return .done }
        if stepIndex == currentIndex { return .active }
        return .pending
    }

    private func iconName(for status: StepStatus) -> String {
        switch status {
        case .pending:
            return "circle"
        case .active:
            return "clock.fill"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    private func color(for status: StepStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .active:
            return .accentColor
        case .done:
            return .green
        }
    }
}
