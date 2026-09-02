import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private enum Mode { case breakRequired, travelRequired }

    private var panel: NSPanel?
    private var emergencyEscapeState: EmergencyEscapeState?
    private var mode: Mode?

    func show(
        startBreak: @escaping () -> Void,
        clockOut: @escaping () -> Void,
        emergencyStartBreak: @escaping () -> Void,
        emergencyClockOut: @escaping () -> Void
    ) {
        if panel != nil, mode != .breakRequired { hide() }
        guard panel == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let escapeState = EmergencyEscapeState()
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
        panel.onEmergencyHoldBegan = { [weak escapeState] in
            escapeState?.beginHold()
        }
        panel.onEmergencyHoldEnded = { [weak escapeState] in
            escapeState?.endHold()
        }
        panel.contentViewController = NSHostingController(
            rootView: BreakRequiredView(
                escapeState: escapeState,
                startBreak: startBreak,
                clockOut: clockOut,
                emergencyStartBreak: emergencyStartBreak,
                emergencyClockOut: emergencyClockOut
            )
        )
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        emergencyEscapeState = escapeState
        mode = .breakRequired
        self.panel = panel
    }

    func showTravel(
        acknowledge: @escaping () -> Void,
        clockOut: @escaping () -> Void
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
                clockOut: clockOut
            )
        )
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mode = .travelRequired
        self.panel = panel
    }

    func hide() {
        emergencyEscapeState?.cancel()
        emergencyEscapeState = nil
        panel?.orderOut(nil)
        panel = nil
        mode = nil
    }
}

private struct TravelRequiredView: View {
    @State private var isConfirmingClockOut = false
    let acknowledge: () -> Void
    let clockOut: () -> Void

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

                Button("Clock out instead") {
                    isConfirmingClockOut = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .padding(48)

            if isConfirmingClockOut {
                Color.black.opacity(0.72).ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("Clock out?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("This ends the current work session.")
                        .foregroundStyle(.secondary)
                    Button("Clock out", role: .destructive) {
                        isConfirmingClockOut = false
                        clockOut()
                    }
                    .controlSize(.large)
                    Button("Keep working") { isConfirmingClockOut = false }
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
    var onEmergencyHoldBegan: (() -> Void)?
    var onEmergencyHoldEnded: (() -> Void)?

    private var isHoldingEmergencyShortcut = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isEmergencyShortcut(event) else {
            super.keyDown(with: event)
            return
        }
        beginEmergencyHoldIfNeeded()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 {
            endEmergencyHoldIfNeeded()
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if isHoldingEmergencyShortcut && !hasEmergencyModifiers(event) {
            endEmergencyHoldIfNeeded()
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isEmergencyShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        beginEmergencyHoldIfNeeded()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape is intentionally ignored. The visible controls remain available.
    }

    private func isEmergencyShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && hasEmergencyModifiers(event)
    }

    private func hasEmergencyModifiers(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains([.command, .option])
    }

    private func beginEmergencyHoldIfNeeded() {
        guard !isHoldingEmergencyShortcut else { return }
        isHoldingEmergencyShortcut = true
        onEmergencyHoldBegan?()
    }

    private func endEmergencyHoldIfNeeded() {
        guard isHoldingEmergencyShortcut else { return }
        isHoldingEmergencyShortcut = false
        onEmergencyHoldEnded?()
    }
}

@MainActor
private final class EmergencyEscapeState: ObservableObject {
    @Published private(set) var holdProgress = 0.0
    @Published private(set) var isConfirming = false

    private var holdTask: Task<Void, Never>?

    func beginHold() {
        guard holdTask == nil, !isConfirming else { return }
        let clock = ContinuousClock()
        let startedAt = clock.now
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                let elapsed = startedAt.duration(to: clock.now).components
                let elapsedSeconds = Double(elapsed.seconds)
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                holdProgress = min(1, elapsedSeconds / 3)
                if holdProgress >= 1 {
                    holdTask = nil
                    holdProgress = 0
                    isConfirming = true
                    return
                }
            }
        }
    }

    func endHold() {
        holdTask?.cancel()
        holdTask = nil
        if !isConfirming {
            holdProgress = 0
        }
    }

    func dismissConfirmation() {
        isConfirming = false
    }

    func cancel() {
        endHold()
        isConfirming = false
    }
}

private struct BreakRequiredView: View {
    @ObservedObject var escapeState: EmergencyEscapeState
    @State private var isConfirmingClockOut = false
    let startBreak: () -> Void
    let clockOut: () -> Void
    let emergencyStartBreak: () -> Void
    let emergencyClockOut: () -> Void

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

                    Button("Clock out instead") {
                        isConfirmingClockOut = true
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.65))
                }

                VStack(spacing: 8) {
                    Text(
                        escapeState.holdProgress > 0
                            ? "Keep holding ⌘⌥Esc…"
                            : "Emergency options: hold ⌘⌥Esc for 3 seconds"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))

                    if escapeState.holdProgress > 0 {
                        ProgressView(value: escapeState.holdProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 240)
                    }

                    Text("Your work stays open. BreakBar never closes or changes another app.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                }
            }
            .foregroundStyle(.white)
            .padding(48)

            if escapeState.isConfirming {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.yellow)
                    Text("Emergency escape")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Choose how BreakBar should record this interruption.")
                        .foregroundStyle(.secondary)

                    Button("Start break now") {
                        escapeState.dismissConfirmation()
                        emergencyStartBreak()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Clock out and dismiss", role: .destructive) {
                        escapeState.dismissConfirmation()
                        emergencyClockOut()
                    }
                    .controlSize(.large)

                    Button("Cancel") {
                        escapeState.dismissConfirmation()
                    }
                    .buttonStyle(.plain)
                }
                .padding(32)
                .frame(width: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.primary)
            } else if isConfirmingClockOut {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Text("Clock out?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("This ends the current work session and dismisses break enforcement.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button("Clock out", role: .destructive) {
                        isConfirmingClockOut = false
                        clockOut()
                    }
                    .controlSize(.large)

                    Button("Keep working") {
                        isConfirmingClockOut = false
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
