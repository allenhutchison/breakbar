import SwiftProtobuf
import XCTest
@testable import BreakBarBusyBar

final class BusyBarInputEventTests: XCTestCase {
    func testDecodesButtonEventsIncludingProtoDefaults() throws {
        var okPress = BSBInput_ButtonEvent()
        okPress.button = .ok
        okPress.action = .press

        var backRelease = BSBInput_ButtonEvent()
        backRelease.button = .back
        backRelease.action = .release

        let data = try serializedState(inputs: [
            input(button: okPress),
            input(button: backRelease),
        ])

        XCTAssertEqual(
            try BusyBarStateDecoder.decodeInputEvents(from: data),
            [
                .button(.ok, action: .press),
                .button(.back, action: .release),
            ]
        )
    }

    func testDecodesSelectorAndSignedEncoderEvents() throws {
        var selector = BSBInput_SwitchEvent()
        selector.position = .custom

        var clockwise = BSBInput_EncoderEvent()
        clockwise.delta = 1

        var counterclockwise = BSBInput_EncoderEvent()
        counterclockwise.delta = -1

        let data = try serializedState(inputs: [
            input(selector: selector),
            input(encoder: clockwise),
            input(encoder: counterclockwise),
        ])

        XCTAssertEqual(
            try BusyBarStateDecoder.decodeInputEvents(from: data),
            [
                .selector(.custom),
                .encoder(delta: 1),
                .encoder(delta: -1),
            ]
        )
    }

    func testIgnoresNonInputAndUnknownInputUpdates() throws {
        var deviceName = BSBState_DeviceName()
        deviceName.name = "BUSY Bar"

        var nonInputUpdate = BSBState_StateUpdate()
        nonInputUpdate.deviceName = deviceName

        var unknownButton = BSBInput_ButtonEvent()
        unknownButton.button = .UNRECOGNIZED(99)

        var state = BSBState_State()
        var inputUpdate = BSBState_StateUpdate()
        inputUpdate.input = input(button: unknownButton)
        state.updates = [nonInputUpdate, inputUpdate]

        XCTAssertEqual(
            try BusyBarStateDecoder.decodeInputEvents(from: state.serializedData()),
            []
        )
    }

    private func serializedState(inputs: [BSBInput_InputEvent]) throws -> Data {
        var state = BSBState_State()
        state.updates = inputs.map { input in
            var update = BSBState_StateUpdate()
            update.input = input
            return update
        }
        return try state.serializedData()
    }

    private func input(button: BSBInput_ButtonEvent) -> BSBInput_InputEvent {
        var input = BSBInput_InputEvent()
        input.buttonEvent = button
        return input
    }

    private func input(selector: BSBInput_SwitchEvent) -> BSBInput_InputEvent {
        var input = BSBInput_InputEvent()
        input.switchEvent = selector
        return input
    }

    private func input(encoder: BSBInput_EncoderEvent) -> BSBInput_InputEvent {
        var input = BSBInput_InputEvent()
        input.encoderEvent = encoder
        return input
    }
}
