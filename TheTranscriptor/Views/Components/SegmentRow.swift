import SwiftUI

private let speakerPalette: [Color] = [
    .blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo
]

func speakerColor(index: Int) -> Color {
    speakerPalette[index % speakerPalette.count]
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerIndex: Int
    let displayName: String
    var onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draftName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeLabel(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Nombre del hablante", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline.bold())
                        .frame(maxWidth: 200)
                } else {
                    Button {
                        draftName = displayName
                        isEditing = true
                    } label: {
                        Text(displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(speakerColor(index: speakerIndex))
                    }
                    .buttonStyle(.plain)
                }

                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func commitRename() {
        isEditing = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
