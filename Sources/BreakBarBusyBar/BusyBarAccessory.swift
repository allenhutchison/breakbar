import BreakBarCore
import Foundation

public actor BusyBarAccessory: BreakBarCore.BreakBarAccessory {
    public nonisolated let identifier = "busy-bar"
    public nonisolated let capabilities: AccessoryCapabilities = [.display, .input, .presence]

    private static let displayTimeoutSeconds = 5
    private static let displayRefreshInterval = Duration.seconds(3)

    private nonisolated let eventStream: AsyncStream<AccessoryEvent>
    private let eventContinuation: AsyncStream<AccessoryEvent>.Continuation
    private let device: any BusyBarDeviceClient
    private let stateStream: any BusyBarStateStreaming

    private var inputTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var desiredDisplay: DisplayContent?
    private var lastRenderedDisplay: DisplayContent?
    private var desiredAction: DesiredAction?
    private var displayWriteInProgress = false
    private var isPresent = false

    public init(baseURL: URL, apiToken: String? = nil) throws {
        let pair = AsyncStream.makeStream(of: AccessoryEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
        device = try BusyBarHTTPClient(baseURL: baseURL, apiToken: apiToken)
        stateStream = try BusyBarStateStream(baseURL: baseURL, apiToken: apiToken)
    }

    init(
        device: any BusyBarDeviceClient,
        stateStream: any BusyBarStateStreaming
    ) {
        let pair = AsyncStream.makeStream(of: AccessoryEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
        self.device = device
        self.stateStream = stateStream
    }

    public func connect() async throws {
        guard inputTask == nil else { return }

        _ = try await device.verifyCompatibility()
        inputTask = Task { [weak self] in
            await self?.runInputLoop()
        }
        refreshTask = Task { [weak self] in
            await self?.runDisplayRefreshLoop()
        }
    }

    public func disconnect() async {
        inputTask?.cancel()
        refreshTask?.cancel()
        inputTask = nil
        refreshTask = nil
        desiredAction = nil
        desiredDisplay = nil
        lastRenderedDisplay = nil
        setPresence(false)
        try? await device.clearOwnedDisplay()
    }

    public func render(
        _ presentation: BreakBarPresentation,
        revision: UInt64
    ) async throws {
        desiredAction = DesiredAction(presentation: presentation, revision: revision)
        desiredDisplay = DisplayContent(presentation: presentation)
        try await flushDisplay(force: false)
    }

    public nonisolated func events() -> AsyncStream<AccessoryEvent> {
        eventStream
    }

    private func runInputLoop() async {
        var retryDelay = 1.0

        while !Task.isCancelled {
            do {
                for try await message in stateStream.messages() {
                    guard !Task.isCancelled else { return }
                    retryDelay = 1
                    setPresence(true)
                    for event in message.inputEvents {
                        handle(event)
                    }
                }
                setPresence(false)
            } catch {
                guard !Task.isCancelled else { return }
                setPresence(false)
            }

            do {
                try await Task.sleep(for: .seconds(retryDelay))
            } catch {
                return
            }
            retryDelay = min(30, retryDelay * 2)
        }
    }

    private func runDisplayRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.displayRefreshInterval)
                try await flushDisplay(force: true)
            } catch is CancellationError {
                return
            } catch {
                setPresence(false)
            }
        }
    }

    private func handle(_ event: BusyBarInputEvent) {
        guard case .button(.start, action: .press) = event,
              let desiredAction
        else {
            return
        }

        switch desiredAction {
        case .startBreak(let revision):
            eventContinuation.yield(
                .startBreak(id: UUID(), revision: revision)
            )
        case .returnToFocus(let revision):
            eventContinuation.yield(
                .returnToFocus(id: UUID(), revision: revision)
            )
        }
    }

    private func flushDisplay(force: Bool) async throws {
        guard !displayWriteInProgress else { return }
        displayWriteInProgress = true
        defer { displayWriteInProgress = false }

        var forceNextWrite = force
        while let desiredDisplay {
            if !forceNextWrite, desiredDisplay == lastRenderedDisplay {
                return
            }

            let displayToWrite = desiredDisplay
            do {
                try await device.drawFrontText(
                    displayToWrite.text,
                    color: displayToWrite.color,
                    timeoutSeconds: Self.displayTimeoutSeconds
                )
                lastRenderedDisplay = displayToWrite
                setPresence(true)
            } catch {
                setPresence(false)
                throw error
            }

            forceNextWrite = false
            if self.desiredDisplay == displayToWrite {
                return
            }
        }
    }

    private func setPresence(_ present: Bool) {
        guard present != isPresent else { return }
        isPresent = present
        eventContinuation.yield(
            .presenceChanged(isPresent: present, id: UUID())
        )
    }
}

private extension BusyBarAccessory {
    enum DesiredAction: Equatable {
        case startBreak(revision: UInt64)
        case returnToFocus(revision: UInt64)

        init?(presentation: BreakBarPresentation, revision: UInt64) {
            switch presentation.tone {
            case .focus, .warning, .required:
                self = .startBreak(revision: revision)
            case .breakTime where presentation.primaryActionTitle != nil:
                self = .returnToFocus(revision: revision)
            default:
                return nil
            }
        }
    }

    struct DisplayContent: Equatable {
        let text: String
        let color = "#FFFFFFFF"

        init(presentation: BreakBarPresentation) {
            let prefix: String
            switch presentation.tone {
            case .neutral:
                prefix = "FREE"
            case .focus:
                prefix = "BUSY"
            case .meeting:
                prefix = "MEET"
            case .warning, .required, .breakTime:
                prefix = "BREAK"
            case .lunch:
                prefix = "LUNCH"
            case .away:
                prefix = "AWAY"
            case .travel:
                prefix = presentation.statusLabel == "Leave " ? "LEAVE" : "AWAY"
            }

            if let timer = presentation.timer {
                text = "\(prefix) \(timer.text)"
            } else {
                text = prefix
            }
        }
    }
}
