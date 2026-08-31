import BreakBarCore
import SwiftUI

/// The single menu-bar rendering path for every countdown and count-up state.
struct MenuBarTimerCell: View {
    let timer: BreakBarTimerPresentation

    var body: some View {
        Text(timer.text)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .frame(width: 58, alignment: .trailing)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch timer.direction {
        case .countDown:
            "\(timer.text) remaining"
        case .countUp:
            "\(timer.text.dropFirst()) elapsed"
        }
    }
}
