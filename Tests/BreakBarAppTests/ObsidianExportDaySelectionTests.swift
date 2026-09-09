import Foundation
@testable import BreakBarApp
import XCTest

final class ObsidianExportDaySelectionTests: XCTestCase {
    func testBoundaryDatesAreDeduplicatedAndSortedByLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let days = ObsidianExportDaySelection.days(
            containing: [
                date("2026-09-09T00:10:00Z"),
                date("2026-09-08T23:55:00Z"),
                date("2026-09-08T08:00:00Z"),
                date("2026-09-09T19:00:00Z"),
            ],
            calendar: calendar
        )

        XCTAssertEqual(
            days,
            [date("2026-09-08T00:00:00Z"), date("2026-09-09T00:00:00Z")]
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
