import XCTest
@testable import BreakBarCore

final class BreakBarEngineTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)
    private let policy = BreakPolicy(
        focusDuration: 60,
        warningDuration: 15,
        minimumBreakDuration: 20
    )

    func testFocusMovesThroughWarningAndRequired() {
        var engine = BreakBarEngine(policy: policy)

        XCTAssertEqual(engine.handle(.clockIn, at: origin), .changed)
        XCTAssertEqual(engine.state.enforcement, .none)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(45)), .changed)
        XCTAssertEqual(engine.state.enforcement, .warning)

        XCTAssertEqual(engine.handle(.tick, at: origin.addingTimeInterval(60)), .changed)
        XCTAssertEqual(engine.state.enforcement, .required)
    }

    func testBreakCannotEndBeforeMinimum() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin.addingTimeInterval(60))

        XCTAssertEqual(
            engine.handle(.returnToFocus, at: origin.addingTimeInterval(70)),
            .rejected(remaining: 10)
        )
        XCTAssertEqual(engine.state.phase, .onBreak)
    }

    func testValidReturnStartsFreshFocusCycle() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin.addingTimeInterval(60))
        let returnedAt = origin.addingTimeInterval(80)

        XCTAssertEqual(engine.handle(.returnToFocus, at: returnedAt), .changed)
        XCTAssertEqual(engine.state.phase, .focusing)
        XCTAssertEqual(engine.state.focusDueAt, returnedAt.addingTimeInterval(60))
    }

    func testClockOutClearsDeadlinesFromAnyActivePhase() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        _ = engine.handle(.startBreak, at: origin)

        XCTAssertEqual(engine.handle(.clockOut, at: origin), .changed)
        XCTAssertEqual(engine.state.phase, .clockedOut)
        XCTAssertNil(engine.state.focusDueAt)
        XCTAssertNil(engine.state.minimumBreakEndsAt)
    }

    func testRepeatedTickIsIdempotent() {
        var engine = BreakBarEngine(policy: policy)
        _ = engine.handle(.clockIn, at: origin)
        let warningTime = origin.addingTimeInterval(50)

        XCTAssertEqual(engine.handle(.tick, at: warningTime), .changed)
        let revision = engine.state.revision
        XCTAssertEqual(engine.handle(.tick, at: warningTime), .unchanged)
        XCTAssertEqual(engine.state.revision, revision)
    }
}
