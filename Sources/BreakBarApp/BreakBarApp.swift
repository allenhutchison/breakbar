import AppKit
import SwiftUI

@main
struct BreakBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
