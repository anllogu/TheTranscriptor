import XCTest
@testable import TheTranscriptor

final class ExportersTests: XCTestCase {
    var transcript: Transcript!

    override func setUp() {
        super.setUp()

        let segments = [
            TranscriptSegment(start: 0.0, end: 4.2, speaker: "SPEAKER_00", text: "Hola, ¿qué tal?"),
            TranscriptSegment(start: 4.5, end: 8.1, speaker: "SPEAKER_01", text: "Bien, ¿y tú?"),
            TranscriptSegment(start: 8.3, end: 12.5, speaker: "SPEAKER_00", text: "Muy bien, gracias por preguntar.")
        ]

        transcript = Transcript(language: "es", duration: 12.5, segments: segments)
        transcript.setSpeakerName("Angel", for: "SPEAKER_00")
        transcript.setSpeakerName("María", for: "SPEAKER_01")
    }

    func testTxtExporterBasic() {
        let output = TxtExporter.export(transcript)

        XCTAssertTrue(output.contains("Angel: Hola, ¿qué tal?"))
        XCTAssertTrue(output.contains("María: Bien, ¿y tú?"))
        XCTAssertTrue(output.contains("Angel: Muy bien, gracias por preguntar."))
    }

    func testTxtExporterRespectsSpeakerNames() {
        let output = TxtExporter.export(transcript)

        // Should use renamed speakers, not original SPEAKER_00/SPEAKER_01
        XCTAssertFalse(output.contains("SPEAKER_00"))
        XCTAssertFalse(output.contains("SPEAKER_01"))
        XCTAssertTrue(output.contains("Angel:"))
        XCTAssertTrue(output.contains("María:"))
    }

    func testTxtExporterLineBreaks() {
        let output = TxtExporter.export(transcript)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 3, "Should have 3 segments")
    }

    func testSrtExporterBasic() {
        let output = SrtExporter.export(transcript)

        XCTAssertTrue(output.contains("1"))
        XCTAssertTrue(output.contains("2"))
        XCTAssertTrue(output.contains("3"))
    }

    func testSrtExporterTimestampFormat() {
        let output = SrtExporter.export(transcript)

        // Check for HH:MM:SS,mmm format
        XCTAssertTrue(output.contains("00:00:00,000"))
        XCTAssertTrue(output.contains("00:00:04,200"))
        XCTAssertTrue(output.contains("00:00:04,500"))
        XCTAssertTrue(output.contains("00:00:08,100"))
    }

    func testSrtExporterArrowFormat() {
        let output = SrtExporter.export(transcript)

        XCTAssertTrue(output.contains("-->"))
    }

    func testSrtExporterSpeakerPrefix() {
        let output = SrtExporter.export(transcript)

        XCTAssertTrue(output.contains("Angel: Hola, ¿qué tal?"))
        XCTAssertTrue(output.contains("María: Bien, ¿y tú?"))
    }

    func testSrtExporterSequentialIndex() {
        let output = SrtExporter.export(transcript)
        let lines = output.split(separator: "\n").map(String.init)

        // First segment index
        XCTAssertTrue(lines.contains("1"))
        // Second segment index
        XCTAssertTrue(lines.contains("2"))
        // Third segment index
        XCTAssertTrue(lines.contains("3"))
    }

    func testSrtExporterFormatStructure() {
        let output = SrtExporter.export(transcript)
        let blocks = output.split(separator: "\n\n").map(String.init)

        XCTAssertGreaterThanOrEqual(blocks.count, 3, "Should have at least 3 subtitle blocks")

        // Each block should have: index, timestamp, text, blank line
        for block in blocks {
            let lines = block.split(separator: "\n").map(String.init)
            XCTAssertGreaterThanOrEqual(lines.count, 3, "Each block should have index, timestamp, and text")
        }
    }

    func testExporterWithoutRenames() {
        var plainTranscript = Transcript(language: "es", duration: 12.5, segments: transcript.segments)
        // Don't set any speaker names

        let txtOutput = TxtExporter.export(plainTranscript)
        let srtOutput = SrtExporter.export(plainTranscript)

        XCTAssertTrue(txtOutput.contains("SPEAKER_00"))
        XCTAssertTrue(srtOutput.contains("SPEAKER_00"))
    }

    func testLargeTimestamps() {
        let longSegments = [
            TranscriptSegment(start: 3661.5, end: 3665.2, speaker: "SPEAKER_00", text: "Test")
        ]
        let longTranscript = Transcript(language: "es", duration: 3665.2, segments: longSegments)

        let srtOutput = SrtExporter.export(longTranscript)

        // 3661.5 seconds = 1 hour, 1 minute, 1.5 seconds
        XCTAssertTrue(srtOutput.contains("01:01:01,500"))
    }

    func testMillisecondPrecision() {
        let segments = [
            TranscriptSegment(start: 0.123, end: 1.456, speaker: "SPEAKER_00", text: "Test")
        ]
        let transcript = Transcript(language: "es", duration: 1.456, segments: segments)

        let srtOutput = SrtExporter.export(transcript)

        XCTAssertTrue(srtOutput.contains("00:00:00,123"))
        XCTAssertTrue(srtOutput.contains("00:00:01,456"))
    }
}
