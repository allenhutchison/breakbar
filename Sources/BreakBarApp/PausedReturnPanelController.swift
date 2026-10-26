import AppKit
import SwiftUI

@MainActor
final class PausedReturnPanelController {
    private var panel: NSPanel?

    func show(
        bringToFront: Bool = false,
        resume: @escaping () -> Void,
        keepPaused: @escaping () -> Void
    ) {
        if let panel {
            if bringToFront { panel.orderFrontRegardless() }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 220),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Resume reminders?"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentViewController = NSHostingController(rootView:
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome back")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Break reminders are still paused. Ready to start a fresh focus cycle?")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Resume reminders", action: resume)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                        .accessibilityIdentifier("paused-return.resume")
                    Button("Keep paused", action: keepPaused)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("paused-return.keep-paused")
                }
                .controlSize(.large)
                Text("If you keep reminders paused, we’ll ask after your next time away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 410, height: 220)
        )
        ModalPanelPositioning.center(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
