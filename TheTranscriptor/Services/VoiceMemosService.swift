import Foundation
import SQLite3

/// Descubre e importa notas de voz de la app **Notas de voz** de macOS.
///
/// La biblioteca local vive en el contenedor de grupo
/// `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`:
/// los `.m4a` con nombres crípticos y una base SQLite `CloudRecordings.db` con
/// los metadatos legibles (título, fecha, duración). Se lee la BD y, si falla o
/// no existe, se cae a enumerar los `.m4a` de la carpeta (formato interno de
/// Apple sujeto a cambios → el listado por carpeta es la red de seguridad).
///
/// Con iCloud activo los ficheros pueden estar evacuados (placeholders de 0
/// bytes); `ensureDownloaded(_:)` fuerza la descarga antes de transcribir, y
/// `copyForTranscription(_:)` hace una copia temporal para no arriesgar nunca la
/// biblioteca del usuario (la pipeline borra su `--input` si "Borrar audio" está
/// activo).
final class VoiceMemosService {
    enum Library: Equatable {
        /// Hay notas de voz disponibles.
        case ok([VoiceMemo])
        /// El contenedor/carpeta existe pero no hay ninguna nota.
        case empty
        /// El contenedor no existe o no es accesible (p. ej. Notas de voz nunca
        /// se abrió en este Mac, así que aún no ha sincronizado nada).
        case unavailable
        /// El contenedor existe y tiene contenido, pero macOS bloquea su lectura
        /// (TCC): la app necesita "Acceso a disco completo".
        case accessDenied
    }

