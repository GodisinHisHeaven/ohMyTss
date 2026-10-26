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
    func testLaunchWithLargeLegacyHistoryNeedsNoBackfillForDashboard() {
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
        // The dashboard no longer starts a full-history backfill. These stored
        // records must not prevent immediate use of readiness and muscle RPE.
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(app.buttons["bodyMap.front.quads"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func reach(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        // Full-screen swipes can jump a small body-map target from beneath
        // the tab bar to above the navigation bar on iPhone SE. Short drags
        // leave overlapping visible areas, so every region can be reached.
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<16 {
            if element.isHittable { return }
            lower.press(forDuration: 0.05, thenDragTo: upper)
        }
        // A sheet can return to a retained scroll offset below the edited row.
        for _ in 0..<16 {
            if element.isHittable { return }
            upper.press(forDuration: 0.05, thenDragTo: lower)
        }
        XCTAssertTrue(element.isHittable, "Expected \(element.identifier) to be reachable at \(element.frame)",
                      file: file, line: line)
    }

    @MainActor
    func testRegionalReport_noneRightEditAndDelete() {
        let app = launch()
        app.buttons["today.more"].tap()
        app.buttons["Discomfort reports"].tap()
        app.buttons["Add report"].tap()
        XCTAssertTrue(app.buttons["feedback.none"].waitForExistence(timeout: 3))
        app.segmentedControls["feedback.side"].buttons["Right"].tap()
        app.buttons["feedback.none"].tap()
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
    func testCancelDoesNotCreateMuscleRPE() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["readiness.empty"].exists)
        let region = app.buttons["bodyMap.front.chest"].firstMatch
        reach(region, in: app)
        region.tap()
        XCTAssertFalse(app.buttons["rpe.save"].isEnabled)
        app.buttons["rpe.cancel"].tap()
        reach(region, in: app)
        XCTAssertEqual(region.value as? String, "Not rated in the last 7 days")
    }

    @MainActor
    func testBodyMapIndependentSidesAndBackRegions() {
        let app = launch()
        let left = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, left")).firstMatch
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, "Not rated in the last 7 days")
        left.tap()
        app.buttons["rpe.grade.2"].tap()
        XCTAssertEqual(app.keyboards.count, 0)
        app.buttons["rpe.save"].tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("RPE 8") == true)

        let right = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, right")).firstMatch
        right.tap()
        app.buttons["rpe.grade.0"].tap()
        app.buttons["rpe.save"].tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("RPE 8") == true)
        XCTAssertTrue((right.value as? String)?.contains("RPE 2") == true)
        attachBodyMapScreenshot(app, name: "Front — independent left and right RPE")

        let back = app.segmentedControls["bodyMap.face"].buttons["Back"]
        reach(back, in: app)
        back.tap()
        let backRegions = [("shoulders", "Shoulders"), ("arms", "Arms"), ("back", "Back"),
                           ("glutes", "Glutes"), ("hamstrings", "Back thighs"), ("calves", "Calves")]
        for (region, label) in backRegions {
            let target = app.buttons["bodyMap.back.\(region)"].firstMatch
            reach(target, in: app)
            target.tap()
            XCTAssertTrue(app.buttons["rpe.cancel"].waitForExistence(timeout: 3), "Back \(region) must be tappable")
            XCTAssertTrue(app.navigationBars[label].exists)
            app.buttons["rpe.cancel"].tap()
        }
        XCTAssertFalse(app.buttons["bodyMap.back.quads"].exists)
        attachBodyMapScreenshot(app, name: "Back — six quick RPE targets")
    }

    @MainActor
    func testReadinessAndHistoryShowTrendsAndWorkoutCategories() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "-AppleInterfaceStyle", "Light"]
        app.launch()
        XCTAssertTrue(app.staticTexts["readiness.score"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["readiness.score"].label, "72")
        XCTAssertFalse(app.staticTexts["Regional context"].exists)
        attachBodyMapScreenshot(app, name: "Today — readiness and seven-day muscle RPE")
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["history.trend"].exists)
        XCTAssertFalse(app.staticTexts["Total TSS"].exists)
        XCTAssertFalse(app.staticTexts["Avg CTL"].exists)
        attachBodyMapScreenshot(app, name: "History — one trend and six workout categories")
        // List exposes rows lazily: scroll each saved row into view before
        // checking it, and verify that the seventh workout is excluded.
        for index in 0..<6 {
            let row = app.buttons["history.workout.synthetic-dashboard-\(index)"]
            reach(row, in: app)
            XCTAssertTrue(["Running", "Cycling", "Swimming", "Strength", "Walking"].contains(row.label))
        }
        XCTAssertFalse(app.buttons["history.workout.synthetic-dashboard-6"].exists)
        let load = app.segmentedControls["history.trend"].buttons["Training load"]
        reach(load, in: app)
        load.tap()
        attachBodyMapScreenshot(app, name: "History — training load trend")
    }

    @MainActor
    func testQuickRPEFineTuningNeedsNoKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "-AppleInterfaceStyle", "Light"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let muscle = app.buttons["bodyMap.front.quads"].firstMatch
        reach(muscle, in: app)
        muscle.tap()
        app.buttons["rpe.grade.3"].tap()
        app.buttons["rpe.fineTune-Increment"].tap()
        XCTAssertEqual(app.keyboards.count, 0)
        attachBodyMapScreenshot(app, name: "Quick RPE — level selection and one-point adjustment")
        app.buttons["rpe.save"].tap()
        reach(muscle, in: app)
        XCTAssertTrue((muscle.value as? String)?.contains("RPE 10") == true)
        app.tabBars.buttons["History"].tap()
        app.tabBars.buttons["Today"].tap()
        reach(muscle, in: app)
        XCTAssertTrue((muscle.value as? String)?.contains("RPE 10") == true)
    }

    @MainActor
    func testDashboardAndRPEAtAccessibilitySizeInDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["readiness.score"].waitForExistence(timeout: 10))
        attachBodyMapScreenshot(app, name: "Today — accessibility text and dark appearance")
        let muscle = app.buttons["bodyMap.front.quads"].firstMatch
        reach(muscle, in: app)
        muscle.tap()
        let grade = app.buttons["rpe.grade.1"]
        reach(grade, in: app)
        grade.tap()
        let save = app.buttons["rpe.save"]
        reach(save, in: app)
        attachBodyMapScreenshot(app, name: "Quick RPE — accessible controls in dark appearance")
        save.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attachBodyMapScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
