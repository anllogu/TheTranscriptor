import Foundation

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let source: String
    let text: String
}

/// Buffer en memoria de líneas de depuración (stdout/stderr del pipeline
/// Python, aprovisionamiento del venv) para la ventana de registro (Ver ▸
/// Registro de depuración, ⌘L). No persiste entre lanzamientos ni se
/// escribe a disco — es solo ayuda para depurar en vivo.
@Observable
final class LogStore {
    static let shared = LogStore()

    private static let limit = 2000

    private(set) var lines: [LogLine] = []
    var isWindowOpen = false

    private init() {}

    func append(_ text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(LogLine(timestamp: Date(), source: source, text: trimmed))
        if lines.count > Self.limit {
            lines.removeFirst(lines.count - Self.limit)
        }
    }

    func clear() {
        lines.removeAll()
    }
}
