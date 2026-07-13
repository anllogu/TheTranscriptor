import Foundation

struct Transcript: Codable {
    let language: String
    let duration: Double
    let segments: [TranscriptSegment]
    var speakerNames: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case language
        case duration
        case segments
    }

    func displayName(for speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }

    mutating func setSpeakerName(_ name: String, for speaker: String) {
        speakerNames[speaker] = name
    }
}