    enum VoiceMemosError: LocalizedError {
        case downloadTimedOut
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .downloadTimedOut:
                return "La descarga desde iCloud tardó demasiado. Inténtalo de nuevo."
            case .fileMissing:
                return "No se encontró el archivo de la nota de voz."
            }
        }
    }

    static let groupContainerName = "group.com.apple.VoiceMemos.shared"

    /// Permite a los tests apuntar a una carpeta temporal en vez del
    /// contenedor real de Notas de voz.
    var recordingsDirectoryOverride: URL?

    private let fileManager = FileManager.default

    init(recordingsDirectoryOverride: URL? = nil) {
        self.recordingsDirectoryOverride = recordingsDirectoryOverride
    }

    // MARK: - Localización

    /// Carpeta `Recordings/` del contenedor de grupo de Notas de voz, o `nil`
    /// si no se puede resolver la carpeta base.
    func recordingsDirectory() -> URL? {
        if let override = recordingsDirectoryOverride {
            return override
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(Self.groupContainerName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    // MARK: - Carga de la biblioteca

    func loadLibrary() -> Library {
        guard let dir = recordingsDirectory(),
              fileManager.fileExists(atPath: dir.path) else {
            return .unavailable
        }

        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        var memos: [VoiceMemo] = []
        if fileManager.fileExists(atPath: dbURL.path),
           let fromDB = readDatabase(at: dbURL, recordingsDir: dir) {
            memos = fromDB
        }

        if memos.isEmpty {
            do {
                memos = try listRecordings(in: dir)
            } catch {
                if isPermissionError(error) { return .accessDenied }
            }
        }

        if memos.isEmpty {
            // El contenedor tiene contenido protegido que no hemos podido leer
            // (BD presente pero no abrible por TCC) → es un bloqueo de permisos,
            // no una biblioteca vacía.
            if fileManager.fileExists(atPath: dbURL.path), !canRead(dbURL) {
                return .accessDenied
            }
            return .empty
        }

        memos.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return .ok(memos)
    }

    // MARK: - Lectura de CloudRecordings.db

    private func readDatabase(at dbURL: URL, recordingsDir: URL) -> [VoiceMemo]? {
        var db: OpaquePointer?
        // `immutable=1` abre la BD de otra app como una instantánea de solo
        // lectura: evita tener que tocar sus ficheros `-wal`/`-shm` y el
        // bloqueo, que suelen estar protegidos aparte.
        let uri = dbURL.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // ZCUSTOMLABEL es el título editable por el usuario y la columna más
        // estable entre versiones de macOS; si el `prepare` falla (esquema
        // distinto) devolvemos nil para que el llamante caiga al listado por
        // carpeta.
        let sql = "SELECT ZUNIQUEID, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH FROM ZCLOUDRECORDING"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var memos: [VoiceMemo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uid = columnText(stmt, 0)
            let label = columnText(stmt, 1)
            let hasDate = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            let dateVal = sqlite3_column_double(stmt, 2)
            let hasDur = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            let durVal = sqlite3_column_double(stmt, 3)
            let path = columnText(stmt, 4)

            guard let url = resolveURL(path: path, in: recordingsDir),
                  fileExistsOrPlaceholder(url) else {
                continue
            }
            let title = (label?.isEmpty == false)
                ? label!
                : url.deletingPathExtension().lastPathComponent
            memos.append(VoiceMemo(
                id: uid ?? url.lastPathComponent,
                title: title,
                // ZDATE es un timestamp Core Data: segundos desde 2001-01-01.
                date: hasDate ? Date(timeIntervalSinceReferenceDate: dateVal) : nil,
                duration: hasDur ? durVal : nil,
                url: url,
                downloadState: downloadState(for: url)
            ))
        }
        return memos
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func resolveURL(path: String?, in recordingsDir: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/"), fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // ZPATH suele ser el nombre de fichero (o una ruta relativa); nos
        // quedamos con el último componente y lo colgamos de Recordings/.
        let name = (path as NSString).lastPathComponent
        return recordingsDir.appendingPathComponent(name)
    }

    // MARK: - Fallback: listar la carpeta

    private func listRecordings(in dir: URL) throws -> [VoiceMemo] {
        let entries = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        var byPath: [String: VoiceMemo] = [:]
        for entry in entries {
            guard let url = materializedURL(for: entry) else { continue }
            let path = url.path
            if byPath[path] != nil { continue }
            let creation = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            byPath[path] = VoiceMemo(
                id: url.lastPathComponent,
                title: url.deletingPathExtension().lastPathComponent,
                date: creation,
                duration: nil,
                url: url,
                downloadState: downloadState(for: url)
            )
        }
        return Array(byPath.values)
    }

    /// Traduce una entrada de carpeta a la URL "real" del `.m4a`. Acepta tanto
    /// el fichero materializado (`nombre.m4a`) como el placeholder de iCloud
    /// (`.nombre.m4a.icloud`).
    private func materializedURL(for entry: URL) -> URL? {
        let name = entry.lastPathComponent
        if entry.pathExtension.lowercased() == "m4a" {
            return entry
        }
        if name.hasSuffix(".icloud"), name.hasPrefix(".") {
            let inner = String(name.dropFirst().dropLast(".icloud".count))
            if (inner as NSString).pathExtension.lowercased() == "m4a" {
                return entry.deletingLastPathComponent().appendingPathComponent(inner)
            }
        }
        return nil
    }

    // MARK: - Permisos (TCC)

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    /// Comprueba si el fichero se puede abrir para lectura de verdad. `access()`
    /// / `isReadableFile` miran solo los permisos POSIX y no detectan el bloqueo
    /// de TCC, que ocurre al abrir; por eso abrimos un `FileHandle`.
    private func canRead(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    // MARK: - Estado de descarga (iCloud)

    private func fileExistsOrPlaceholder(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return fileManager.fileExists(atPath: placeholderURL(for: url).path)
    }

    private func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    private func downloadState(for url: URL) -> VoiceMemo.DownloadState {
        if fileManager.fileExists(atPath: url.path) {
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               let status = values.ubiquitousItemDownloadingStatus {
                return status == .current ? .downloaded : .notDownloaded
            }
            return .downloaded
        }
        return .notDownloaded
    }

    // MARK: - Copia para transcribir

    /// Materializa la nota (descargándola de iCloud si hace falta) y la copia a
    /// un directorio temporal; devuelve la copia. Se transcribe **la copia**,
    /// nunca el original de la biblioteca de Notas de voz: si "Borrar audio"
    /// está activo la pipeline borraría su `--input`, y eso jamás debe afectar a
    /// la biblioteca del usuario.
    ///
    /// Bloquea mientras dura la descarga → debe llamarse fuera del hilo
    /// principal.
    func copyForTranscription(_ memo: VoiceMemo) throws -> URL {
        let sourceURL = memo.url
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VoiceMemosImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let baseName = sanitizedFileName(memo.title)
        let destination = tempDir.appendingPathComponent("\(baseName).\(ext)")

        // Camino rápido: si el fichero ya está materializado y es legible, se
        // copia directamente. NO llamamos a `startDownloadingUbiquitousItem`
        // aquí: sobre el contenedor de otra app lanza un error engañoso
        // ("couldn't be saved in the folder Recordings") aunque el fichero esté
        // presente y legible.
        if fileManager.fileExists(atPath: sourceURL.path), canRead(sourceURL) {
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        }

        // Evacuado a iCloud: pedimos la descarga (best-effort) y leemos con
        // coordinación de ficheros, que dispara la bajada gestionada por el
        // sistema y nos da una instantánea legible sin que escribamos nosotros
        // en la biblioteca de Notas de voz.
        try? fileManager.startDownloadingUbiquitousItem(at: sourceURL)

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinatorError
        ) { readURL in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if let coordinatorError { throw coordinatorError }
        guard fileManager.fileExists(atPath: destination.path) else {
            throw VoiceMemosError.fileMissing
        }
        return destination
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "nota_de_voz" : trimmed
    }
}
