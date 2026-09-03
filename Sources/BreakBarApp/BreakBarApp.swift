import AppKit
import SwiftUI

@main
struct BreakBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("Today", id: "today-history") {
            TodayHistoryView(model: appDelegate.model)
        }
        .defaultSize(width: 620, height: 620)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
