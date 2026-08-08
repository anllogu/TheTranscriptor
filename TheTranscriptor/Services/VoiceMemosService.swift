import Foundation
import SQLite3

/// Descubre e importa notas de voz de la app **Notas de voz** de macOS.
///
/// La biblioteca local vive en el contenedor de grupo
/// `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`:
/// los `.m4a` con nombres crípticos y una base SQLite `CloudRecordings.db` con
/// los metadatos legibles (título, fecha, duración). `loadLibrary()` siempre
/// enumera la carpeta (fuente de verdad de qué ficheros existen) y siempre
/// intenta leer la BD; las filas de la BD **enriquecen** las entradas de
/// carpeta emparejándolas por nombre de fichero, en vez de sustituirlas
/// todo-o-nada — así un fallo parcial de la BD (esquema distinto, fila con
/// `ZPATH` obsoleto) degrada por fila y no borra los metadatos de toda la
/// biblioteca (formato interno de Apple sujeto a cambios → el listado por
/// carpeta sigue siendo la red de seguridad última).
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

        // La enumeración de carpeta es la fuente de verdad de qué ficheros
        // existen de verdad (url/downloadState); siempre se ejecuta, sea cual
        // sea el resultado de la BD.
        var folderMemos: [VoiceMemo] = []
        do {
            folderMemos = try listRecordings(in: dir)
        } catch {
            if isPermissionError(error) { return .accessDenied }
        }

        var folderByKey: [String: VoiceMemo] = [:]
        for memo in folderMemos {
            folderByKey[Self.mergeKey(for: memo.url)] = memo
        }

        let dbURL = dir.appendingPathComponent("CloudRecordings.db")
        if fileManager.fileExists(atPath: dbURL.path) {
            let result = readDatabase(at: dbURL, recordingsDir: dir)
            var matched = 0
            for row in result.rows {
                // Se prueban las claves candidatas en orden de fiabilidad:
                // ruta resuelta > nombre de fichero crudo de ZPATH > uid >
                // label. Un ZPATH nulo/obsoleto no debe perder la fila si
                // alguna de las otras claves casa con un fichero real.
                guard let key = row.mergeKeyCandidates.first(where: { folderByKey[$0] != nil }) else {
                    continue
                }
                // Se conserva el `url`/`downloadState` real de la carpeta y se
                // enriquece con título/fecha/duración/id de la fila de BD.
                let folderEntry = folderByKey[key]!
                folderByKey[key] = VoiceMemo(
                    id: row.id,
                    title: row.title,
                    date: row.date,
                    duration: row.duration,
                    url: folderEntry.url,
                    downloadState: folderEntry.downloadState
                )
                matched += 1
            }
            let walSuffix = result.walCopied ? " (wal copiado)" : ""
            if let stage = result.failureStage {
                LogStore.shared.append(
                    "CloudRecordings.db: \(stage) → listado por carpeta",
                    source: "voicememos"
                )
            } else {
                LogStore.shared.append(
                    "CloudRecordings.db: \(result.rowsSeen) filas, \(matched) emparejadas\(walSuffix)",
                    source: "voicememos"
                )
            }
        }

        let memos = Array(folderByKey.values)

        if memos.isEmpty {
            // El contenedor tiene contenido protegido que no hemos podido leer
            // (BD presente pero no abrible por TCC) → es un bloqueo de permisos,
            // no una biblioteca vacía.
            if fileManager.fileExists(atPath: dbURL.path), !canRead(dbURL) {
                return .accessDenied
            }
            return .empty
        }

        return .ok(memos.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
    }

    /// Clave de emparejamiento BD ↔ carpeta: nombre de fichero sin extensión,
    /// normalizado (minúsculas). Un `ZPATH` nulo u obsoleto en la BD no debe
    /// eliminar la nota — el emparejamiento se hace por este nombre, no por
    /// ruta absoluta.
    private static func mergeKey(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// Igual que `mergeKey(for:)` pero partiendo de un nombre de fichero (o
    /// cualquier texto de la BD que pueda serlo) en vez de una `URL`.
    private static func mergeKey(forFileName name: String) -> String {
        ((name as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
    }

    // MARK: - Lectura de CloudRecordings.db

    /// Fila leída de `ZCLOUDRECORDING` con metadatos y las claves candidatas
    /// por las que se intentará emparejarla con un fichero de carpeta, en
    /// orden de fiabilidad.
    private struct DatabaseRow {
        let id: String
        let title: String
        let date: Date?
        let duration: Double?
        let mergeKeyCandidates: [String]
    }

    /// Resultado de leer `CloudRecordings.db`, con diagnóstico para el
    /// registro de depuración (⌘L): la lectura es ahora por fila, así que un
    /// fallo parcial (columna ausente, `ZPATH` obsoleto) no tira toda la BD.
    private struct DatabaseReadResult {
        var rows: [DatabaseRow] = []
        var rowsSeen: Int = 0
        var walCopied: Bool = false
        /// Descripción corta del punto de fallo si no se pudo leer ninguna
        /// fila (p. ej. "no se pudo copiar el .db", "tabla ausente"). `nil`
        /// si la lectura fue correcta (aunque devuelva cero filas).
        var failureStage: String?
    }

    private func readDatabase(at dbURL: URL, recordingsDir: URL) -> DatabaseReadResult {
        // Copiamos la BD (y, si existen, sus `-wal`/`-shm`) a un directorio
        // temporal propio y abrimos ESA copia sin `immutable=1`, para que
        // SQLite reproduzca el WAL. Con `immutable=1` sobre el original,
        // SQLite ignora por completo el `-wal`: si Notas de voz no ha hecho
        // checkpoint todavía (frecuente), la consulta ve una instantánea
        // vieja o vacía — la trampa que nos mordió. Nunca se toca el
        // original: solo lecturas + copia, borrada al terminar.
        let snapshotDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VoiceMemosDBSnapshot", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        } catch {
            return DatabaseReadResult(failureStage: "no se pudo crear directorio temporal")
        }
        defer { try? fileManager.removeItem(at: snapshotDir) }

        let snapshotDB = snapshotDir.appendingPathComponent("CloudRecordings.db")
        do {
            try fileManager.copyItem(at: dbURL, to: snapshotDB)
        } catch {
            return DatabaseReadResult(failureStage: "no se pudo copiar el .db")
        }

        // `-wal`/`-shm` son best-effort: si no existen o no se pueden leer,
        // seguimos solo con el `.db` (se comporta como si estuviera
        // checkpointeado).
        var walCopied = false
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: snapshotDB.path + suffix)
            if (try? fileManager.copyItem(at: src, to: dst)) != nil, suffix == "-wal" {
                walCopied = true
            }
        }

        var db: OpaquePointer?
        let uri = snapshotDB.absoluteString + "?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return DatabaseReadResult(failureStage: "no se pudo abrir la copia")
        }
        defer { sqlite3_close(db) }

        // Esquema tolerante: solo pedimos las columnas que de verdad existen
        // en esta versión de macOS, para que la ausencia de una (p. ej.
        // `ZDURATION`) no tire la tabla entera.
        let availableColumns = tableColumns(db, table: "ZCLOUDRECORDING")
        guard !availableColumns.isEmpty else {
            return DatabaseReadResult(failureStage: "tabla ausente")
        }

        let wanted = ["ZUNIQUEID", "ZCUSTOMLABEL", "ZDATE", "ZDURATION", "ZPATH"]
        let columns = wanted.filter { availableColumns.contains($0) }
        guard !columns.isEmpty else {
            return DatabaseReadResult(failureStage: "sin columnas reconocidas")
        }
        var indexByColumn: [String: Int32] = [:]
        for (i, name) in columns.enumerated() { indexByColumn[name] = Int32(i) }

        let sql = "SELECT \(columns.joined(separator: ", ")) FROM ZCLOUDRECORDING"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return DatabaseReadResult(failureStage: "prepare falló")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [DatabaseRow] = []
        var rowsSeen = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowsSeen += 1
            let uid = indexByColumn["ZUNIQUEID"].flatMap { columnText(stmt, $0) }
            let label = indexByColumn["ZCUSTOMLABEL"].flatMap { columnText(stmt, $0) }
            let dateIdx = indexByColumn["ZDATE"]
            let hasDate = dateIdx.map { sqlite3_column_type(stmt, $0) != SQLITE_NULL } ?? false
            let dateVal = dateIdx.map { sqlite3_column_double(stmt, $0) } ?? 0
            let durIdx = indexByColumn["ZDURATION"]
            let hasDur = durIdx.map { sqlite3_column_type(stmt, $0) != SQLITE_NULL } ?? false
            let durVal = durIdx.map { sqlite3_column_double(stmt, $0) } ?? 0
            let path = indexByColumn["ZPATH"].flatMap { columnText(stmt, $0) }

            // Claves candidatas para emparejar con la carpeta, en orden de
            // fiabilidad: ruta resuelta (ZPATH válido) > nombre de fichero
            // crudo del texto de ZPATH (aunque esté obsoleto/no exista) >
            // ZUNIQUEID > ZCUSTOMLABEL. Un ZPATH nulo/obsoleto no pierde la
            // fila si alguna de las demás casa con un fichero real.
            var candidates: [String] = []
            var fallbackDisplayName: String?
            if let resolved = resolveURL(path: path, in: recordingsDir) {
                candidates.append(Self.mergeKey(for: resolved))
                fallbackDisplayName = resolved.deletingPathExtension().lastPathComponent
            }
            if let path, !path.isEmpty {
                let rawName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                candidates.append(Self.mergeKey(forFileName: rawName))
                if fallbackDisplayName == nil { fallbackDisplayName = rawName }
            }
            if let uid {
                candidates.append(Self.mergeKey(forFileName: uid))
                if fallbackDisplayName == nil { fallbackDisplayName = uid }
            }
            if let label, !label.isEmpty {
                candidates.append(Self.mergeKey(forFileName: label))
            }

            let fallbackTitle = fallbackDisplayName ?? label ?? "nota_de_voz"
            let title = (label?.isEmpty == false) ? label! : fallbackTitle
            rows.append(DatabaseRow(
                id: uid ?? fallbackTitle,
                title: title,
                // ZDATE es un timestamp Core Data: segundos desde 2001-01-01.
                date: hasDate ? Date(timeIntervalSinceReferenceDate: dateVal) : nil,
                duration: hasDur ? durVal : nil,
                mergeKeyCandidates: candidates
            ))
        }
        return DatabaseReadResult(rows: rows, rowsSeen: rowsSeen, walCopied: walCopied, failureStage: nil)
    }

    /// Nombres de columna reales de una tabla (`PRAGMA table_info`), vacío si
    /// la tabla no existe.
    private func tableColumns(_ db: OpaquePointer?, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA table_info: columna 1 = nombre.
            if let cString = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: cString))
            }
        }
        return names
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
        let candidate = recordingsDir.appendingPathComponent(name)
        guard fileExistsOrPlaceholder(candidate) else { return nil }
        return candidate
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
            let nameWithoutExtension = url.deletingPathExtension().lastPathComponent
            byPath[path] = VoiceMemo(
                id: url.lastPathComponent,
                title: nameWithoutExtension,
                date: dateFromRecordingFileName(nameWithoutExtension) ?? creation,
                duration: nil,
                url: url,
                downloadState: downloadState(for: url)
            )
        }
        return Array(byPath.values)
    }

    /// Parsea el patrón de nombre de fichero de Notas de voz
    /// `YYYYMMDD HHMMSS-XXXXXXXX` (sin extensión) a una fecha local. Devuelve
    /// `nil` si el nombre no encaja exactamente con el patrón. Usado en el
    /// fallback por carpeta: no sustituye al título/fecha reales de la BD,
    /// pero evita que todas las notas aparezcan con la misma fecha cuando
    /// iCloud las materializa de golpe.
    func dateFromRecordingFileName(_ name: String) -> Date? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard let datePart = parts.first else { return nil }
        let dateTime = datePart.split(separator: " ")
        guard dateTime.count == 2,
              dateTime[0].count == 8, dateTime[0].allSatisfy(\.isNumber),
              dateTime[1].count == 6, dateTime[1].allSatisfy(\.isNumber) else {
            return nil
        }

        var components = DateComponents()
        let datePartStr = String(dateTime[0])
        let timePartStr = String(dateTime[1])
        components.year = Int(datePartStr.prefix(4))
        components.month = Int(datePartStr.dropFirst(4).prefix(2))
        components.day = Int(datePartStr.dropFirst(6).prefix(2))
        components.hour = Int(timePartStr.prefix(2))
        components.minute = Int(timePartStr.dropFirst(2).prefix(2))
        components.second = Int(timePartStr.dropFirst(4).prefix(2))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard let date = calendar.date(from: components) else { return nil }
        // `Calendar.date(from:)` normaliza componentes fuera de rango (p. ej.
        // mes 13) en vez de fallar; recomponemos y comparamos para detectar
        // ese caso y devolver `nil` como un patrón realmente no conforme.
        let recomposed = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard recomposed.year == components.year,
              recomposed.month == components.month,
              recomposed.day == components.day,
              recomposed.hour == components.hour,
              recomposed.minute == components.minute,
              recomposed.second == components.second else {
            return nil
        }
        return date
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
