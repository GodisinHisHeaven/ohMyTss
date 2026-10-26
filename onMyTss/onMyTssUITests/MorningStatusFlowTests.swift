import XCTest

final class MorningStatusFlowTests: XCTestCase {
    @MainActor
    func testMorningAccountStaysNativeThroughPrivacySettingsAndSignOut() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--morning-status-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let entry = app.buttons["settings.morningStatus"]
        reach(entry, app: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Morning Status"].waitForExistence(timeout: 5))
        let email = app.textFields["morning.email"]
        email.tap()
        email.typeText("athlete@example.invalid")
        let password = app.secureTextFields["morning.password"]
        password.tap()
        password.typeText("fixture-password")
        app.buttons["morning.signIn"].tap()
        let name = app.staticTexts["morning.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(name.label.contains("Sample Athlete"))
        attach(app, "Native morning status with synthetic account")

        let timezone = app.buttons["morning.timezone"]
        reach(timezone, app: app)
        timezone.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Asia/Shanghai")
        app.buttons["morning.zone.Asia/Shanghai"].tap()
        let save = app.buttons["morning.saveTimezone"]
        reach(save, app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertFalse(save.isEnabled)
        let saved = app.staticTexts["Morning delivery time zone updated."]
        reach(saved, app: app)
        XCTAssertTrue(saved.exists)
        attach(app, "Native time zone save confirmation")

        let privacy = app.buttons["morning.privacy"]
        reach(privacy, app: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Data and Privacy"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let unsubscribe = app.buttons["morning.unsubscribe"]
        reach(unsubscribe, app: app, towardTop: true)
        unsubscribe.tap()
        app.buttons["Turn Off Texts"].tap()
        let stopped = app.staticTexts["morning.subscription"]
        reach(stopped, app: app, towardTop: true)
        XCTAssertTrue(stopped.label.contains("Not subscribed"))
        attach(app, "Native SMS unsubscribe state with synthetic account")

        let signOut = app.buttons["morning.signOut"]
        reach(signOut, app: app)
        signOut.tap()
        XCTAssertTrue(app.textFields["morning.email"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func reach(_ element: XCUIElement, app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = app.tabBars.firstMatch.frame.minY
            let frame = element.exists ? element.frame : .zero
            if element.isHittable, frame.minY >= top, frame.maxY <= bottom { return }

            // Form updates can move a row above the viewport after a save.
            // Follow its current position and use short drags to avoid overshooting it.
            let hasPosition = !frame.isEmpty
            let scrollTowardTop = hasPosition ? frame.minY < top : towardTop
            let center = (top + bottom) / 2
            let distance = min((bottom - top) * 0.4,
                               hasPosition ? max(60, abs(frame.midY - center)) : (bottom - top) * 0.4)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width / 2, dy: center))
            let finish = start.withOffset(CGVector(dx: 0, dy: scrollTowardTop ? distance : -distance))
            start.press(forDuration: 0.05, thenDragTo: finish)
        }
        XCTFail("Could not fully reveal \(element.description)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
