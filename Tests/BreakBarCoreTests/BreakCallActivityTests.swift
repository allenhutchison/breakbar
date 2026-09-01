import XCTest
@testable import BreakBarCore

final class BreakCallActivityTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 3_000_000)
    private let zoom = BreakCallSignal(
        bundleIdentifier: "us.zoom.xos",
        confidence: .dedicatedApplication
    )

    func testClassifiesDedicatedCallAppHelpersAtHighConfidence() {
        XCTAssertEqual(
            BreakCallApplicationClassifier.signal(for: "us.zoom.xos.helper"),
            zoom
        )
    }

    func testClassifiesBrowserHelpersAtCalendarCorrelatedConfidence() {
        XCTAssertEqual(
            BreakCallApplicationClassifier.signal(for: "com.google.Chrome.helper"),
            BreakCallSignal(
                bundleIdentifier: "com.google.Chrome",
                confidence: .calendarCorrelatedBrowser
            )
        )
    }

    func testDoesNotTreatUnrecognizedMicrophoneUseAsCall() {
        XCTAssertNil(
            BreakCallApplicationClassifier.signal(for: "com.apple.VoiceMemos")
        )
    }

    func testDedicatedAppDoesNotRequireCalendarCorrelation() {
        XCTAssertEqual(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: zoom,
                currentAcceptedSignal: nil,
                constraints: [],
                at: origin
            ),
            zoom
        )
    }

    func testBrowserRequiresNearbyCalendarMeeting() {
        let browser = BreakCallSignal(
            bundleIdentifier: "com.google.Chrome",
            confidence: .calendarCorrelatedBrowser
        )
        let distantMeeting = BreakCalendarConstraint(
            id: "later",
            startAt: date(600),
            endAt: date(900)
        )

        XCTAssertNil(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: browser,
                currentAcceptedSignal: nil,
                constraints: [distantMeeting],
                at: origin
            )
        )
        XCTAssertEqual(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: browser,
                currentAcceptedSignal: nil,
                constraints: [distantMeeting],
                at: date(300)
            ),
            browser
        )
    }

    func testAcceptedBrowserRemainsAssociatedThroughMeetingOverrun() {
        let browser = BreakCallSignal(
            bundleIdentifier: "com.google.Chrome",
            confidence: .calendarCorrelatedBrowser
        )

        XCTAssertEqual(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: browser,
                currentAcceptedSignal: browser,
                constraints: [],
                at: date(3_600)
            ),
            browser
        )
        XCTAssertNil(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: nil,
                currentAcceptedSignal: browser,
                constraints: [],
                at: date(3_601)
            )
        )
    }

    func testUserApprovedBrowserRuleAcceptsAdHocCall() {
        let browser = BreakCallSignal(
            bundleIdentifier: "com.google.Chrome",
            confidence: .calendarCorrelatedBrowser
        )

        XCTAssertEqual(
            BreakCallCorrelation.acceptedSignal(
                rawSignal: browser,
                currentAcceptedSignal: nil,
                constraints: [],
                at: origin,
                allowUncorrelatedBrowser: true
            ),
            BreakCallSignal(
                bundleIdentifier: "com.google.Chrome",
                confidence: .userApprovedBrowser
            )
        )
    }

    func testStartRequiresContinuousSignal() {
        var debouncer = BreakCallActivityDebouncer(startDelay: 2, stopDelay: 5)

        XCTAssertNil(debouncer.update(rawSignal: zoom, at: origin))
        XCTAssertNil(debouncer.update(rawSignal: zoom, at: date(1)))
        XCTAssertEqual(debouncer.update(rawSignal: zoom, at: date(2)), zoom)
    }

    func testBriefMicrophoneFlapDoesNotStartCall() {
        var debouncer = BreakCallActivityDebouncer(startDelay: 2, stopDelay: 5)

        XCTAssertNil(debouncer.update(rawSignal: zoom, at: origin))
        XCTAssertNil(debouncer.update(rawSignal: nil, at: date(1)))
        XCTAssertNil(debouncer.stableSignal)
    }

    func testStopRequiresLongerDebounce() {
        var debouncer = BreakCallActivityDebouncer(
            stableSignal: zoom,
            startDelay: 2,
            stopDelay: 5
        )

        XCTAssertEqual(debouncer.update(rawSignal: nil, at: origin), zoom)
        XCTAssertEqual(debouncer.update(rawSignal: nil, at: date(4)), zoom)
        XCTAssertNil(debouncer.update(rawSignal: nil, at: date(5)))
        XCTAssertNil(debouncer.stableSignal)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
