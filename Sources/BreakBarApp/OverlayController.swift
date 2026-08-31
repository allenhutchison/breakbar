import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?

    func show(startBreak: @escaping () -> Void, clockOut: @escaping () -> Void) {
        guard panel == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let panel = BreakOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(
            rootView: BreakRequiredView(startBreak: startBreak, clockOut: clockOut)
        )
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class BreakOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Escape is intentionally ignored. The visible controls remain available.
    }
}

private struct BreakRequiredView: View {
    let startBreak: () -> Void
    let clockOut: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.88))
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: 0.98)
                        .stroke(
                            Color(red: 0.97, green: 0.24, blue: 0.27),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 150, height: 150)

                VStack(spacing: 12) {
                    Text("TIME TO GET UP")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .tracking(1.5)
                    Text("Start the break here. A connected accessory can do this too.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    Button("Start break on this Mac", action: startBreak)
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.97, green: 0.24, blue: 0.27))
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])

                    Button("Clock out instead", action: clockOut)
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.65))
                }

                Text("Your work stays open. BreakBar never closes or changes another app.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .foregroundStyle(.white)
            .padding(48)
        }
        .accessibilityElement(children: .contain)
    }
}
