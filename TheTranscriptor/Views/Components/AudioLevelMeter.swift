import SwiftUI

struct AudioLevelMeter: View {
    let level: Float

    private let barCount = 24

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color(for: index))
                        .opacity(isActive(index) ? 1 : 0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 48)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func isActive(_ index: Int) -> Bool {
        Float(index) / Float(barCount) < level
    }

    private func color(for index: Int) -> Color {
        let ratio = Float(index) / Float(barCount)
        if ratio > 0.85 { return .red }
        if ratio > 0.6 { return .yellow }
        return .green
    }
}
