import AppKit
import SwiftUI

/// Estado de apertura de la ventana de Notas de voz, para el toggle
/// mostrar/ocultar del menú (mismo patrón que `LogStore`/`HistoryStore`).
@Observable
final class VoiceMemosWindowState {
    static let shared = VoiceMemosWindowState()
    var isWindowOpen = false
    private init() {}
}

/// Explorador de las notas de voz de la app **Notas de voz** de macOS
/// (CU-11). Lista las notas de la biblioteca local y, al elegir una, la
/// descarga de iCloud si hace falta, la copia a un temporal y la transcribe
/// con los ajustes vigentes.
struct VoiceMemosWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    enum Status { case loading, ok, empty, unavailable, accessDenied }

    @State private var status: Status = .loading
    @State private var memos: [VoiceMemo] = []

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    load()
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            VoiceMemosWindowState.shared.isWindowOpen = true
            load()
        }
        .onDisappear { VoiceMemosWindowState.shared.isWindowOpen = false }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            centered {
                ProgressView("Buscando notas de voz…")
            }
        case .unavailable:
            centered {
                messageView(
                    icon: "icloud.slash",
                    title: "No se encontró la biblioteca de Notas de voz",
                    detail: "Abre la app Notas de voz al menos una vez en este Mac para que sincronice tus grabaciones desde iCloud."
                )
            }
        case .empty:
            centered {
                messageView(
                    icon: "waveform.slash",
                    title: "No hay notas de voz",
                    detail: "Cuando grabes notas en la app Notas de voz aparecerán aquí."
                )
            }
        case .accessDenied:
            centered {
                VStack(spacing: 16) {
                    messageView(
                        icon: "lock.shield",
                        title: "The Transcriptor necesita permiso para leer Notas de voz",
                        detail: "macOS protege tus grabaciones. Concede a The Transcriptor \"Acceso a disco completo\" en Ajustes del Sistema, reinicia la app y vuelve a intentarlo."
                    )
                    Button("Abrir Ajustes del Sistema…") { openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .ok:
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if let error = appState.voiceMemoImportError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            List(memos) { memo in
                row(for: memo)
            }
            .listStyle(.inset)
        }
    }

    private func row(for memo: VoiceMemo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle(for: memo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if memo.downloadState != .downloaded {
                Label("iCloud", systemImage: "icloud.and.arrow.down")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Se descargará de iCloud antes de transcribir")
            }
            Button("Transcribir") { transcribe(memo) }
                .disabled(appState.isProcessing)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Acciones

    private func load() {
        status = .loading
        let service = appState.voiceMemosService
        switch service.loadLibrary() {
        case .ok(let found):
            memos = found
            status = .ok
        case .empty:
            memos = []
            status = .empty
        case .unavailable:
            memos = []
            status = .unavailable
        case .accessDenied:
            memos = []
            status = .accessDenied
        }
    }

    private func transcribe(_ memo: VoiceMemo) {
        Task { await appState.transcribeVoiceMemo(memo) }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Formato

    private func subtitle(for memo: VoiceMemo) -> String {
        var parts: [String] = []
        if let date = memo.date {
            parts.append(Self.dateFormatter.string(from: date))
        }
        if let duration = memo.duration {
            parts.append(Self.durationLabel(duration))
        }
        return parts.isEmpty ? memo.url.lastPathComponent : parts.joined(separator: " · ")
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Helpers de layout

    private func centered<V: View>(@ViewBuilder _ view: () -> V) -> some View {
        view()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func messageView(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }
}
