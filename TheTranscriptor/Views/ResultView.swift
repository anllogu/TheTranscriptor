import SwiftUI
import AppKit

struct ResultView: View {
    @Environment(AppState.self) private var appState

    @State private var transcript: Transcript

    init(transcript: Transcript) {
        _transcript = State(initialValue: transcript)
    }

    private var speakerOrder: [String] {
        var seen: [String] = []
        for segment in transcript.segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            if transcript.segments.isEmpty {
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
                    ForEach(transcript.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            speakerIndex: speakerOrder.firstIndex(of: segment.speaker) ?? 0,
                            displayName: transcript.displayName(for: segment.speaker)
                        ) { newName in
                            transcript.setSpeakerName(newName, for: segment.speaker)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Copiar") {
                    copyToClipboard()
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Exportar .txt") {
                    export(using: TxtExporter.export, extension: "txt")
                }
                Button("Exportar .srt") {
                    export(using: SrtExporter.export, extension: "srt")
                }
                Spacer()
                Button("Nueva transcripción") {
                    appState.reset()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                PrivacyBadge(isDownloading: false)
            }
        }
    }

    private func copyToClipboard() {
        let text = TxtExporter.export(transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(using exporter: (Transcript) -> String, extension ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcripcion.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = exporter(transcript)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
