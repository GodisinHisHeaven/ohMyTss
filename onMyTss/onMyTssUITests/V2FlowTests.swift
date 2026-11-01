import XCTest

/// Debug uses isolated synthetic stores; explicit sync fixtures mock the source only.
/// These tests require a real Apple simulator and are not runnable on Linux.
final class V2FlowTests: XCTestCase {
    @MainActor
    func testOfflineRepairKeepsThousandDiskRecordsBrowsable() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-large-history", "--v2-disk-history",
                               "--v2-history-repair-fixture", "--v2-large-history-linked-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        let repairStatus = app.descendants(matching: .any)["history.repair.status"].firstMatch
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: repairStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 120), .completed,
                       "The durable local repair must finish before its results are checked.")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        app.buttons["Today"].firstMatch.tap()
        let garmin = app.buttons["today.workout.synthetic-launch-0"]
        XCTAssertTrue(reachDashboardButton(garmin, in: app))
        XCTAssertFalse(app.buttons["today.workout.synthetic-launch-strava-alias"].exists)
        garmin.tap()
        XCTAssertTrue(app.navigationBars["Run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Legacy TSS: 50.0")).firstMatch.exists)

        let linkedTags = app.descendants(matching: .any)["activity.linkedTags"].firstMatch
        reach(linkedTags, in: app)
        XCTAssertTrue(linkedTags.label.contains("history-sentinel-tag") || app.staticTexts["history-sentinel-tag"].exists)
        let linkedSet = app.descendants(matching: .any)["activity.linkedSet"].firstMatch
        reach(linkedSet, in: app)
        XCTAssertTrue(linkedSet.label.contains("Squat") || app.staticTexts["Squat"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "activity.linkedSet").count, 0)
        XCTAssertTrue(app.staticTexts["Sets from linked sources are shown here but cannot be edited here yet."].exists)
        let linkedReport = app.descendants(matching: .any)["activity.linkedReport"].firstMatch
        reach(linkedReport, in: app)
        XCTAssertTrue(linkedReport.label.contains("Front thighs") || app.staticTexts["Front thighs · Left"].exists)
        XCTAssertTrue(app.staticTexts["Reports from linked sources retain their original activity. Edit them in report history."].exists)
    }

    @MainActor
    func testLinkedPersonalDetailsRemainVisibleAndReadOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "--v2-linked-details-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let workout = app.buttons["today.workout.synthetic-linked-garmin"]
        XCTAssertTrue(reachDashboardButton(workout, in: app))
        workout.tap()
        XCTAssertTrue(app.navigationBars["Swim"].waitForExistence(timeout: 5))

        let linkedTags = app.descendants(matching: .any)["activity.linkedTags"].firstMatch
        reach(linkedTags, in: app)
        XCTAssertTrue(linkedTags.label.localizedCaseInsensitiveContains("paddles") || app.staticTexts["paddles"].exists)
        XCTAssertFalse(app.staticTexts["deleted-fixture-tag"].exists)
        XCTAssertFalse(app.staticTexts["legacy-deleted-fixture-tag"].exists)

        let ownSet = app.buttons["activity.ownSet"].firstMatch
        // A row can report isHittable while its tap point is obscured by
        // navigation chrome. Find the editable row before scrolling to the
        // linked report, which can unload this row from the list.
        guard reachDashboardButton(ownSet, in: app, navigationTitle: "Swim") else {
            let frame = ownSet.exists ? String(describing: ownSet.frame) : "not present"
            XCTFail("Canonical set did not reach the unobscured viewport: \(frame)\n\(app.debugDescription)")
            return
        }
        XCTAssertTrue(ownSet.isEnabled)
        let tabBar = app.tabBars.firstMatch
        let tabFrame = tabBar.exists ? String(describing: tabBar.frame) : "not present"
        print("UI_CANONICAL_SET frame=\(ownSet.frame) nav=\(app.navigationBars["Swim"].frame) tabs=\(tabFrame)")
        ownSet.tap()
        let opened = app.navigationBars["Edit set"].waitForExistence(timeout: 10)
        if !opened {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Canonical set editor did not open"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            print("UI_CANONICAL_SET_FAILURE \(app.debugDescription)")
        }
        XCTAssertTrue(opened)
        app.navigationBars["Edit set"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Swim"].waitForExistence(timeout: 5))

        let linkedSet = app.descendants(matching: .any)["activity.linkedSet"].firstMatch
        reach(linkedSet, in: app)
        XCTAssertTrue(app.staticTexts["Sets from linked sources are shown here but cannot be edited here yet."].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "activity.linkedSet").count, 0)

        let linkedReport = app.descendants(matching: .any)["activity.linkedReport"].firstMatch
        reach(linkedReport, in: app)
        XCTAssertTrue(app.staticTexts["Reports from linked sources retain their original activity. Edit them in report history."].exists)
    }

    @MainActor
    func testSyncWithThousandSavedActivitiesKeepsTabsUsable() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-large-history", "--v2-disk-history", "--v2-sync-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let sync = app.buttons["today.sync"]
        sync.tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        app.buttons["Today"].firstMatch.tap()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sync)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        #if DEBUG
        let message = app.staticTexts["Sync complete. Saved history remains available offline."]
        reach(message, in: app)
        XCTAssertTrue(message.exists)
        #endif
        sync.tap()
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        app.buttons["Today"].firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sync)], timeout: 30), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Saved history remains usable during incremental sync"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(app.state, .runningForeground)
    }

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
    func testIntensityThresholdsShowCompactDistribution() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-workout-map-demo", "--v2-intensity-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()

        let lt1 = app.textFields["settings.lt1HeartRate"]
        reach(lt1, in: app)
        lt1.tap()
        lt1.typeText("140")
        app.buttons["settings.intensityDone"].tap()
        let lt2 = app.textFields["settings.lt2HeartRate"]
        reach(lt2, in: app)
        lt2.tap()
        lt2.typeText("170")
        app.buttons["settings.intensityDone"].tap()
        let save = app.buttons["settings.saveIntensityThresholds"]
        reach(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Intensity thresholds saved."].waitForExistence(timeout: 5))

        app.buttons["Today"].firstMatch.tap()
        let low = app.descendants(matching: .any)["today.intensity.low"]
        reach(low, in: app)
        let middle = app.descendants(matching: .any)["today.intensity.middle"]
        let high = app.descendants(matching: .any)["today.intensity.high"]
        XCTAssertTrue(middle.exists)
        XCTAssertTrue(high.exists)
        XCTAssertTrue(low.label.contains("72%"))
        XCTAssertTrue(middle.label.contains("20%"))
        XCTAssertTrue(high.label.contains("8%"))
        XCTAssertTrue(low.frame.minY.isFinite && middle.frame.minY.isFinite && high.frame.minY.isFinite)
        XCTAssertLessThan(low.frame.midX, middle.frame.midX)
        XCTAssertLessThan(middle.frame.midX, high.frame.midX)
        XCTAssertEqual(low.frame.minY, middle.frame.minY, accuracy: 3)
        XCTAssertEqual(middle.frame.minY, high.frame.minY, accuracy: 3)
        XCTAssertFalse(app.staticTexts["Last 7 days · heart rate"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Based on")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Compact intensity distribution"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Settings"].firstMatch.tap()
        reach(lt1, in: app)
        XCTAssertEqual(lt1.value as? String, "140")
        XCTAssertEqual(lt2.value as? String, "170")
        lt1.tap()
        lt1.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        app.buttons["settings.intensityDone"].tap()
        reach(lt2, in: app)
        lt2.tap()
        lt2.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        app.buttons["settings.intensityDone"].tap()
        reach(save, in: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Intensity thresholds cleared."].waitForExistence(timeout: 5))
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
        app.buttons["Settings"].firstMatch.tap()
        let heartRate = app.textFields["settings.cardioHR"]
        XCTAssertTrue(heartRate.waitForExistence(timeout: 5))
        heartRate.tap()
        heartRate.typeText("190")
        app.buttons["settings.saveCardio"].tap()
        app.buttons["Today"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        app.buttons["Settings"].firstMatch.tap()
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
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Today"].firstMatch.tap()
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
    private func reachDashboardButton(_ element: XCUIElement, in app: XCUIApplication,
                                      navigationTitle: String = "Today") -> Bool {
        let navigationBar = app.navigationBars[navigationTitle]
        let tabBar = app.tabBars.firstMatch
        guard navigationBar.exists else { return false }
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for attempt in 0...16 {
            let viewport = app.frame
            let tabFrame = tabBar.exists ? tabBar.frame : .zero
            // On iPhone Duo the navigation controls can be a side rail, without
            // a TabBar element. Only a wide bottom bar limits vertical space.
            let hasBottomBar = !tabFrame.isEmpty && tabFrame.minY > navigationBar.frame.maxY
                && tabFrame.width >= viewport.width * 0.5
            let safeTop = navigationBar.frame.maxY + 8
            let safeBottom = (hasBottomBar ? min(viewport.maxY, tabFrame.minY) : viewport.maxY) - 8
            var rail = CGRect.null
            if !hasBottomBar {
                let frames = ["Today", "History", "Settings"].compactMap { name -> CGRect? in
                    let button = app.buttons[name].firstMatch
                    guard button.exists else { return nil }
                    let frame = button.frame
                    return !frame.isEmpty && frame.width < viewport.width * 0.5 ? frame : nil
                }
                if frames.count >= 2 {
                    let bounds = frames.reduce(CGRect.null) { $0.union($1) }
                    if bounds.height > bounds.width { rail = bounds }
                }
            }
            var scrollDown = true
            if element.exists {
                let frame = element.frame
                let centerOutsideRail = rail.isNull || frame.midX < rail.minX - 8 || frame.midX > rail.maxX + 8
                if frame.width > 0, frame.height > 0, frame.minY >= safeTop, frame.maxY <= safeBottom,
                   frame.midX >= viewport.minX + 8, frame.midX <= viewport.maxX - 8,
                   centerOutsideRail, element.isHittable {
                    return true
                }
                if frame.height > 0, frame.minY < safeTop { scrollDown = false }
            }
            if attempt == 16 { break }
            if scrollDown {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            } else {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            }
        }
        return false
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
        guard reachDashboardButton(record, in: app) else {
            XCTFail("Record strength is not fully visible in the dashboard viewport")
            return
        }
        record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard app.navigationBars["Strength session"].waitForExistence(timeout: 5) else {
            XCTFail("Record strength did not open the strength session sheet")
            return
        }
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
        dismissStrengthKeyboard(app)
        let save = app.buttons["strength.save.form"]
        reach(save, in: app)
        save.tap()
        let zero = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "RIR 0")).firstMatch
        reach(zero, in: app)
        XCTAssertTrue(zero.exists)
        zero.tap()
        let editRIR = app.textFields["strength.rir"]
        editRIR.tap()
        editRIR.typeText(XCUIKeyboardKey.delete.rawValue)
        dismissStrengthKeyboard(app)
        let saveChanges = app.buttons["strength.save.form"]
        reach(saveChanges, in: app)
        saveChanges.tap()
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
    private func dismissStrengthKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["strength.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Strength keyboard Done is unavailable", file: file, line: line)
        done.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Strength keyboard did not dismiss", file: file, line: line)
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
    func testImportedHistoryColorsMusclesAndAllowsQuickOverride() {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-workout-map-demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        let left = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, left")).firstMatch
        let right = app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, right")).firstMatch
        reach(left, in: app)
        let startingValue = left.value as? String
        XCTAssertTrue(startingValue?.contains("Moderate") == true)
        XCTAssertFalse(startingValue?.contains("RPE") == true)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'estimated'")).firstMatch.exists)
        attachBodyMapScreenshot(app, name: "History alone — muscle grades without manual ratings")
        left.tap()
        XCTAssertTrue(app.buttons["rpe.grade.1"].isSelected)
        XCTAssertEqual(app.keyboards.count, 0)
        app.buttons["rpe.cancel"].tap()
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, startingValue)
        left.tap()
        app.buttons["rpe.grade.2"].tap()
        app.buttons["rpe.save"].tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("RPE 8") == true)
        XCTAssertEqual(right.value as? String, startingValue)
        app.buttons["History"].firstMatch.tap()
        app.buttons["Today"].firstMatch.tap()
        reach(left, in: app)
        XCTAssertTrue((left.value as? String)?.contains("RPE 8") == true)
        XCTAssertEqual(right.value as? String, startingValue)
        attachBodyMapScreenshot(app, name: "History grade with one-side RPE adjustment")
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
        app.buttons["History"].firstMatch.tap()
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
        app.buttons["History"].firstMatch.tap()
        app.buttons["Today"].firstMatch.tap()
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
