import Foundation
import XCTest

/// Runs only on a newly created hosted simulator whose default store was seeded
/// externally with synthetic data. The app is the unmodified Release build.
@MainActor
final class ReleaseSavedHistoryGateTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testReleaseUpgradeInterruptAndResume() throws {
        let app = XCUIApplication()
        XCTAssertTrue(app.launchArguments.isEmpty, "Release test must not enable debug fixtures")
        let clock = ContinuousClock()
        let start = clock.now
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 60), "Seeded app must cold launch to Today")
        record("cold_launch_today", elapsed: start.duration(to: clock.now))
        XCTAssertEqual(app.state, .runningForeground)

        let settings = app.buttons["Settings"].firstMatch
        let today = app.buttons["Today"].firstMatch
        let history = app.buttons["History"].firstMatch
        let navStart = clock.now
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        record("navigate_settings", elapsed: navStart.duration(to: clock.now))

        let hr = app.textFields["settings.cardioHR"]
        let save = app.buttons["settings.saveCardio"]
        XCTAssertTrue(hr.waitForExistence(timeout: 20))
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        // The synthetic old-version store starts with no heart-rate value.
        let initial = (hr.value as? String) ?? ""
        XCTAssertFalse(initial.contains("170") || initial.contains("180"), "Unexpected fixture initial HR")
        hr.tap()
        hr.typeText("170")
        let firstSave = clock.now
        save.tap()
        let updating = app.staticTexts["Updating estimates. You can continue using the app."]
        XCTAssertTrue(updating.waitForExistence(timeout: 5), "Must observe first recalculation in progress")
        XCTAssertFalse(hr.isEnabled, "Field should be locked during recalculation")
        today.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15))
        record("navigation_while_recalculating", elapsed: firstSave.duration(to: clock.now))
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let saved = app.staticTexts["Saved. Estimates updated; previous versions retained."]
        XCTAssertTrue(saved.waitForExistence(timeout: 180), "First refresh must complete")
        record("first_refresh_complete", elapsed: firstSave.duration(to: clock.now))
        XCTAssertEqual(hr.value as? String, "170")

        XCTAssertTrue(hr.isEnabled)
        hr.tap()
        hr.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        hr.typeText("180")
        XCTAssertEqual(hr.value as? String, "180")
        let secondSave = clock.now
        save.tap()
        XCTAssertTrue(updating.waitForExistence(timeout: 5), "Must observe second recalculation before interruption")
        XCTAssertFalse(hr.isEnabled, "Second recalculation already finished; interruption was not exercised")
        app.terminate()
        record("terminate_during_second_refresh", elapsed: secondSave.duration(to: clock.now))
        XCTAssertEqual(app.state, .notRunning)

        let restart = clock.now
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 60), "App must reopen after interruption")
        record("relaunch_after_interruption", elapsed: restart.duration(to: clock.now))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        let resumedHR = app.textFields["settings.cardioHR"]
        XCTAssertTrue(resumedHR.waitForExistence(timeout: 20))
        let latestValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "180"), object: resumedHR)
        XCTAssertEqual(XCTWaiter.wait(for: [latestValue], timeout: 20), .completed, "Latest saved input must survive interruption")
        let resumeSave = clock.now
        app.buttons["settings.saveCardio"].tap()
        XCTAssertTrue(app.staticTexts["Saved. Estimates updated; previous versions retained."].waitForExistence(timeout: 180),
                      "Retry must finish for latest input")
        record("retry_refresh_complete", elapsed: resumeSave.duration(to: clock.now))
        XCTAssertEqual(resumedHR.value as? String, "180")
        XCTAssertEqual(app.state, .runningForeground)
        print("RELEASE_GATE_UI_COMPLETE latestHR=180 firstInFlight=true secondInFlight=true")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Synthetic Release settings after interrupted refresh"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testReleaseIntensityTransitions() throws {
        let app = XCUIApplication()
        XCTAssertTrue(app.launchArguments.isEmpty, "Release test must not enable debug fixtures")
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 60))
        let today = app.buttons["Today"].firstMatch
        let settings = app.buttons["Settings"].firstMatch
        let missing = app.staticTexts["LT1 / LT2 not set"]
        let low = app.descendants(matching: .any)["today.intensity.low"].firstMatch
        let middle = app.descendants(matching: .any)["today.intensity.middle"].firstMatch
        let high = app.descendants(matching: .any)["today.intensity.high"].firstMatch
        let lt1 = app.textFields["settings.lt1HeartRate"]
        let lt2 = app.textFields["settings.lt2HeartRate"]
        let save = app.buttons["settings.saveIntensityThresholds"]

        func edit(_ field: XCUIElement, value: String) {
            reach(field, in: app)
            field.tap()
            // A threshold has at most three digits; additional deletes are safe
            // for an initially empty field and avoid relying on placeholder value.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
            if !value.isEmpty { field.typeText(value) }
            let done = app.buttons["settings.intensityDone"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
        }
        func saveThresholds(_ first: String, _ second: String, message: String) {
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
            edit(lt1, value: first)
            edit(lt2, value: second)
            reach(save, in: app)
            save.tap()
            XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 15))
        }
        func showToday() {
            today.tap()
            XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 20))
        }
        func assertAllIn(_ element: XCUIElement) {
            reach(element, in: app)
            let predicate = NSPredicate(format: "label CONTAINS %@", "100%")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed,
                           "Synthetic 140 bpm samples must all be in the selected zone")
        }

        // Establish an explicit empty starting state regardless of retained defaults.
        saveThresholds("", "", message: "Intensity thresholds cleared.")
        showToday()
        reach(missing, in: app)
        XCTAssertTrue(missing.exists)
        XCTAssertFalse(low.exists)
        XCTAssertFalse(middle.exists)
        XCTAssertFalse(high.exists)

        saveThresholds("130", "150", message: "Intensity thresholds saved.")
        showToday()
        assertAllIn(middle)
        XCTAssertFalse(missing.exists)

        saveThresholds("", "", message: "Intensity thresholds cleared.")
        showToday()
        reach(missing, in: app)
        XCTAssertTrue(missing.exists)
        XCTAssertFalse(low.exists)
        XCTAssertFalse(middle.exists)
        XCTAssertFalse(high.exists)

        saveThresholds("150", "170", message: "Intensity thresholds saved.")
        showToday()
        assertAllIn(low)
        XCTAssertFalse(missing.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 60))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        reach(lt1, in: app)
        XCTAssertEqual(lt1.value as? String, "150")
        reach(lt2, in: app)
        XCTAssertEqual(lt2.value as? String, "170")
        print("RELEASE_INTENSITY_COMPLETE restoredLT1=150 restoredLT2=170")
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<16 {
            if element.isHittable { return }
            lower.press(forDuration: 0.05, thenDragTo: upper)
        }
        for _ in 0..<16 {
            if element.isHittable { return }
            upper.press(forDuration: 0.05, thenDragTo: lower)
        }
        XCTFail("Expected \(element.identifier) to be reachable", file: file, line: line)
    }

    private func record(_ name: String, elapsed: Duration) {
        let parts = elapsed.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        print("RELEASE_GATE_UI phase=\(name) elapsed_seconds=\(seconds)")
    }
}
