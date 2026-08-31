import AppKit
import SwiftUI

@main
struct BreakBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            BreakBarMenuView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.menuBarSymbol)
                Text(model.presentation.shortLabel)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .frame(
                        width: model.state.phase == .clockedOut ? nil : 58,
                        alignment: .trailing
                    )
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("BreakBar, \(model.presentation.shortLabel)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
