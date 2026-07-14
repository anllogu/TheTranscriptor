import AppKit
import SwiftUI

struct HistoryWindowView: View {
    @State private var historyStore = HistoryStore.shared
    @State private var selection: HistoryEntry.ID?

    var body: some View {
        NavigationSplitView {
            List(historyStore.entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.sourceFileName)
                        .font(.headline)
                    Text(rowSubtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            .overlay {
                if historyStore.entries.isEmpty {
                    Text("Todavía no hay transcripciones en el historial")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        } detail: {
            if let entry = historyStore.entries.first(where: { $0.id == selection }) {
                HistoryDetailView(entry: entry)
                    .id(entry.id)
            } else {
                Text("Selecciona una transcripción")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            historyStore.isWindowOpen = true
            historyStore.reload()
        }
        .onDisappear { historyStore.isWindowOpen = false }
    }

    private func rowSubtitle(for entry: HistoryEntry) -> String {
        "\(Self.dateFormatter.string(from: entry.createdAt)) · \(entry.transcript.language)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Detalle de una entrada del historial: misma estructura que `ResultView`
/// (lista de segmentos agrupados por hablante, renombrado, copiar/exportar),
/// más metadatos de origen y "Eliminar del historial" en vez de "Nueva
/// transcripción". Se mantiene como vista separada en vez de compartir un
/// componente con `ResultView` porque la única lógica no trivial (lista de
/// segmentos, exporters) ya son funciones/vistas reutilizadas tal cual; el
/// resto son un puñado de líneas con acciones de cabecera distintas.
private struct HistoryDetailView: View {
    @State private var entry: HistoryEntry

    init(entry: HistoryEntry) {
        _entry = State(initialValue: entry)
    }

    private var speakerOrder: [String] {
        var seen: [String] = []
        for segment in entry.transcript.segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if entry.transcript.segments.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No se detectó ningún segmento de voz en este audio")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entry.transcript.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            speakerIndex: speakerOrder.firstIndex(of: segment.speaker) ?? 0,
                            displayName: entry.transcript.displayName(for: segment.speaker)
                        ) { newName in
                            entry.transcript.setSpeakerName(newName, for: segment.speaker)
                            HistoryStore.shared.save(entry)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Copiar") { copyToClipboard() }
                Button("Exportar .txt") { export(using: TxtExporter.export, extension: "txt") }
                Button("Exportar .srt") { export(using: SrtExporter.export, extension: "srt") }
                Spacer()
                Button("Eliminar del historial", role: .destructive) {
                    HistoryStore.shared.delete(id: entry.id)
                }
            }
            .padding()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sourceFileName)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path = entry.sourceAudioPath, FileManager.default.fileExists(atPath: path) {
                Button("Mostrar en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    private var headerSubtitle: String {
        let duration = Int(entry.transcript.duration)
        return "\(Self.dateFormatter.string(from: entry.createdAt)) · \(entry.whisperModel) · \(entry.transcript.language) · \(duration)s"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func copyToClipboard() {
        let text = TxtExporter.export(entry.transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(using exporter: (Transcript) -> String, extension ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcripcion.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = exporter(entry.transcript)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
