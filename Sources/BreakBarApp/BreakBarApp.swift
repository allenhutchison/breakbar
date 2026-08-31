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
                if let timer = model.presentation.timer {
                    MenuBarTimerCell(timer: timer)
                } else {
                    Text(model.presentation.statusLabel)
                        .font(.system(.body).weight(.semibold))
                }
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
