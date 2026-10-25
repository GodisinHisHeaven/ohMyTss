import XCTest

/// Runs against the app's DEBUG-only isolated SwiftData store; no fake imports or HealthKit mocks.
/// These tests require a real Apple simulator and are not runnable on Linux.
final class V2FlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected connected control to be reachable")
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
        let zero = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "RIR 0")).firstMatch
        reach(zero, in: app)
        XCTAssertTrue(zero.exists)
        zero.tap()
        let editRIR = app.textFields["strength.rir"]
        editRIR.tap()
        editRIR.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["strength.save"].tap()
        let unknown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Effort unknown")).firstMatch
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
}
