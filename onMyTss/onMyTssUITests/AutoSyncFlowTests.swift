import XCTest

final class AutoSyncFlowTests: XCTestCase {
    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testForegroundLaunchImportsTrainingAndExplainsMissingRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-sync-fixture", "--v2-auto-sync-fixture"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        // The isolated store starts empty; the synthetic workout is imported by
        // the real engine without tapping Sync or pulling to refresh.
        XCTAssertTrue(app.staticTexts["Training load is available. Sleep or a personal heart baseline is needed for readiness."]
            .waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["readiness.empty"].exists)
        XCTAssertFalse(app.staticTexts["readiness.score"].exists)

        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let importedWorkout = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.workout.")).firstMatch
        // SwiftUI lists materialize offscreen rows as they are scrolled into view.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<16 {
            if importedWorkout.isHittable { break }
            lower.press(forDuration: 0.05, thenDragTo: upper)
        }
        XCTAssertTrue(importedWorkout.waitForExistence(timeout: 10))
        XCTAssertTrue(importedWorkout.isHittable)
    }
}
