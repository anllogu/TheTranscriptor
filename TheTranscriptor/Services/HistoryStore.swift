import Foundation

/// Persistencia del historial de transcripciones: un fichero JSON por
/// entrada bajo `Application Support/TheTranscriptor/history/<uuid>.json`.
/// Deliberadamente **no** vive bajo `work/` (que
/// `PythonPipelineService.purgeOrphanedWorkDirs()` vacía entera en cada
/// arranque) — reutiliza el mismo `applicationSupportDirectory()` como
/// base, pero con su propia subcarpeta que nunca se purga automáticamente.
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    var isWindowOpen = false

    private init() {
        entries = Self.loadAll()
    }

    private static var directory: URL {
        PythonPipelineService.applicationSupportDirectory()
            .appendingPathComponent("history", isDirectory: true)
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ entry: HistoryEntry) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: Self.fileURL(for: entry.id), options: .atomic)
        } catch {
            LogStore.shared.append("Historial: fallo al guardar entrada \(entry.id): \(error)", source: "history")
            return
        }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: Self.fileURL(for: id))
        entries.removeAll { $0.id == id }
    }

    func reload() {
        entries = Self.loadAll()
    }

    /// Borra entradas más antiguas que `retentionDays` días. `0` significa
    /// sin límite (no hace nada).
    func applyRetentionPolicy(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let expired = entries.filter { $0.createdAt < cutoff }
        for entry in expired {
            delete(id: entry.id)
        }
    }

    private static func loadAll() -> [HistoryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        let loaded: [HistoryEntry] = files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try decoder.decode(HistoryEntry.self, from: data)
            } catch {
                LogStore.shared.append("Historial: no se pudo leer \(url.lastPathComponent): \(error)", source: "history")
                return nil
            }
        }
        return loaded.sorted { $0.createdAt > $1.createdAt }
    }
}
