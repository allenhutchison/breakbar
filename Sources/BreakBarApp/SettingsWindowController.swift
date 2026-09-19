import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var windowController: NSWindowController?

    func show(
        model: AppModel,
        checkForUpdates: @escaping () -> Void,
        requestNotificationAccess: @escaping () -> Void,
        runOnboarding: @escaping () -> Void
    ) {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BreakBar Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                model: model,
                checkForUpdates: checkForUpdates,
                requestNotificationAccess: requestNotificationAccess,
                runOnboarding: runOnboarding
            )
        )
        window.center()

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
