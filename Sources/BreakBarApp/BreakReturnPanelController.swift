import AppKit
import BreakBarCore
import SwiftUI

@MainActor
final class BreakReturnPanelController {
    private var panel: NSPanel?
    private var panelState: BreakReturnPanelState?

    func show(
        presentation: BreakBarPresentation,
        canReturn: Bool,
        bringToFront: Bool = false,
        returnToFocus: @escaping () -> Void,
        clockOut: @escaping () -> Void
    ) {
        if let panelState {
            panelState.update(presentation: presentation, canReturn: canReturn)
            if bringToFront {
                panel?.orderFrontRegardless()
            }
            return
        }

        let panelState = BreakReturnPanelState(
            presentation: presentation,
            canReturn: canReturn,
            returnToFocus: returnToFocus,
            clockOut: clockOut
        )
        let panelSize = NSSize(width: 390, height: 250)
        let panel = BreakReturnPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
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
            rootView: BreakReturnPanelView(state: panelState)
        )
        position(panel, size: panelSize)
        panel.orderFrontRegardless()

        self.panelState = panelState
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        panelState = nil
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
                y: visibleFrame.maxY - size.height - 28
            )
        )
    }
}

private final class BreakReturnPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Keep the return prompt available until the break ends or work stops.
    }
}

@MainActor
private final class BreakReturnPanelState: ObservableObject {
    @Published private(set) var presentation: BreakBarPresentation
    @Published private(set) var canReturn: Bool

    let returnToFocus: () -> Void
    let clockOut: () -> Void

    init(
        presentation: BreakBarPresentation,
        canReturn: Bool,
        returnToFocus: @escaping () -> Void,
        clockOut: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.canReturn = canReturn
        self.returnToFocus = returnToFocus
        self.clockOut = clockOut
    }

    func update(presentation: BreakBarPresentation, canReturn: Bool) {
        guard self.presentation != presentation || self.canReturn != canReturn else { return }
        self.presentation = presentation
        self.canReturn = canReturn
    }
}

private struct BreakReturnPanelView: View {
    @ObservedObject var state: BreakReturnPanelState

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: state.canReturn ? "figure.walk.arrival" : "cup.and.heat.waves.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 46, height: 46)
                    .background(accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.canReturn ? "Welcome back" : "Break in progress")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(
                        state.canReturn
                            ? "Return when you’re ready to begin a fresh focus cycle."
                            : "The minimum break is still counting down."
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Text(state.canReturn ? "Break complete" : "Minimum remaining")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let timer = state.presentation.timer {
                    StableTimerText(
                        text: timer.text,
                        fontSize: 18,
                        weight: .bold,
                        width: 78,
                        alignment: .trailing
                    )
                }
            }

            HStack(spacing: 10) {
                Button("Return to focus", action: state.returnToFocus)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                    .disabled(!state.canReturn)
                    .keyboardShortcut(.return, modifiers: [])

                Button("Clock out", action: state.clockOut)
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Spacer(minLength: 0)
            }

            Text("BreakBar stays paused until you choose what happens next.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(width: 390, height: 250)
        .background(.ultraThinMaterial)
    }

    private var accent: Color {
        Color(red: 0.12, green: 0.64, blue: 0.48)
    }
}
