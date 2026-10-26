import XCTest

/// Runs against the app's DEBUG-only isolated SwiftData store; no fake imports or HealthKit mocks.
/// These tests require a real Apple simulator and are not runnable on Linux.
final class V2FlowTests: XCTestCase {
    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testLaunchWithLargeSavedHistoryOpensUsableTabs() {
        assertLargeHistoryOpensUsableTabs(missingEstimates: false)
    }

    @MainActor
    func testLaunchWithLargeLegacyHistoryAllowsNavigationDuringBackfill() {
        assertLargeHistoryOpensUsableTabs(missingEstimates: true)
    }

    @MainActor
    func testStorageOpenFailureShowsRetryInsteadOfTerminatingApp() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-storage-failure-once"]
        app.launch()
        XCTAssertTrue(app.buttons["storage.retry"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["storage.retry"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSavingMaximumHeartRateWithThousandDiskRecordsKeepsNavigationUsable() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-large-history", "--v2-disk-history"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let heartRate = app.textFields["settings.cardioHR"]
        XCTAssertTrue(heartRate.waitForExistence(timeout: 5))
        heartRate.tap()
        heartRate.typeText("190")
        app.buttons["settings.saveCardio"].tap()
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Saved. Estimates updated; previous versions retained."].waitForExistence(timeout: 30))
        XCTAssertEqual(heartRate.value as? String, "190")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func assertLargeHistoryOpensUsableTabs(missingEstimates: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-large-history"]
        if missingEstimates { app.launchArguments.append("--v2-missing-estimates") }
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        // app.launch() includes XCTest's automation handshake and idle wait.
        // Assert usable navigation here; the persistence test checks main-actor
        // responsiveness during backfill without timing that external setup.
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["bodyMap.front.quads"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func reach(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        // A sheet can return to a retained scroll offset below the edited row.
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(element.isHittable, "Expected connected control to be reachable", file: file, line: line)
    }

    @MainActor
    func testRegionalReport_noneRightEditAndDelete() {
        let app = launch()
        let region = app.buttons["bodyMap.front.quads"].firstMatch
        reach(region, in: app)
        region.tap()
        XCTAssertTrue(app.buttons["feedback.none"].waitForExistence(timeout: 3))
        app.segmentedControls["feedback.side"].buttons["Right"].tap()
        app.buttons["feedback.none"].tap()
        let history = app.buttons["Report history"]
        reach(history, in: app)
        history.tap()
        let report = app.staticTexts["No noticeable discomfort"]
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Front thighs · Right"].exists)
        report.tap()
        app.segmentedControls["feedback.side"].buttons["Left"].tap()
        app.buttons["feedback.save"].tap()
        XCTAssertTrue(app.staticTexts["Front thighs · Left"].waitForExistence(timeout: 3))
        app.staticTexts["No noticeable discomfort"].tap()
        let delete = app.buttons["Delete report"]
        reach(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.staticTexts["No reports yet"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Report removed from actual stored history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testStrengthCreateEditDelete_RIRZeroAndUnknown() {
        let app = launch()
        let record = app.buttons["today.strength"]
        reach(record, in: app)
        record.tap()
        let create = app.buttons["strength.createSession"]
        reach(create, in: app)
        create.tap()
        let add = app.buttons["activity.addSets"]
        reach(add, in: app)
        add.tap()
        let rir = app.textFields["strength.rir"]
        XCTAssertTrue(rir.waitForExistence(timeout: 3))
        rir.tap()
        rir.typeText("0")
        app.buttons["strength.save"].tap()
        let zero = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "RIR 0")).firstMatch
        reach(zero, in: app)
        XCTAssertTrue(zero.exists)
        zero.tap()
        let editRIR = app.textFields["strength.rir"]
        editRIR.tap()
        editRIR.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["strength.save"].tap()
        let unknown = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Effort unknown")).firstMatch
        reach(unknown, in: app)
        XCTAssertTrue(unknown.exists)
        unknown.tap()
        let delete = app.buttons["Delete set"]
        reach(delete, in: app)
        delete.tap()
        let noSets = app.staticTexts["No sets recorded"]
        reach(noSets, in: app)
        XCTAssertTrue(noSets.exists)
    }

    @MainActor
    func testSkipDoesNotCreateFeedback() {
        let app = launch()
        let region = app.buttons["bodyMap.front.chest"].firstMatch
        reach(region, in: app)
        region.tap()
        app.buttons["feedback.skip"].tap()
        let history = app.buttons["Report history"]
        reach(history, in: app)
        history.tap()
        XCTAssertTrue(app.staticTexts["No reports yet"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testBodyMapIndependentSidesAndBackRegions() {
        let app = launch()
        let left = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, left")).firstMatch
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, "No report in the last 7 days")
        left.tap()
        app.segmentedControls["feedback.side"].buttons["Left"].tap()
        app.buttons["feedback.save"].tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("Soreness") == true)

        let right = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, right")).firstMatch
        right.tap()
        app.segmentedControls["feedback.side"].buttons["Right"].tap()
        app.buttons["feedback.none"].tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("Soreness") == true)
        XCTAssertTrue((right.value as? String)?.contains("No noticeable discomfort") == true)
        attachBodyMapScreenshot(app, name: "Front — independent left and right reports")

        let back = app.segmentedControls["bodyMap.face"].buttons["Back"]
        reach(back, in: app)
        back.tap()
        let backRegions = [("shoulders", "Shoulders"), ("arms", "Arms"), ("back", "Back"),
                           ("glutes", "Glutes"), ("hamstrings", "Back thighs"), ("calves", "Calves")]
        for (region, label) in backRegions {
            let target = app.buttons["bodyMap.back.\(region)"].firstMatch
            reach(target, in: app)
            target.tap()
            XCTAssertTrue(app.buttons["feedback.skip"].waitForExistence(timeout: 3), "Back \(region) must be tappable")
            let picker = app.descendants(matching: .any)["feedback.region"].firstMatch
            XCTAssertTrue((picker.label + " " + (picker.value as? String ?? "")).contains(label))
            app.buttons["feedback.skip"].tap()
        }
        XCTAssertFalse(app.buttons["bodyMap.back.quads"].exists)
        attachBodyMapScreenshot(app, name: "Back — all six visible regions respond")
    }

    @MainActor
    private func attachBodyMapScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
