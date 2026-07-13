import Foundation

struct SrtExporter {
    static func export(_ transcript: Transcript) -> String {
        var lines: [String] = []
        var index = 1

        for segment in transcript.segments {
            let startTime = formatTime(segment.start)
            let endTime = formatTime(segment.end)
            let displayName = transcript.displayName(for: segment.speaker)

            lines.append("\(index)")
            lines.append("\(startTime) --> \(endTime)")
            lines.append("\(displayName): \(segment.text)")
            lines.append("")

            index += 1
        }

        return lines.joined(separator: "\n")
    }

    private static func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let milliseconds = Int(round((seconds - Double(totalSeconds)) * 1000))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
}
