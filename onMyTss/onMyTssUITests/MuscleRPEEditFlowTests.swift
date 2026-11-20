import XCTest

/// All observations come from the isolated, synthetic RPE edit fixture.
@MainActor
final class MuscleRPEEditFlowTests: XCTestCase {
    func testOlderLeftToBothUpdatesBothDisplayedRatingsAndDate() {
        verifyBothEdit(olderSide: "left")
    }

    func testOlderRightToBothUpdatesBothDisplayedRatingsAndDate() {
        verifyBothEdit(olderSide: "right")
    }

    func testSameDateSidesToBothUpdatesBothDisplayedRatingsAndDate() {
        verifyBothEdit(olderSide: "left", sameDate: true)
    }

    func testSwitchingToOppositeSideKeepsOriginalSide() {
        let app = launch()
        let left = muscle("left", in: app), right = muscle("right", in: app)
        reach(left, in: app)
        let originalLeft = left.value as? String
        left.tap()
        app.segmentedControls["rpe.side"].buttons["Right"].tap()
        chooseSevenAndSave(in: app)
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, originalLeft)
        assertRating(right, rpe: 7, date: Date())
    }

    func testExplicitHistoricalDateSurvivesSideChange() {
        let app = launch()
        let left = muscle("left", in: app), right = muscle("right", in: app)
        reach(left, in: app)
        let originalLeft = left.value as? String, originalRight = right.value as? String
        left.tap()
        let historicalDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        chooseDate(historicalDate, in: app)
        let both = app.segmentedControls["rpe.side"].buttons["Both"]
        reach(both, in: app)
        both.tap()
        XCTAssertTrue(app.staticTexts["rpe.datePolicy"].label.contains("Your chosen date is kept"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Historical RPE date preserved after changing sides"
        attachment.lifetime = .keepAlways
        add(attachment)
        chooseSevenAndSave(in: app)
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, originalLeft)
        XCTAssertEqual(right.value as? String, originalRight)
    }

    func testCancellingSideAndGradeChangesKeepsBothRatings() {
        let app = launch()
        let left = muscle("left", in: app), right = muscle("right", in: app)
        reach(left, in: app)
        let originalLeft = left.value as? String, originalRight = right.value as? String
        left.tap()
        app.segmentedControls["rpe.side"].buttons["Both"].tap()
        app.buttons["rpe.grade.2"].tap()
        app.buttons["rpe.cancel"].tap()
        reach(left, in: app)
        XCTAssertEqual(left.value as? String, originalLeft)
        XCTAssertEqual(right.value as? String, originalRight)
        left.tap()
        XCTAssertTrue(app.segmentedControls["rpe.side"].buttons["Left"].isSelected)
        XCTAssertTrue(app.buttons["rpe.grade.0"].isSelected)
        app.buttons["rpe.cancel"].tap()
    }

    private func verifyBothEdit(olderSide: String, sameDate: Bool = false) {
        let app = launch(olderSide: olderSide, sameDate: sameDate)
        let opened = muscle(olderSide, in: app)
        reach(opened, in: app)
        assertRating(opened, rpe: 3, date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        opened.tap()
        app.segmentedControls["rpe.side"].buttons["Both"].tap()
        chooseSevenAndSave(in: app)
        let left = muscle("left", in: app), right = muscle("right", in: app)
        reach(left, in: app)
        assertRating(left, rpe: 7, date: Date())
        assertRating(right, rpe: 7, date: Date())
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Both sides updated from older \(olderSide)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(olderSide: String = "left", sameDate: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "--v2-rpe-edit-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if olderSide == "right" { app.launchArguments.append("--v2-rpe-older-right") }
        if sameDate { app.launchArguments.append("--v2-rpe-same-date") }
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 15))
        return app
    }

    private func muscle(_ side: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "bodyMap.front.quads")
            .matching(NSPredicate(format: "label == %@", "Front thighs, \(side)")).firstMatch
    }

    private func chooseSevenAndSave(in app: XCUIApplication) {
        let grade = app.buttons["rpe.grade.2"]
        reach(grade, in: app)
        grade.tap() // Hard starts at RPE 8.
        app.buttons["rpe.fineTune-Decrement"].tap()
        let save = app.buttons["rpe.save"]
        reach(save, in: app)
        save.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }

    private func assertRating(_ element: XCUIElement, rpe: Int, date: Date,
                              file: StaticString = #filePath, line: UInt = #line) {
        let value = element.value as? String ?? ""
        XCTAssertTrue(value.contains("RPE \(rpe)"), value, file: file, line: line)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        XCTAssertTrue(value.contains(formatter.string(from: date)), value, file: file, line: line)
    }

    private func chooseDate(_ date: Date, in app: XCUIApplication) {
        let picker = app.datePickers["rpe.date"]
        reach(picker, in: app)
        picker.tap()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d"
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", formatter.string(from: date))).firstMatch
        if !day.exists {
            // The seven-day window can span the previous calendar month.
            let previousMonth = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Previous Month")).firstMatch
            if previousMonth.exists { previousMonth.tap() }
        }
        XCTAssertTrue(day.waitForExistence(timeout: 3), app.debugDescription)
        day.tap()
        // The navigation bar can be covered by the compact calendar. Its Date
        // label stays outside the popover, so dismiss from there before scrolling.
        app.staticTexts["Date"].tap()
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        for _ in 0..<12 {
            if element.isHittable { return }
            lower.press(forDuration: 0.05, thenDragTo: upper)
        }
        for _ in 0..<12 {
            if element.isHittable { return }
            upper.press(forDuration: 0.05, thenDragTo: lower)
        }
        XCTAssertTrue(element.isHittable, "Unreachable \(element.identifier)", file: file, line: line)
    }
}
