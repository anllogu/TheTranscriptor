import Foundation

struct TxtExporter {
    static func export(_ transcript: Transcript) -> String {
        var lines: [String] = []
        var currentSpeaker: String?
        var currentStart: Double = 0
        var currentTexts: [String] = []

        func flush() {
            guard let speaker = currentSpeaker else { return }
            let displayName = transcript.displayName(for: speaker)
            let timestamp = formatTime(currentStart)
            lines.append("[\(timestamp)] \(displayName): \(currentTexts.joined(separator: " "))")
        }

        for segment in transcript.segments {
            if segment.speaker != currentSpeaker {
                flush()
                currentSpeaker = segment.speaker
                currentStart = segment.start
                currentTexts = [segment.text]
            } else {
                currentTexts.append(segment.text)
            }
        }
        flush()

        return lines.joined(separator: "\n")
    }

    private static func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
