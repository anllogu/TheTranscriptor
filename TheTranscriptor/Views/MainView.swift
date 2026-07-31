import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.phase {
            case .checkingRequirements(let checks):
                RequirementsView(checks: checks)
            case .idle:
                DropZoneView()
            case .recording:
                RecordingView()
            case .processing(let phase, let progress, let downloading, let action):
                ProcessingView(phase: phase, progress: progress, downloading: downloading, currentAction: action)
            case .result(let entry):
                ResultView(entry: entry)
            case .error(let error):
                ErrorView(error: error)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
