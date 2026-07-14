import Foundation

struct Transcript: Codable {
    let language: String
    let duration: Double
    let segments: [TranscriptSegment]
    var speakerNames: [String: String]

    enum CodingKeys: String, CodingKey {
        case language
        case duration
        case segments
        case speakerNames
    }

    init(language: String, duration: Double, segments: [TranscriptSegment], speakerNames: [String: String] = [:]) {
        self.language = language
        self.duration = duration
        self.segments = segments
        self.speakerNames = speakerNames
    }

    // `result.json` (generado por transcriptor_local.py) nunca incluye
    // speakerNames, y el historial de transcripciones sí necesita que se
    // conserve tras un renombrado de hablante — decodeIfPresent mantiene
    // ambos casos compatibles con el mismo tipo.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        duration = try container.decode(Double.self, forKey: .duration)
        segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
    }

    func displayName(for speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }

    mutating func setSpeakerName(_ name: String, for speaker: String) {
        speakerNames[speaker] = name
    }
}
