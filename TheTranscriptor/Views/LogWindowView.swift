import SwiftUI
import AppKit

struct LogWindowView: View {
    @State private var logStore = LogStore.shared

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if logStore.lines.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Sin actividad todavía")
                        .font(.title3.bold())
                    Text("Aquí aparecerá la salida del pipeline Python y del aprovisionamiento del entorno mientras se ejecutan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logStore.lines) { line in
                                logRow(line)
                                    .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: logStore.lines.count) {
                        if let lastID = logStore.lines.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .textSelection(.enabled)
            }

            Divider()

            HStack {
                Text("\(logStore.lines.count) líneas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copiar todo") {
                    copyAll()
                }
                .disabled(logStore.lines.isEmpty)
                Button("Limpiar") {
                    logStore.clear()
                }
                .disabled(logStore.lines.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { logStore.isWindowOpen = true }
        .onDisappear { logStore.isWindowOpen = false }
    }

    private func logRow(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: line.timestamp))
                .foregroundStyle(.tertiary)
            Text(line.source)
                .foregroundStyle(color(for: line.source))
                .frame(width: 60, alignment: .leading)
            Text(line.text)
                .foregroundStyle(line.source == "stderr" ? .red : .primary)
        }
        .font(.caption.monospaced())
    }

    private func color(for source: String) -> Color {
        switch source {
        case "stderr": return .red
        case "stdout": return .secondary
        case "setup": return .blue
        default: return .secondary
        }
    }

    private func copyAll() {
        let text = logStore.lines
            .map { "\(Self.timeFormatter.string(from: $0.timestamp)) [\($0.source)] \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
