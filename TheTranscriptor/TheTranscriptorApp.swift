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
        .defaultSize(width: 560, height: 480)
        .commands {
            // SwiftUI añade "Nueva ventana" (⌘N) automáticamente a toda
            // WindowGroup; esta app no soporta múltiples ventanas y ⌘N ya
            // está asignado a "nueva transcripción" en las vistas — quitar
            // el comando por defecto evita que compita por el atajo.
            CommandGroup(replacing: .newItem) { }
            LogWindowCommands()
        }

        Window("Registro de depuración", id: "debug-log") {
            LogWindowView()
        }
        .defaultSize(width: 640, height: 420)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

private struct LogWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var logStore = LogStore.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(logStore.isWindowOpen ? "Ocultar registro de depuración" : "Mostrar registro de depuración") {
                if logStore.isWindowOpen {
                    dismissWindow(id: "debug-log")
                } else {
                    openWindow(id: "debug-log")
                }
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}
