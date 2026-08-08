import XCTest
import SQLite3
@testable import TheTranscriptor

final class VoiceMemosServiceTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("VoiceMemosServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeM4A(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "SQL failed: \(sql)")
    }

    /// - Parameter columns: columnas a crear en la tabla; por defecto todas.
    ///   Permite simular un esquema parcial (p. ej. sin `ZDURATION`).
    /// - Parameter pathLiteral: si se pasa, se usa literalmente como
    ///   expresión SQL del valor de `ZPATH` (p. ej. `"NULL"`) en vez de
    ///   derivarlo de `row.path`.
    /// - Parameter walMode: si es `true`, activa `PRAGMA journal_mode=WAL` y
    ///   **no hace checkpoint** antes de cerrar — las filas quedan solo en el
    ///   `-wal`, no en el `.db` principal.
    @discardableResult
    private func createDatabase(
        rows: [(uid: String, label: String?, date: Double?, duration: Double?, path: String?)],
        columns: [String] = ["ZUNIQUEID", "ZCUSTOMLABEL", "ZDATE", "ZDURATION", "ZPATH"],
        walMode: Bool = false
    ) -> URL {
        let dbURL = tempDir.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        if walMode {
            exec(db, "PRAGMA journal_mode=WAL")
        }

        let columnDefs = columns.map { name -> String in
            switch name {
            case "ZUNIQUEID", "ZCUSTOMLABEL", "ZPATH": return "\(name) TEXT"
            default: return "\(name) REAL"
            }
        }.joined(separator: ",\n            ")
        exec(db, """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            \(columnDefs)
        )
        """)
        for row in rows {
            var values: [String: String] = [:]
            values["ZUNIQUEID"] = "'\(row.uid)'"
            values["ZCUSTOMLABEL"] = row.label.map { "'\($0)'" } ?? "NULL"
            values["ZDATE"] = row.date.map { String($0) } ?? "NULL"
            values["ZDURATION"] = row.duration.map { String($0) } ?? "NULL"
            values["ZPATH"] = row.path.map { "'\($0)'" } ?? "NULL"
            let present = columns.filter { values[$0] != nil }
            let insertValues = present.map { values[$0]! }.joined(separator: ", ")
            exec(db, """
            INSERT INTO ZCLOUDRECORDING (\(present.joined(separator: ", ")))
            VALUES (\(insertValues))
            """)
        }
        // En modo WAL, cerramos sin checkpoint: las filas quedan solo en el
        // `-wal`, que es exactamente el escenario que rompía la lectura con
        // `?immutable=1` (SQLite lo ignora por completo).
        return dbURL
    }

    // MARK: - Lectura de la BD

    func testLoadLibraryReadsDatabase() throws {
        _ = try writeM4A("rec1.m4a")
        _ = try writeM4A("rec2.m4a")
        // ZDATE es un timestamp Core Data (segundos desde 2001-01-01).
        createDatabase(rows: [
            (uid: "A", label: "Reunión equipo", date: 700_000_000, duration: 42.5, path: "rec1.m4a"),
            (uid: "B", label: "Idea rápida", date: 700_100_000, duration: 12.0, path: "rec2.m4a")
        ])

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }

        XCTAssertEqual(memos.count, 2)
        // Orden por fecha descendente: la más reciente primero.
        XCTAssertEqual(memos[0].title, "Idea rápida")
        XCTAssertEqual(memos[1].title, "Reunión equipo")
        XCTAssertEqual(memos[1].duration ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(
            memos[1].date?.timeIntervalSinceReferenceDate ?? 0,
            700_000_000,
            accuracy: 0.001
        )
    }

    func testLoadLibraryFallsBackToLabelFromFileName() throws {
        _ = try writeM4A("20240101 120000.m4a")
        createDatabase(rows: [
            (uid: "A", label: nil, date: 700_000_000, duration: nil, path: "20240101 120000.m4a")
        ])

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].title, "20240101 120000")
    }

    // MARK: - Fallback por carpeta

    func testLoadLibraryFallbackListsFilesWithoutDatabase() throws {
        _ = try writeM4A("nota-a.m4a")
        _ = try writeM4A("nota-b.m4a")

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 2)
        XCTAssertTrue(memos.allSatisfy { $0.duration == nil })
        XCTAssertEqual(Set(memos.map(\.title)), ["nota-a", "nota-b"])
    }

    // MARK: - Estados vacío / no disponible

    func testLoadLibraryEmptyWhenNoRecordings() {
        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        XCTAssertEqual(service.loadLibrary(), .empty)
    }

    func testLoadLibraryUnavailableWhenDirectoryMissing() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let service = VoiceMemosService(recordingsDirectoryOverride: missing)
        XCTAssertEqual(service.loadLibrary(), .unavailable)
    }

    func testLoadLibraryAccessDeniedWhenDirectoryUnreadable() throws {
        let protectedDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        try Data([0]).write(to: protectedDir.appendingPathComponent("CloudRecordings.db"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: protectedDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: protectedDir.path)
        }

        let service = VoiceMemosService(recordingsDirectoryOverride: protectedDir)
        XCTAssertEqual(service.loadLibrary(), .accessDenied)
    }

    // MARK: - Unión BD + carpeta

    func testLoadLibraryReadsFromWALBeforeCheckpoint() throws {
        _ = try writeM4A("rec1.m4a")
        // BD en modo WAL, insertada y cerrada SIN checkpoint: con
        // `?immutable=1` (comportamiento antiguo) estas filas serían
        // invisibles porque SQLite ignora el `-wal` de una BD inmutable. Es
        // la prueba de regresión clave de la copia-instantánea.
        createDatabase(
            rows: [(uid: "A", label: "Reunión importante", date: 700_000_000, duration: 42.5, path: "rec1.m4a")],
            walMode: true
        )

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].title, "Reunión importante")
        XCTAssertEqual(memos[0].duration ?? 0, 42.5, accuracy: 0.001)
    }

    func testLoadLibraryMergesStaleOrNullPathByFileName() throws {
        _ = try writeM4A("rec1.m4a")
        // ZPATH nulo: el emparejamiento con el fichero de carpeta se apoya en
        // que ZUNIQUEID coincide con el nombre base del `.m4a` presente.
        createDatabase(rows: [
            (uid: "rec1", label: "Reunión con ZPATH nulo", date: 700_000_000, duration: 10.0, path: nil)
        ])

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 1, "no debe duplicarse ni perderse")
        XCTAssertEqual(memos[0].title, "Reunión con ZPATH nulo")
    }

    func testLoadLibraryMergesStalePathByFileName() throws {
        _ = try writeM4A("rec1.m4a")
        // ZPATH apunta a una ruta absoluta obsoleta que ya no existe; el
        // emparejamiento cae al nombre de fichero del propio ZPATH.
        createDatabase(rows: [
            (uid: "A", label: "Reunión con ruta obsoleta", date: 700_000_000, duration: 10.0,
             path: "/Volumes/old-disk/does-not-exist/rec1.m4a")
        ])

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].title, "Reunión con ruta obsoleta")
    }

    func testLoadLibraryPartialSchemaMissingDuration() throws {
        _ = try writeM4A("rec1.m4a")
        _ = try writeM4A("rec2.m4a")
        createDatabase(
            rows: [
                (uid: "A", label: "Primera", date: 700_000_000, duration: nil, path: "rec1.m4a"),
                (uid: "B", label: "Segunda", date: 700_100_000, duration: nil, path: "rec2.m4a")
            ],
            columns: ["ZUNIQUEID", "ZCUSTOMLABEL", "ZDATE", "ZPATH"]
        )

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 2)
        XCTAssertTrue(memos.allSatisfy { $0.duration == nil })
        XCTAssertEqual(Set(memos.map(\.title)), ["Primera", "Segunda"])
    }

    func testLoadLibraryIncludesFilesWithoutDatabaseRow() throws {
        _ = try writeM4A("rec1.m4a")
        _ = try writeM4A("sin-fila-en-bd.m4a")
        createDatabase(rows: [
            (uid: "A", label: "Con fila en BD", date: 700_000_000, duration: 5.0, path: "rec1.m4a")
        ])

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        guard case .ok(let memos) = service.loadLibrary() else {
            return XCTFail("Se esperaba .ok")
        }
        XCTAssertEqual(memos.count, 2)
        XCTAssertEqual(Set(memos.map(\.title)), ["Con fila en BD", "sin-fila-en-bd"])
    }

    // MARK: - Nombre de fichero → fecha

    func testDateFromRecordingFileNameParsesPattern() {
        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        let date = service.dateFromRecordingFileName("20250608 175210-ED79C8DA")
        XCTAssertNotNil(date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 17)
        XCTAssertEqual(components.minute, 52)
        XCTAssertEqual(components.second, 10)
    }

    func testDateFromRecordingFileNameReturnsNilForNonConformingNames() {
        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        XCTAssertNil(service.dateFromRecordingFileName("nota-a"))
        XCTAssertNil(service.dateFromRecordingFileName("20250608.m4a"))
        XCTAssertNil(service.dateFromRecordingFileName(""))
    }

    // MARK: - Copia para transcribir

    func testCopyForTranscriptionLeavesOriginalUntouched() throws {
        let original = try writeM4A("importante.m4a")
        let memo = VoiceMemo(
            id: "A",
            title: "Nota importante",
            date: nil,
            duration: nil,
            url: original,
            downloadState: .downloaded
        )

        let service = VoiceMemosService(recordingsDirectoryOverride: tempDir)
        let copy = try service.copyForTranscription(memo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNotEqual(copy.path, original.path)
        XCTAssertEqual(copy.pathExtension, "m4a")
        XCTAssertEqual(copy.deletingPathExtension().lastPathComponent, "Nota importante")
    }
}
