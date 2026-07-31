import XCTest
@testable import TheTranscriptor

final class FFmpegDylibShimServiceTests: XCTestCase {
    var service: FFmpegDylibShimService!
    var tempDir: URL!
    var dylibsDir: URL!
    var shimDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service = FFmpegDylibShimService()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegShimTests-\(UUID().uuidString)", isDirectory: true)
        dylibsDir = tempDir.appendingPathComponent("dylibs", isDirectory: true)
        shimDir = tempDir.appendingPathComponent("shim", isDirectory: true)
        try FileManager.default.createDirectory(at: dylibsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func touch(_ name: String) throws {
        try Data().write(to: dylibsDir.appendingPathComponent(name))
    }

    // MARK: majorSoname

    func testMajorSonameForFfmpegLibraries() {
        XCTAssertEqual(FFmpegDylibShimService.majorSoname(for: "libavdevice.62.3.102.dylib"),
                       "libavdevice.62.dylib")
        XCTAssertEqual(FFmpegDylibShimService.majorSoname(for: "libavcodec.62.28.102.dylib"),
                       "libavcodec.62.dylib")
        XCTAssertEqual(FFmpegDylibShimService.majorSoname(for: "libswresample.6.3.102.dylib"),
                       "libswresample.6.dylib")
    }

    func testMajorSonameIgnoresNonFfmpegLibraries() {
        XCTAssertNil(FFmpegDylibShimService.majorSoname(for: "libSvtAv1Enc.4.1.0.dylib"))
        XCTAssertNil(FFmpegDylibShimService.majorSoname(for: "libx264.165.dylib"))
        XCTAssertNil(FFmpegDylibShimService.majorSoname(for: "libmp3lame.0.dylib"))
        XCTAssertNil(FFmpegDylibShimService.majorSoname(for: "notalib.txt"))
        XCTAssertNil(FFmpegDylibShimService.majorSoname(for: "libavutil.dylib"))
    }

    // MARK: rebuildShim

    func testRebuildShimCreatesMajorSonameSymlinks() throws {
        try touch("libavdevice.62.3.102.dylib")
        try touch("libavcodec.62.28.102.dylib")
        try touch("libavutil.60.26.102.dylib")
        try touch("libswscale.9.5.102.dylib")
        // ruido que NO debe symlinkarse
        try touch("libx264.165.dylib")
        try touch("libSvtAv1Enc.4.1.0.dylib")

        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)

        let links = try FileManager.default.contentsOfDirectory(atPath: shimDir.path).sorted()
        XCTAssertEqual(links, [
            "libavcodec.62.dylib",
            "libavdevice.62.dylib",
            "libavutil.60.dylib",
            "libswscale.9.dylib"
        ])

        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: shimDir.appendingPathComponent("libavdevice.62.dylib").path)
        XCTAssertEqual(dest, dylibsDir.appendingPathComponent("libavdevice.62.3.102.dylib").path)
    }

    func testRebuildShimIsIdempotent() throws {
        try touch("libavdevice.62.3.102.dylib")

        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)
        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)

        let links = try FileManager.default.contentsOfDirectory(atPath: shimDir.path)
        XCTAssertEqual(links, ["libavdevice.62.dylib"])
    }

    func testRebuildShimRefreshesWhenVersionChanges() throws {
        try touch("libavdevice.62.3.102.dylib")
        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)

        // Simula una actualización de PyAV: distinto fichero versionado.
        try FileManager.default.removeItem(
            at: dylibsDir.appendingPathComponent("libavdevice.62.3.102.dylib"))
        try touch("libavdevice.62.4.100.dylib")

        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)

        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: shimDir.appendingPathComponent("libavdevice.62.dylib").path)
        XCTAssertEqual(dest, dylibsDir.appendingPathComponent("libavdevice.62.4.100.dylib").path)
    }

    func testRebuildShimWithNoFfmpegLibrariesCreatesEmptyDir() throws {
        try touch("libx264.165.dylib")

        try service.rebuildShim(fromDylibs: dylibsDir, into: shimDir)

        let links = try FileManager.default.contentsOfDirectory(atPath: shimDir.path)
        XCTAssertTrue(links.isEmpty)
    }
}
