import BreakBarCore
import Foundation
import XCTest
@testable import BreakBarBusyBar

final class BusyBarAccessoryTests: XCTestCase {
    func testConnectsAndRendersSelfClearingFocusStatus() async throws {
        let device = RecordingBusyBarDevice()
        let stateStream = ControlledBusyBarStateStream()
        let accessory = BusyBarAccessory(device: device, stateStream: stateStream)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let state = BreakBarState(
            phase: .focusing,
            phaseStartedAt: now,
            nominalFocusDueAt: now.addingTimeInterval(55 * 60),
            focusDueAt: now.addingTimeInterval(55 * 60),
            revision: 4
        )

        try await accessory.connect()
        try await accessory.render(
            BreakBarPresentation(state: state, policy: .standard, now: now),
            revision: state.revision
        )

        let compatibilityChecks = await device.compatibilityChecks()
        let recordedDraws = await device.recordedDraws()
        XCTAssertEqual(compatibilityChecks, 1)
        XCTAssertEqual(
            recordedDraws,
            [RecordedDraw(text: "BUSY 55:00", color: "#FFFFFFFF", timeoutSeconds: 5)]
        )

        await accessory.disconnect()
        let clearCount = await device.clearCount()
        XCTAssertEqual(clearCount, 1)
    }

    func testStartButtonMapsToActionsForTheLatestRenderedRevision() async throws {
        let device = RecordingBusyBarDevice()
        let stateStream = ControlledBusyBarStateStream()
        let accessory = BusyBarAccessory(device: device, stateStream: stateStream)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let firstEvent = Task { () -> AccessoryEvent? in
            for await event in accessory.events() {
                switch event {
                case .startBreak, .returnToFocus:
                    return event
                case .presenceChanged:
                    continue
                }
            }
            return nil
        }

        try await accessory.connect()
        let focusState = BreakBarState(
            phase: .focusing,
            phaseStartedAt: now,
            nominalFocusDueAt: now.addingTimeInterval(55 * 60),
            focusDueAt: now.addingTimeInterval(55 * 60),
            revision: 8
        )
        try await accessory.render(
            BreakBarPresentation(state: focusState, policy: .standard, now: now),
            revision: focusState.revision
        )
        stateStream.yield(
            BusyBarStateMessage(inputEvents: [
                .button(.ok, action: .press),
                .button(.start, action: .release),
                .button(.start, action: .press),
            ])
        )
        guard case .startBreak(_, revision: 8) = await firstEvent.value else {
            return XCTFail("Expected the focus action with revision 8")
        }

        let breakState = BreakBarState(
            phase: .onBreak,
            phaseStartedAt: now,
            minimumBreakEndsAt: now.addingTimeInterval(-1),
            revision: 9
        )
        try await accessory.render(
            BreakBarPresentation(state: breakState, policy: .standard, now: now),
            revision: breakState.revision
        )
        let secondEvent = Task { () -> AccessoryEvent? in
            for await event in accessory.events() {
                switch event {
                case .startBreak, .returnToFocus:
                    return event
                case .presenceChanged:
                    continue
                }
            }
            return nil
        }
        stateStream.yield(
            BusyBarStateMessage(inputEvents: [
                .selector(.busy),
                .encoder(delta: 1),
                .button(.start, action: .press),
            ])
        )

        guard case .returnToFocus(_, revision: 9) = await secondEvent.value else {
            return XCTFail("Expected the break action with revision 9")
        }

        await accessory.disconnect()
    }
}

private struct RecordedDraw: Equatable, Sendable {
    let text: String
    let color: String
    let timeoutSeconds: Int
}

private actor RecordingBusyBarDevice: BusyBarDeviceClient {
    private var checks = 0
    private var draws: [RecordedDraw] = []
    private var clears = 0

    func verifyCompatibility() async throws -> BusyBarAPICompatibility {
        checks += 1
        return try BusyBarAPICompatibility(deviceVersion: "27.5.0")
    }

    func drawFrontText(
        _ text: String,
        color: String,
        timeoutSeconds: Int
    ) async throws {
        draws.append(
            RecordedDraw(text: text, color: color, timeoutSeconds: timeoutSeconds)
        )
    }

    func clearOwnedDisplay() async throws {
        clears += 1
    }

    func compatibilityChecks() -> Int { checks }
    func recordedDraws() -> [RecordedDraw] { draws }
    func clearCount() -> Int { clears }
}

private final class ControlledBusyBarStateStream: BusyBarStateStreaming,
    @unchecked Sendable
{
    private let stream: AsyncThrowingStream<BusyBarStateMessage, Error>
    private let continuation: AsyncThrowingStream<BusyBarStateMessage, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(
            of: BusyBarStateMessage.self
        )
    }

    func messages() -> AsyncThrowingStream<BusyBarStateMessage, Error> {
        stream
    }

    func yield(_ message: BusyBarStateMessage) {
        continuation.yield(message)
    }
}
