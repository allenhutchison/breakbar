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
}
