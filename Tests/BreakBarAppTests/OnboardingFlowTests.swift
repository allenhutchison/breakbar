import Foundation
import XCTest
@testable import BreakBarApp

final class OnboardingFlowTests: XCTestCase {
    func testProgressMovesThroughStepsWithoutLeavingBounds() {
        var progress = OnboardingProgress()

        XCTAssertEqual(progress.step, .welcome)
        XCTAssertEqual(progress.position, 1)
        XCTAssertFalse(progress.canMoveBack)
        XCTAssertFalse(progress.isFinalStep)

        progress.moveBack()
        XCTAssertEqual(progress.step, .welcome)

        for expectedStep in OnboardingStep.allCases.dropFirst() {
            progress.moveForward()
            XCTAssertEqual(progress.step, expectedStep)
        }

        XCTAssertTrue(progress.isFinalStep)
        progress.moveForward()
        XCTAssertEqual(progress.step, .ready)

        progress.moveBack()
        XCTAssertEqual(progress.step, .options)
        XCTAssertTrue(progress.canMoveBack)
    }

    func testCompletionPreferenceIsVersioned() throws {
        let suiteName = "OnboardingFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(OnboardingPreferences.shouldPresent(defaults: defaults))

        defaults.set(
            OnboardingPreferences.currentVersion - 1,
            forKey: OnboardingPreferences.completedVersionKey
        )
        XCTAssertTrue(OnboardingPreferences.shouldPresent(defaults: defaults))

        OnboardingPreferences.markCompleted(defaults: defaults)

        XCTAssertFalse(OnboardingPreferences.shouldPresent(defaults: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: OnboardingPreferences.completedVersionKey),
            OnboardingPreferences.currentVersion
        )
    }
}
