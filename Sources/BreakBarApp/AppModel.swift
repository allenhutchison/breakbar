import AppKit
import BreakBarCore
import BreakBarPersistence
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: BreakBarState
    @Published private(set) var now: Date
    @Published private(set) var lastMessage: String?

    let policy: BreakPolicy
    let isDemoMode: Bool

    private var engine: BreakBarEngine
    private let repository: SessionRepository?
    private let overlayController = OverlayController()
    private var ticker: Task<Void, Never>?

    init() {
        isDemoMode = CommandLine.arguments.contains("--demo")
        policy = isDemoMode
            ? BreakPolicy(focusDuration: 60, warningDuration: 15, minimumBreakDuration: 20)
            : .standard

        var restored = BreakBarState()
        var loadedRepository: SessionRepository?
        var startupMessage: String?
        do {
            let databaseURL = try Self.databaseURL(isDemoMode: isDemoMode)
            let repository = try SessionRepository(url: databaseURL)
            try repository.bootstrapIfNeeded(
                state: isDemoMode
                    ? BreakBarState()
                    : LegacyStatePersistence.load() ?? BreakBarState()
            )
            restored = try repository.loadState() ?? BreakBarState()
            loadedRepository = repository
        } catch {
            startupMessage = "BreakBar could not open its history database: \(error.localizedDescription)"
        }

        repository = loadedRepository
        engine = BreakBarEngine(state: restored, policy: policy)
        state = engine.state
        now = Date()
        lastMessage = startupMessage

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }

        Task { [weak self] in
            self?.tick()
        }
    }

    deinit {
        ticker?.cancel()
    }

    var presentation: BreakBarPresentation {
        BreakBarPresentation(state: state, policy: policy, now: now)
    }

    var menuBarSymbol: String {
        switch presentation.tone {
        case .neutral: "figure.stand"
        case .focus: "timer"
        case .warning: "exclamationmark.circle.fill"
        case .required: "figure.walk.motion"
        case .breakTime: "cup.and.heat.waves.fill"
        }
    }

    var canReturnEarly: Bool {
        guard state.phase == .onBreak else { return false }
        return (state.minimumBreakEndsAt ?? now) <= now
    }

    func performPrimaryAction() {
        switch state.phase {
        case .clockedOut:
            clockIn()
        case .focusing:
            startBreak()
        case .onBreak:
            returnToFocus()
        }
    }

    func clockIn() {
        apply(.clockIn)
    }

    func clockOut() {
        apply(.clockOut)
    }

    func startBreak() {
        let result = apply(.startBreak)
        if result == .changed {
            SystemActions.startScreensaver()
        }
    }

    func returnToFocus() {
        let result = apply(.returnToFocus)
        if case let .rejected(remaining) = result {
            lastMessage = "Stay away for another \(BreakBarPresentation.clock(remaining))."
        }
    }

    func clearMessage() {
        lastMessage = nil
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func tick() {
        now = Date()
        _ = apply(.tick, at: now)
    }

    @discardableResult
    private func apply(_ command: BreakCommand, at date: Date? = nil) -> BreakCommandResult {
        let eventDate = date ?? Date()
        let previousState = engine.state
        var candidate = engine
        let result = candidate.handle(command, at: eventDate)
        now = eventDate

        if result == .changed {
            guard let repository else {
                lastMessage = "The history database is unavailable, so the timer did not change."
                synchronizeOverlay()
                return .unchanged
            }
            do {
                try repository.commitTransition(
                    from: previousState,
                    to: candidate.state,
                    at: eventDate
                )
            } catch {
                lastMessage = "The timer did not change because it could not be saved: \(error.localizedDescription)"
                synchronizeOverlay()
                return .unchanged
            }
            engine = candidate
            state = candidate.state
            lastMessage = nil
        } else {
            state = engine.state
        }
        if previousState.enforcement != .warning && state.enforcement == .warning {
            WarningNotifier.deliver(
                remaining: max(0, (state.focusDueAt ?? eventDate).timeIntervalSince(eventDate)),
                revision: state.revision
            )
        }
        synchronizeOverlay()
        return result
    }

    private static func databaseURL(isDemoMode: Bool) throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return base.appendingPathComponent("BreakBar", isDirectory: true)
            .appendingPathComponent(isDemoMode ? "breakbar-demo.sqlite" : "breakbar.sqlite")
    }

    private func synchronizeOverlay() {
        if state.phase == .focusing && state.enforcement == .required {
            overlayController.show(
                startBreak: { [weak self] in self?.startBreak() },
                clockOut: { [weak self] in self?.clockOut() }
            )
        } else {
            overlayController.hide()
        }
    }
}
