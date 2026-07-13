import Foundation

struct TranscriptSegment: Codable, Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let speaker: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case speaker
        case text
    }

    init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}
