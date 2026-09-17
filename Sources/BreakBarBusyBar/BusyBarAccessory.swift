import BreakBarCore
import Foundation

public struct BusyBarAccessoryDiagnostics: Equatable, Sendable {
    public let deviceAPIVersion: String?
    public let lastSuccessfulWriteAt: Date?
    public let lastInputAt: Date?

    public init(
        deviceAPIVersion: String?,
        lastSuccessfulWriteAt: Date?,
        lastInputAt: Date?
    ) {
        self.deviceAPIVersion = deviceAPIVersion
        self.lastSuccessfulWriteAt = lastSuccessfulWriteAt
        self.lastInputAt = lastInputAt
    }
}

public actor BusyBarAccessory: BreakBarCore.BreakBarAccessory {
    public nonisolated let identifier = "busy-bar"
    public nonisolated let capabilities: AccessoryCapabilities = [.display, .input, .presence]

    private static let displayTimeoutSeconds = 5
    private static let displayRefreshInterval = Duration.seconds(3)

    private nonisolated let eventStream: AsyncStream<AccessoryEvent>
    private let eventContinuation: AsyncStream<AccessoryEvent>.Continuation
    private let device: any BusyBarDeviceClient
    private let stateStream: any BusyBarStateStreaming
    private let now: @Sendable () -> Date

    private var inputTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var desiredDisplay: DisplayContent?
    private var lastRenderedDisplay: DisplayContent?
    private var desiredAction: DesiredAction?
    private var displayWriteInProgress = false
    private var displayWriteTask: (id: UUID, task: Task<Void, Error>)?
    private var displayFlushWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycleGeneration = UUID()
    private var isConnected = false
    private var isDisconnecting = false
    private var isPresent = false
    private var deviceAPIVersion: String?
    private var lastSuccessfulWriteAt: Date?
    private var lastInputAt: Date?

    public init(baseURL: URL, apiToken: String? = nil) throws {
        let pair = AsyncStream.makeStream(of: AccessoryEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
        device = try BusyBarHTTPClient(baseURL: baseURL, apiToken: apiToken)
        stateStream = try BusyBarStateStream(baseURL: baseURL, apiToken: apiToken)
        now = { Date() }
    }

    init(
        device: any BusyBarDeviceClient,
        stateStream: any BusyBarStateStreaming,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let pair = AsyncStream.makeStream(of: AccessoryEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
        self.device = device
        self.stateStream = stateStream
        self.now = now
    }

    public func connect() async throws {
        guard inputTask == nil, !isConnected else { return }
        guard !isDisconnecting else { throw CancellationError() }

        let generation = lifecycleGeneration
        let compatibility = try await device.verifyCompatibility()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration, !isDisconnecting else {
            throw CancellationError()
        }
        deviceAPIVersion = compatibility.deviceVersion
        isConnected = true
        inputTask = Task { [weak self] in
            await self?.runInputLoop()
        }
        refreshTask = Task { [weak self] in
            await self?.runDisplayRefreshLoop()
        }
    }

    public func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        lifecycleGeneration = UUID()
        isConnected = false
        inputTask?.cancel()
        refreshTask?.cancel()
        inputTask = nil
        refreshTask = nil
        desiredAction = nil
        desiredDisplay = nil
        lastRenderedDisplay = nil
        setPresence(false)

        let activeWrite = displayWriteTask
        activeWrite?.task.cancel()
        if let activeWrite {
            _ = await activeWrite.task.result
        }
        await waitForDisplayFlush()
        try? await device.clearOwnedDisplay()
        isDisconnecting = false
    }

    public func render(
        _ presentation: BreakBarPresentation,
        revision: UInt64
    ) async throws {
        guard isConnected, !isDisconnecting else { throw CancellationError() }
        desiredAction = DesiredAction(presentation: presentation, revision: revision)
        desiredDisplay = DisplayContent(presentation: presentation)
        try await flushDisplay(force: false, generation: lifecycleGeneration)
    }

    public nonisolated func events() -> AsyncStream<AccessoryEvent> {
        eventStream
    }

    public func diagnostics() -> BusyBarAccessoryDiagnostics {
        BusyBarAccessoryDiagnostics(
            deviceAPIVersion: deviceAPIVersion,
            lastSuccessfulWriteAt: lastSuccessfulWriteAt,
            lastInputAt: lastInputAt
        )
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
                try await flushDisplay(force: true, generation: lifecycleGeneration)
            } catch is CancellationError {
                return
            } catch {
                setPresence(false)
            }
        }
    }

    private func handle(_ event: BusyBarInputEvent) {
        lastInputAt = now()
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

    private func flushDisplay(force: Bool, generation: UUID) async throws {
        guard !displayWriteInProgress else { return }
        displayWriteInProgress = true
        defer {
            displayWriteInProgress = false
            let waiters = displayFlushWaiters
            displayFlushWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        var forceNextWrite = force
        while generation == lifecycleGeneration,
              isConnected,
              !isDisconnecting,
              let desiredDisplay
        {
            if !forceNextWrite, desiredDisplay == lastRenderedDisplay {
                return
            }

            let displayToWrite = desiredDisplay
            let writeID = UUID()
            let writeTask = Task {
                try await device.drawFrontText(
                    displayToWrite.text,
                    color: displayToWrite.color,
                    timeoutSeconds: Self.displayTimeoutSeconds
                )
            }
            displayWriteTask = (writeID, writeTask)
            do {
                try await withTaskCancellationHandler {
                    try await writeTask.value
                } onCancel: {
                    writeTask.cancel()
                }
                if displayWriteTask?.id == writeID {
                    displayWriteTask = nil
                }
                guard generation == lifecycleGeneration,
                      isConnected,
                      !isDisconnecting
                else {
                    throw CancellationError()
                }
                lastRenderedDisplay = displayToWrite
                lastSuccessfulWriteAt = now()
                setPresence(true)
            } catch {
                if displayWriteTask?.id == writeID {
                    displayWriteTask = nil
                }
                guard generation == lifecycleGeneration,
                      isConnected,
                      !isDisconnecting
                else {
                    throw CancellationError()
                }
                setPresence(false)
                throw error
            }

            forceNextWrite = false
            if self.desiredDisplay == displayToWrite {
                return
            }
        }
    }

    private func waitForDisplayFlush() async {
        guard displayWriteInProgress else { return }
        await withCheckedContinuation { continuation in
            displayFlushWaiters.append(continuation)
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
