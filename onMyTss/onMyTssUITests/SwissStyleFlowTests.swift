import XCTest

#if DEBUG
final class SwissStyleFlowTests: XCTestCase {
    @MainActor
    func testOnboardingLayoutsAndOptionalThresholdRemainUsable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--swiss-onboarding", "-AppleInterfaceStyle", "Light"]
        app.launch()
        let start = app.buttons["Get Started"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
        attach(app, "Swiss — welcome")
        start.tap()
        XCTAssertTrue(app.staticTexts["Health Data Access"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].isHittable)
        attach(app, "Swiss — Health permissions")
        // Preview the next layout without requesting actual Health permissions.
        app.terminate()
        app.launchArguments += ["--swiss-threshold-preview"]
        app.launch()
        let skip = app.buttons["Skip (FTP Unknown)"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        XCTAssertTrue(skip.isHittable)
        attach(app, "Swiss — optional threshold")
        skip.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testReducedEffectsKeepRPEAndSettingsUsableInDarkMode() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "--swiss-reduced-effects",
                               "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["readiness.score"].waitForExistence(timeout: 10))
        attach(app, "Swiss — dark reduced effects")
        let muscle = app.buttons["bodyMap.front.quads"].firstMatch
        for _ in 0..<16 where !muscle.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(muscle.isHittable)
        muscle.tap()
        let grade = app.buttons["rpe.grade.1"]
        XCTAssertTrue(grade.waitForExistence(timeout: 5))
        grade.tap()
        XCTAssertTrue(grade.isSelected)
        XCTAssertTrue(app.buttons["rpe.save"].isEnabled)
        attach(app, "Swiss — opaque RPE controls")
        app.buttons["rpe.cancel"].tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.textFields["settings.cardioHR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.saveCardio"].isHittable)
        attach(app, "Swiss — settings")
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["history.trend"].waitForExistence(timeout: 5))
        attach(app, "Swiss — dark history")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
