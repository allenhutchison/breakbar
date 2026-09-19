import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var windowController: NSWindowController?

    func show(
        model: AppModel,
        requestNotificationAccess: @escaping () -> Void
    ) {
        let view = OnboardingView(
            model: model,
            requestNotificationAccess: requestNotificationAccess,
            finish: { [weak self] in
                OnboardingPreferences.markCompleted()
                self?.windowController?.close()
            }
        )

        if let windowController, let window = windowController.window {
            window.contentViewController = NSHostingController(rootView: view)
            windowController.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up BreakBar"
        window.contentMinSize = NSSize(width: 680, height: 580)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 720, height: 620))
        ModalPanelPositioning.center(window)

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
