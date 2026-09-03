import AppKit
import SwiftUI

@MainActor
final class TodayHistoryWindowController {
    private var windowController: NSWindowController?

    func show(model: AppModel) {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Today"
        window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: TodayHistoryView(model: model)
        )
        window.center()

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
