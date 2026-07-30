import XCTest
@testable import TheTranscriptor

final class ModelsTests: XCTestCase {
    func testTranscriptSegmentCodable() {
        let segment = TranscriptSegment(start: 0.0, end: 4.2, speaker: "SPEAKER_00", text: "Hola…")

        let encoder = JSONEncoder()
        let data = try! encoder.encode(segment)

        let decoder = JSONDecoder()
        let decodedSegment = try! decoder.decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(decodedSegment.start, 0.0)
        XCTAssertEqual(decodedSegment.end, 4.2)
        XCTAssertEqual(decodedSegment.speaker, "SPEAKER_00")
        XCTAssertEqual(decodedSegment.text, "Hola…")
    }

    func testTranscriptDecodingFromJSON() {
        let json = """
        {
          "language": "es",
          "duration": 1834.2,
          "segments": [
            { "start": 0.0, "end": 4.2, "speaker": "SPEAKER_00", "text": "Hola…" },
            { "start": 4.5, "end": 8.1, "speaker": "SPEAKER_01", "text": "¿Qué tal?" }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let transcript = try! decoder.decode(Transcript.self, from: json)

        XCTAssertEqual(transcript.language, "es")
        XCTAssertEqual(transcript.duration, 1834.2)
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].start, 0.0)
        XCTAssertEqual(transcript.segments[0].end, 4.2)
        XCTAssertEqual(transcript.segments[0].speaker, "SPEAKER_00")
        XCTAssertEqual(transcript.segments[0].text, "Hola…")
        XCTAssertEqual(transcript.segments[1].start, 4.5)
        XCTAssertEqual(transcript.segments[1].speaker, "SPEAKER_01")
    }

    func testDefaultMeetingSpeakerNames() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 2.0, speaker: "SPEAKER_00", text: "Hola"),
            TranscriptSegment(start: 2.0, end: 4.0, speaker: "SPEAKER_01", text: "Buenas"),
            TranscriptSegment(start: 4.0, end: 6.0, speaker: "SPEAKER_00", text: "¿Qué tal?"),
            TranscriptSegment(start: 6.0, end: 8.0, speaker: "SPEAKER_02", text: "Bien"),
        ]
        let transcript = Transcript(language: "es", duration: 8.0, segments: segments)

        let names = AppState.defaultMeetingSpeakerNames(for: transcript)

        XCTAssertEqual(names["SPEAKER_00"], "Yo")
        XCTAssertEqual(names["SPEAKER_01"], "Interlocutor 1")
        XCTAssertEqual(names["SPEAKER_02"], "Interlocutor 2")
        XCTAssertEqual(names.count, 3)
    }

    func testTranscriptDisplayName() {
        var transcript = Transcript(language: "es", duration: 100.0, segments: [])

        XCTAssertEqual(transcript.displayName(for: "SPEAKER_00"), "SPEAKER_00")

        transcript.setSpeakerName("Angel", for: "SPEAKER_00")
        XCTAssertEqual(transcript.displayName(for: "SPEAKER_00"), "Angel")
    }

    func testTranscriptSpeakerNamesRoundTripsThroughCodable() throws {
        var transcript = Transcript(language: "es", duration: 100.0, segments: [])
        transcript.setSpeakerName("Angel", for: "SPEAKER_00")

        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        XCTAssertEqual(decoded.displayName(for: "SPEAKER_00"), "Angel")
    }

    func testPipelinePhaseDisplayName() {
        XCTAssertEqual(PipelinePhase.converting.displayName, "Convirtiendo audio…")
        XCTAssertEqual(PipelinePhase.transcribing.displayName, "Transcribiendo…")
        XCTAssertEqual(PipelinePhase.diarizing.displayName, "Diarizando…")
        XCTAssertEqual(PipelinePhase.merging.displayName, "Uniendo resultados…")
    }

    func testPipelinePhaseRawValue() {
        XCTAssertEqual(PipelinePhase.converting.rawValue, "CONVERTING")
        XCTAssertEqual(PipelinePhase.transcribing.rawValue, "TRANSCRIBING")
        XCTAssertEqual(PipelinePhase.diarizing.rawValue, "DIARIZING")
        XCTAssertEqual(PipelinePhase.merging.rawValue, "MERGING")
    }

    func testWhisperModelRawValue() {
        XCTAssertEqual(WhisperModel.tiny.rawValue, "tiny")
        XCTAssertEqual(WhisperModel.base.rawValue, "base")
        XCTAssertEqual(WhisperModel.small.rawValue, "small")
        XCTAssertEqual(WhisperModel.medium.rawValue, "medium")
        XCTAssertEqual(WhisperModel.largeV3.rawValue, "large-v3")
    }

    func testWhisperModelInit() {
        XCTAssertEqual(WhisperModel(rawValue: "tiny"), .tiny)
        XCTAssertEqual(WhisperModel(rawValue: "base"), .base)
        XCTAssertEqual(WhisperModel(rawValue: "small"), .small)
        XCTAssertEqual(WhisperModel(rawValue: "medium"), .medium)
        XCTAssertEqual(WhisperModel(rawValue: "large-v3"), .largeV3)
        XCTAssertNil(WhisperModel(rawValue: "unknown"))
    }

    func testWhisperModelDisplayName() {
        XCTAssertTrue(WhisperModel.tiny.displayName.contains("mínimo tamaño"))
        XCTAssertTrue(WhisperModel.largeV3.displayName.contains("máxima calidad"))
    }

    func testRequirementCheckOk() {
        let check = RequirementCheck.ffmpeg()
        XCTAssertTrue(check.status.isOk)
        XCTAssertEqual(check.name, "ffmpeg")
    }

    func testRequirementCheckMissing() {
        let check = RequirementCheck.ffmpegMissing()
        XCTAssertFalse(check.status.isOk)
        XCTAssertEqual(check.name, "ffmpeg")
    }

    func testRequirementCheckPackagesMissing() {
        let check = RequirementCheck.packagesMissing(["faster-whisper", "pyannote.audio"])
        XCTAssertFalse(check.status.isOk)
        if case .missing(let instruction) = check.status {
            XCTAssertTrue(instruction.contains("pip install"))
        } else {
            XCTFail("Expected .missing status")
        }
    }
}
