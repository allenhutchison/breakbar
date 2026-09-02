import AppKit
import BreakBarCore
import SwiftUI

@MainActor
final class AwayReturnPanelController {
    private var panel: NSPanel?
    private var panelState: AwayReturnPanelState?

    func show(
        presentation: BreakBarPresentation,
        classify: @escaping (AwayClassification) -> Void,
        clockOut: @escaping () -> Void
    ) {
        if let panelState {
            panelState.update(presentation: presentation)
            return
        }

        let panelState = AwayReturnPanelState(
            presentation: presentation,
            classify: classify,
            clockOut: clockOut
        )
        let panelSize = NSSize(width: 410, height: 420)
        let panel = AwayReturnPanel(
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
            rootView: AwayReturnPanelView(state: panelState)
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

private final class AwayReturnPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Keep the classification prompt available until the away time is resolved.
    }
}

@MainActor
private final class AwayReturnPanelState: ObservableObject {
    @Published private(set) var presentation: BreakBarPresentation

    let classify: (AwayClassification) -> Void
    let clockOut: () -> Void

    init(
        presentation: BreakBarPresentation,
        classify: @escaping (AwayClassification) -> Void,
        clockOut: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.classify = classify
        self.clockOut = clockOut
    }

    func update(presentation: BreakBarPresentation) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
    }
}

private struct AwayReturnPanelView: View {
    @ObservedObject var state: AwayReturnPanelState

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "figure.walk.arrival")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(awayAccent)
                    .frame(width: 46, height: 46)
                    .background(awayAccent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome back")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("How should BreakBar classify your time away?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Text("Time away")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let timer = state.presentation.timer {
                    StableTimerText(
                        text: timer.text,
                        fontSize: 18,
                        weight: .bold,
                        width: 88,
                        alignment: .trailing
                    )
                }
            }

            classificationButton("Lunch", color: lunchAccent) {
                state.classify(.lunch)
            }
            classificationButton("Break", color: breakAccent) {
                state.classify(.breakTime)
            }
            classificationButton("Other away", color: awayAccent) {
                state.classify(.otherAway)
            }
            classificationButton("Count as work", color: workAccent) {
                state.classify(.countAsWork)
            }

            Button("Clock out", action: state.clockOut)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 410, height: 420)
        .background(.ultraThinMaterial)
    }

    private func classificationButton(
        _ title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.large)
    }

    private var lunchAccent: Color { Color(red: 0.90, green: 0.45, blue: 0.16) }
    private var breakAccent: Color { Color(red: 0.12, green: 0.64, blue: 0.48) }
    private var awayAccent: Color { Color(red: 0.42, green: 0.44, blue: 0.50) }
    private var workAccent: Color { Color(red: 0.16, green: 0.47, blue: 0.88) }
}
