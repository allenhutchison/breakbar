import AppKit

@MainActor
enum ModalPanelPositioning {
    static func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(centeredOrigin(size: panel.frame.size, in: visibleFrame))
    }

    nonisolated static func centeredOrigin(size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
    }
}
