import Foundation

struct TxtExporter {
    static func export(_ transcript: Transcript) -> String {
        var lines: [String] = []

        for segment in transcript.segments {
            let displayName = transcript.displayName(for: segment.speaker)
            let line = "\(displayName): \(segment.text)"
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
