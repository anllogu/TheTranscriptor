import XCTest
@testable import TheTranscriptor

final class RequirementsCheckerTests: XCTestCase {
    var checker: RequirementsChecker!

    override func setUp() {
        super.setUp()
        checker = RequirementsChecker()
    }

    func testCheckRequirementsReturnsArray() {
        let checks = checker.checkRequirements()
        XCTAssertGreaterThan(checks.count, 0, "Should return at least one check")
    }

    func testCheckRequirementsIncludesPython() {
        let checks = checker.checkRequirements()
        let pythonChecks = checks.filter { $0.name.contains("Python") }
        XCTAssertGreaterThan(pythonChecks.count, 0, "Should include Python check")
    }

    func testCheckRequirementsIncludesFFmpeg() {
        let checks = checker.checkRequirements()
        let ffmpegChecks = checks.filter { $0.name == "ffmpeg" }
        XCTAssertGreaterThan(ffmpegChecks.count, 0, "Should include ffmpeg check")
    }

    func testCheckRequirementsIncludesPackages() {
        let checks = checker.checkRequirements()
        let packageChecks = checks.filter { $0.name.contains("Paquetes") }
        XCTAssertGreaterThan(packageChecks.count, 0, "Should include packages check")
    }

    func testCheckRequirementsIncludesHuggingFaceToken() {
        let checks = checker.checkRequirements()
        let tokenChecks = checks.filter { $0.name.contains("Hugging Face") }
        XCTAssertGreaterThan(tokenChecks.count, 0, "Should include Hugging Face token check")
    }

    func testCheckRequirementsWithToken() {
        let checks = checker.checkRequirements(huggingFaceToken: "hf_test123")
        let tokenChecks = checks.filter { $0.name.contains("Hugging Face") }
        XCTAssertGreaterThan(tokenChecks.count, 0)

        if let tokenCheck = tokenChecks.first {
            XCTAssertTrue(tokenCheck.status.isOk, "Token check should be OK when token is provided")
        }
    }

    func testCheckRequirementsWithoutToken() {
        let checks = checker.checkRequirements(huggingFaceToken: "")
        let tokenChecks = checks.filter { $0.name.contains("Hugging Face") }
        XCTAssertGreaterThan(tokenChecks.count, 0)

        if let tokenCheck = tokenChecks.first {
            XCTAssertFalse(tokenCheck.status.isOk, "Token check should be missing when token is empty")
        }
    }

    func testCheckRequirementsFFmpegMissing() {
        // This will depend on whether ffmpeg is installed
        let checks = checker.checkRequirements()
        let ffmpegChecks = checks.filter { $0.name == "ffmpeg" }

        if let ffmpegCheck = ffmpegChecks.first {
            // If ffmpeg is missing, check has instruction
            if !ffmpegCheck.status.isOk {
                if case .missing(let instruction) = ffmpegCheck.status {
                    XCTAssertFalse(instruction.isEmpty)
                }
            }
        }
    }

    func testRequirementCheckStatusMessages() {
        let okCheck = RequirementCheck.ffmpeg()
        XCTAssertTrue(okCheck.status.isOk)

        let missingCheck = RequirementCheck.ffmpegMissing()
        XCTAssertFalse(missingCheck.status.isOk)

        if case .missing(let instruction) = missingCheck.status {
            XCTAssertTrue(instruction.contains("brew install"))
        }
    }
}
