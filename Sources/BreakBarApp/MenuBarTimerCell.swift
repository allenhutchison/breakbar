import SwiftUI

/// Keeps timer glyphs stable inside the circular timer instrument.
struct StableTimerText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight
    let width: CGFloat
    let alignment: Alignment

    var body: some View {
        ZStack(alignment: alignment) {
            Text("+88:88")
                .font(timerFont)
                .hidden()
                .accessibilityHidden(true)
            Text(text)
                .font(timerFont)
                .lineLimit(1)
        }
        .frame(width: width, alignment: alignment)
        .fixedSize(horizontal: true, vertical: false)
        .transaction { $0.animation = nil }
    }

    private var timerFont: Font {
        .custom("Menlo", fixedSize: fontSize).weight(weight)
    }
}
