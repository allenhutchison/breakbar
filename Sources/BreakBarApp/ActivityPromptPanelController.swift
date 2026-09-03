import AppKit
import SwiftUI

@MainActor
final class ActivityPromptPanelController {
    private var panel: NSPanel?
    private var promptKey: String?

    func show(
        key: String,
        title: String,
        detail: String,
        symbolName: String,
        accent: NSColor,
        primaryTitle: String,
        secondaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) {
        if panel != nil, promptKey != key {
            hide()
        }
        guard panel == nil else { return }

        let panelSize = NSSize(width: 420, height: 270)
        let panel = ActivityPromptPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = NSHostingController(
            rootView: ActivityPromptView(
                title: title,
                detail: detail,
                symbolName: symbolName,
                accent: Color(nsColor: accent),
                primaryTitle: primaryTitle,
                secondaryTitle: secondaryTitle,
                primaryAction: primaryAction,
                secondaryAction: secondaryAction
            )
        )
        position(panel, size: panelSize)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        promptKey = key
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        promptKey = nil
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        )
    }
}

private final class ActivityPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Keep the prompt visible until the user chooses an explicit action.
    }
}

private struct ActivityPromptView: View {
    let title: String
    let detail: String
    let symbolName: String
    let accent: Color
    let primaryTitle: String
    let secondaryTitle: String
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 56, height: 56)
                .background(accent.opacity(0.14), in: Circle())

            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button(secondaryTitle, action: secondaryAction)
                    .controlSize(.large)

                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 270)
        .background(.ultraThinMaterial)
    }
}
