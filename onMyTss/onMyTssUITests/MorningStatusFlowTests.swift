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
        XCTAssertTrue(app.staticTexts["Name, Sample Athlete"].waitForExistence(timeout: 5))
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
        save.tap()
        XCTAssertTrue(app.staticTexts["Morning delivery time zone updated."].waitForExistence(timeout: 3))

        let privacy = app.buttons["morning.privacy"]
        reach(privacy, app: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Data and Privacy"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let unsubscribe = app.buttons["morning.unsubscribe"]
        reach(unsubscribe, app: app)
        unsubscribe.tap()
        app.buttons["Turn Off Texts"].tap()
        let stopped = app.staticTexts["SMS, Not subscribed"]
        reach(stopped, app: app)
        XCTAssertTrue(stopped.exists)
        attach(app, "Native SMS unsubscribe state with synthetic account")

        let signOut = app.buttons["morning.signOut"]
        reach(signOut, app: app)
        signOut.tap()
        XCTAssertTrue(app.textFields["morning.email"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func reach(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<9 {
            if element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<12 {
            if element.isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
