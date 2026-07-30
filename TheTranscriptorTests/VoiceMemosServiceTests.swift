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

    private func createDatabase(
        rows: [(uid: String, label: String?, date: Double?, duration: Double?, path: String)]
    ) {
        let dbURL = tempDir.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE ZCLOUDRECORDING (
            Z_PK INTEGER PRIMARY KEY,
            ZUNIQUEID TEXT,
            ZCUSTOMLABEL TEXT,
            ZDATE REAL,
            ZDURATION REAL,
            ZPATH TEXT
        )
        """)
        for row in rows {
            let label = row.label.map { "'\($0)'" } ?? "NULL"
            let date = row.date.map { String($0) } ?? "NULL"
            let duration = row.duration.map { String($0) } ?? "NULL"
            exec(db, """
            INSERT INTO ZCLOUDRECORDING (ZUNIQUEID, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH)
            VALUES ('\(row.uid)', \(label), \(date), \(duration), '\(row.path)')
            """)
        }
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
