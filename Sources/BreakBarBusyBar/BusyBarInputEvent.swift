import Foundation
import SwiftProtobuf

public enum BusyBarButton: Equatable, Sendable {
    case ok
    case back
    case start
}

public enum BusyBarButtonAction: Equatable, Sendable {
    case press
    case release
}

public enum BusyBarSelectorPosition: Equatable, Sendable {
    case busy
    case custom
    case off
    case apps
    case settings
}

public enum BusyBarInputEvent: Equatable, Sendable {
    case button(BusyBarButton, action: BusyBarButtonAction)
    case selector(BusyBarSelectorPosition)
    case encoder(delta: Int32)
}

public enum BusyBarStateDecoder {
    public static func decodeInputEvents(from data: Data) throws -> [BusyBarInputEvent] {
        let state = try BSBState_State(serializedBytes: data)
        return state.updates.compactMap { update in
            guard case .input(let input)? = update.state else {
                return nil
            }

            switch input.event {
            case .buttonEvent(let event):
                guard let button = button(from: event.button),
                      let action = action(from: event.action)
                else {
                    return nil
                }
                return .button(button, action: action)
            case .switchEvent(let event):
                guard let position = selectorPosition(from: event.position) else {
                    return nil
                }
                return .selector(position)
            case .encoderEvent(let event):
                return .encoder(delta: event.delta)
            case nil:
                return nil
            }
        }
    }

    private static func button(from value: BSBInput_Button) -> BusyBarButton? {
        switch value {
        case .ok:
            return .ok
        case .back:
            return .back
        case .start:
            return .start
        case .UNRECOGNIZED:
            return nil
        }
    }

    private static func action(from value: BSBInput_ButtonAction) -> BusyBarButtonAction? {
        switch value {
        case .press:
            return .press
        case .release:
            return .release
        case .UNRECOGNIZED:
            return nil
        }
    }

    private static func selectorPosition(
        from value: BSBInput_SwitchPosition
    ) -> BusyBarSelectorPosition? {
        switch value {
        case .busy:
            return .busy
        case .custom:
            return .custom
        case .off:
            return .off
        case .apps:
            return .apps
        case .settings:
            return .settings
        case .UNRECOGNIZED:
            return nil
        }
    }
}
