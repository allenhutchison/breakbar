import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private enum Mode { case breakRequired, travelRequired }

    private var panel: NSPanel?
    private var mode: Mode?

    func show(
        startBreak: @escaping () -> Void,
        canDeferBreak: Bool,
        deferBreakTitle: String,
        deferBreak: @escaping () -> Void,
        pauseReminders: @escaping () -> Void
    ) {
        if panel != nil, mode != .breakRequired { hide() }
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
            rootView: BreakRequiredView(
                startBreak: startBreak,
                canDeferBreak: canDeferBreak,
                deferBreakTitle: deferBreakTitle,
                deferBreak: deferBreak,
                pauseReminders: pauseReminders
            )
        )
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mode = .breakRequired
        self.panel = panel
    }

    func showTravel(
        acknowledge: @escaping () -> Void,
        pauseReminders: @escaping () -> Void
    ) {
        if panel != nil, mode != .travelRequired { hide() }
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
            rootView: TravelRequiredView(
                acknowledge: acknowledge,
                pauseReminders: pauseReminders
            )
        )
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mode = .travelRequired
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        mode = nil
    }
}

private struct TravelRequiredView: View {
    @State private var isConfirmingPause = false
    let acknowledge: () -> Void
    let pauseReminders: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.88))
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "car.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(Color(red: 0.94, green: 0.48, blue: 0.12))

                VStack(spacing: 12) {
                    Text("TIME TO GO")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .tracking(1.5)
                    Text("Your travel block has started. Break reminders are paused while you’re away.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .multilineTextAlignment(.center)

                Button("I’m leaving", action: acknowledge)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.94, green: 0.48, blue: 0.12))
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])

                Button("Pause reminders") {
                    isConfirmingPause = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .padding(48)

            if isConfirmingPause {
                Color.black.opacity(0.72).ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("Pause reminders?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Reminders stay paused until you resume them.")
                        .foregroundStyle(.secondary)
                    Button("Pause reminders", role: .destructive) {
                        isConfirmingPause = false
                        pauseReminders()
                    }
                    .controlSize(.large)
                    Button("Keep working") { isConfirmingPause = false }
                        .buttonStyle(.plain)
                }
                .padding(32)
                .frame(width: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .contain)
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
    @State private var isConfirmingPause = false
    let startBreak: () -> Void
    let canDeferBreak: Bool
    let deferBreakTitle: String
    let deferBreak: () -> Void
    let pauseReminders: () -> Void

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

                    if canDeferBreak {
                        Button(deferBreakTitle, action: deferBreak)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityHint("Delays this break once. The next reminder requires a break.")
                    }

                    Button("Pause reminders") {
                        isConfirmingPause = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.65))
                }

                Text("Your work stays open. BreakBar never closes or changes another app.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .foregroundStyle(.white)
            .padding(48)

            if isConfirmingPause {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Text("Pause reminders?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Reminders stay paused until you resume them.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button("Pause reminders", role: .destructive) {
                        isConfirmingPause = false
                        pauseReminders()
                    }
                    .controlSize(.large)

                    Button("Keep working") {
                        isConfirmingPause = false
                    }
                    .buttonStyle(.plain)
                }
                .padding(32)
                .frame(width: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
