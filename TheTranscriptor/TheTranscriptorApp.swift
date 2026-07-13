import SwiftUI

@main
struct TheTranscriptorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .task {
                    PythonPipelineService.purgeOrphanedWorkDirs()
                    appState.checkRequirements()
                }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
