import AppKit
import SwiftUI

@MainActor
final class DiagnosticsWindowController {
    private var windowController: NSWindowController?
    private var hostingController: NSHostingController<DiagnosticsView>?

    func show(snapshot: DiagnosticsSnapshot, refresh: @escaping () -> Void) {
        let view = DiagnosticsView(snapshot: snapshot, refresh: refresh)

        if let windowController, let hostingController {
            hostingController.rootView = view
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BreakBar Diagnostics"
        window.minSize = NSSize(width: 580, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.center()

        let windowController = NSWindowController(window: window)
        self.hostingController = hostingController
        self.windowController = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
