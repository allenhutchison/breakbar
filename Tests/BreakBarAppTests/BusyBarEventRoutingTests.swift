import BreakBarCore
import Foundation
import XCTest
@testable import BreakBarApp

final class BusyBarEventRoutingTests: XCTestCase {
    func testNormalizesSafeExplicitDeviceAddresses() {
        XCTAssertEqual(
            BusyBarAddress.normalized(" HTTP://10.0.4.20/ \n"),
            "http://10.0.4.20"
        )
        XCTAssertEqual(
            BusyBarAddress.normalized("https://busybar.local:8443"),
            "https://busybar.local:8443"
        )
    }

    func testRejectsAddressesWithCredentialsOrEndpointPaths() {
        XCTAssertNil(BusyBarAddress.normalized("ftp://10.0.4.20"))
        XCTAssertNil(BusyBarAddress.normalized("http://user:secret@10.0.4.20"))
        XCTAssertNil(BusyBarAddress.normalized("http://10.0.4.20/api/version"))
        XCTAssertNil(BusyBarAddress.normalized("http://10.0.4.20?token=secret"))
    }

    func testRoutesCurrentFocusAndBreakActions() {
        let focus = BreakBarState(phase: .focusing, revision: 4)
        let onBreak = BreakBarState(phase: .onBreak, revision: 5)

        XCTAssertEqual(
            BusyBarEventRouting.command(
                for: .startBreak(id: UUID(), revision: 4),
                state: focus
            ),
            .startBreak
        )
        XCTAssertEqual(
            BusyBarEventRouting.command(
                for: .returnToFocus(id: UUID(), revision: 5),
                state: onBreak
            ),
            .returnToFocus
        )
    }

    func testRejectsStaleOrPhaseIncompatibleActions() {
        let focus = BreakBarState(phase: .focusing, revision: 7)

        XCTAssertNil(
            BusyBarEventRouting.command(
                for: .startBreak(id: UUID(), revision: 6),
                state: focus
            )
        )
        XCTAssertNil(
            BusyBarEventRouting.command(
                for: .returnToFocus(id: UUID(), revision: 7),
                state: focus
            )
        )
        XCTAssertNil(
            BusyBarEventRouting.command(
                for: .presenceChanged(isPresent: true, id: UUID()),
                state: focus
            )
        )
    }
}
