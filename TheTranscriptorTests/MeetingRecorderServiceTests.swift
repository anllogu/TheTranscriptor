import XCTest
@testable import TheTranscriptor

/// Verifica el cálculo puro de offsets entre las dos pistas de una reunión.
final class MeetingRecorderServiceTests: XCTestCase {
    func testMicStartsFirst() {
        let mic = Date(timeIntervalSince1970: 1_000)
        let system = mic.addingTimeInterval(0.05)
        let (micOffset, systemOffset) = MeetingRecorderService.offsets(micStart: mic, systemStart: system)
        XCTAssertEqual(micOffset, 0, accuracy: 1e-4)
        XCTAssertEqual(systemOffset, 0.05, accuracy: 1e-4)
    }

    func testSystemStartsFirst() {
        let system = Date(timeIntervalSince1970: 1_000)
        let mic = system.addingTimeInterval(0.03)
        let (micOffset, systemOffset) = MeetingRecorderService.offsets(micStart: mic, systemStart: system)
        XCTAssertEqual(micOffset, 0.03, accuracy: 1e-4)
        XCTAssertEqual(systemOffset, 0, accuracy: 1e-4)
    }

    func testSimultaneousStart() {
        let t = Date(timeIntervalSince1970: 1_000)
        let (micOffset, systemOffset) = MeetingRecorderService.offsets(micStart: t, systemStart: t)
        XCTAssertEqual(micOffset, 0, accuracy: 1e-4)
        XCTAssertEqual(systemOffset, 0, accuracy: 1e-4)
    }
}
