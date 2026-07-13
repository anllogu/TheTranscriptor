import XCTest
@testable import TheTranscriptor

final class PythonEnvironmentDetectorTests: XCTestCase {
    var detector: PythonEnvironmentDetector!

    override func setUp() {
        super.setUp()
        detector = PythonEnvironmentDetector()
    }

    func testDetectPythonFromCommonPaths() {
        // This test will pass on systems with Python installed
        // Testing on this Mac, we should find python3
        let pythonPath = detector.detectPythonPath()
        XCTAssertNotNil(pythonPath, "Should find Python on system")

        if let path = pythonPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                         "Python path should exist: \(path)")
        }
    }

    func testDetectPythonWithSavedPath() {
        // Create a temporary symlink for testing (if /usr/bin/python3 exists)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which python3"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pythonPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pythonPath.isEmpty {
                    // Test with saved path
                    let detected = detector.detectPythonPath(savedPath: pythonPath)
                    XCTAssertEqual(detected, pythonPath, "Should return saved path if valid")
                }
            }
        } catch {
            XCTFail("Failed to detect Python: \(error)")
        }
    }

    func testDetectPythonFromShell() {
        // Test the which command detection
        let pythonPath = detector.detectPythonPath()
        XCTAssertNotNil(pythonPath)
    }

    func testInvalidPythonPath() {
        let invalid = detector.detectPythonPath(savedPath: "/nonexistent/python3")
        // Should fall back to other paths and find something valid
        XCTAssertNotNil(invalid)
    }
}
