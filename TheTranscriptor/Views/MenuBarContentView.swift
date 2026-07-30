import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Contenido del icono de la bandeja de sistema (CU-10 / §4.8). El menú se
/// reconstruye cada vez que se abre, así que refleja el `AppState.phase` actual
/// para ofrecer las acciones pertinentes (grabar, detener, ver progreso…).
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch appState.phase {
            case .recording:
                recordingItems
            case .processing:
                processingItems
            case .checkingRequirements(let checks) where !checks.isEmpty:
                requirementsPendingItems
            case .checkingRequirements:
                Text("Comprobando requisitos…")
                commonItems
            default:
                readyItems
            }
        }
    }

    // MARK: - Estado listo (idle / result / error)

    @ViewBuilder
    private var readyItems: some View {
        Button {
            Task { await appState.startRecording(mode: .microphone) }
        } label: {
            Label("Grabar con micrófono", systemImage: "mic.fill")
        }
        .keyboardShortcut("r", modifiers: [.command, .option])

        Button {
            Task { await appState.startRecording(mode: .meeting) }
        } label: {
            Label("Grabar reunión (micro + sistema)", systemImage: "person.wave.2.fill")
        }
        .keyboardShortcut("m", modifiers: [.command, .option])

        Divider()

        Button("Transcribir archivo…") { pickFileAndTranscribe() }
        Button("Importar de Notas de voz…") { showWindow(id: "voice-memos") }

        Divider()
        commonItems
    }

    // MARK: - Grabando

    @ViewBuilder
    private var recordingItems: some View {
        let isMeeting = appState.recordingMode == .meeting
        let elapsed = isMeeting ? appState.meetingRecorder.elapsed : appState.recorder.elapsed
        Text(isMeeting
            ? "● Grabando reunión — \(timeLabel(elapsed))"
            : "● Grabando micrófono — \(timeLabel(elapsed))")

        if !isMeeting {
            if appState.recorder.state == .recording {
                Button("Pausar") { appState.recorder.pause() }
            } else if appState.recorder.state == .paused {
                Button("Reanudar") { try? appState.recorder.resume() }
            }
        }

        Button("Detener y transcribir") { appState.finishRecording() }
        Button("Cancelar grabación") { appState.cancelRecording() }

        Divider()
        Button("Abrir The Transcriptor") { showMainWindow() }
        Divider()
        quitButton
    }

    // MARK: - Procesando

    @ViewBuilder
    private var processingItems: some View {
        Text("Transcribiendo…")
        Button("Abrir The Transcriptor") { showMainWindow() }
        Divider()
        quitButton
    }

    // MARK: - Requisitos pendientes

    @ViewBuilder
    private var requirementsPendingItems: some View {
        Button {
            showMainWindow()
        } label: {
            Label("Requisitos pendientes — Configurar…", systemImage: "exclamationmark.triangle.fill")
        }
        Divider()
        commonItems
    }

    // MARK: - Items comunes

    @ViewBuilder
    private var commonItems: some View {
        Button("Historial…") { showWindow(id: "history") }
        Button("Ajustes…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Abrir The Transcriptor") { showMainWindow() }
        Divider()
        quitButton
    }

    private var quitButton: some View {
        Button("Salir") { quit() }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Acciones

    private func showMainWindow() {
        showWindow(id: "main")
    }

    private func showWindow(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickFileAndTranscribe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Audio, .mpeg4Movie, .quickTimeMovie, .wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.runPipeline(input: url)
    }

    private func quit() {
        // Limpia el WAV temporal si se está grabando al salir.
        if appState.isRecording {
            appState.cancelRecording()
        }
        NSApplication.shared.terminate(nil)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Icono del `MenuBarExtra`. Es una vista siempre viva (el icono está siempre
/// en la barra de estado), así que la usamos también para **auto-abrir la
/// ventana principal** cuando la app entra en procesado tras una grabación
/// iniciada desde la bandeja.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform")
            .onChange(of: appState.isProcessing) { _, nowProcessing in
                if nowProcessing {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
