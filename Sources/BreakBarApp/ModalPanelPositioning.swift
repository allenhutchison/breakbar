import AppKit

@MainActor
enum ModalPanelPositioning {
    static func center(_ panel: NSPanel, on targetScreen: NSScreen? = nil) {
        guard let screen = targetScreen ?? activeScreen() else {
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

    nonisolated static func targetScreenIndex(
        preferredScreenIndex: Int?,
        pointerLocation: NSPoint,
        screenFrames: [NSRect]
    ) -> Int? {
        if let preferredScreenIndex,
           screenFrames.indices.contains(preferredScreenIndex)
        {
            return preferredScreenIndex
        }

        return screenFrames.firstIndex(where: {
            NSMouseInRect(pointerLocation, $0, false)
        }) ?? screenFrames.indices.first
    }

    private static func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let preferredScreenIndex = NSScreen.main.flatMap { mainScreen in
            screens.firstIndex(where: { $0 === mainScreen })
        }
        guard let targetIndex = targetScreenIndex(
            preferredScreenIndex: preferredScreenIndex,
            pointerLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame)
        ) else {
            return nil
        }
        return screens[targetIndex]
    }
}
