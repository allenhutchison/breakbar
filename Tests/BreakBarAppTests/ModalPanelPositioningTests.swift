import AppKit
@testable import BreakBarApp
import XCTest

final class ModalPanelPositioningTests: XCTestCase {
    func testCenteredOriginUsesVisibleFrameIncludingItsOffset() {
        let visibleFrame = NSRect(x: -1728, y: 25, width: 1728, height: 1055)
        let panelSize = NSSize(width: 410, height: 420)

        let origin = ModalPanelPositioning.centeredOrigin(
            size: panelSize,
            in: visibleFrame
        )

        XCTAssertEqual(origin.x, -1069)
        XCTAssertEqual(origin.y, 342.5)
    }

    func testTargetScreenPrefersTheScreenContainingTheKeyWindow() {
        let index = ModalPanelPositioning.targetScreenIndex(
            preferredScreenIndex: 1,
            pointerLocation: NSPoint(x: 100, y: 100),
            screenFrames: screenFrames
        )

        XCTAssertEqual(index, 1)
    }

    func testTargetScreenUsesThePointerWhenThereIsNoKeyWindow() {
        let index = ModalPanelPositioning.targetScreenIndex(
            preferredScreenIndex: nil,
            pointerLocation: NSPoint(x: -900, y: 500),
            screenFrames: screenFrames
        )

        XCTAssertEqual(index, 1)
    }

    func testTargetScreenFallsBackToThePrimaryScreen() {
        let index = ModalPanelPositioning.targetScreenIndex(
            preferredScreenIndex: nil,
            pointerLocation: NSPoint(x: 5000, y: 5000),
            screenFrames: screenFrames
        )

        XCTAssertEqual(index, 0)
    }

    func testTargetScreenIsAbsentWhenThereAreNoScreens() {
        let index = ModalPanelPositioning.targetScreenIndex(
            preferredScreenIndex: nil,
            pointerLocation: .zero,
            screenFrames: []
        )

        XCTAssertNil(index)
    }

    private var screenFrames: [NSRect] {
        [
            NSRect(x: 0, y: 0, width: 1920, height: 1080),
            NSRect(x: -1728, y: 0, width: 1728, height: 1080),
        ]
    }
}
