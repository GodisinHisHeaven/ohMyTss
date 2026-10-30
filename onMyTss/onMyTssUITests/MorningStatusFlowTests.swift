import XCTest

final class MorningStatusFlowTests: XCTestCase {
    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testMorningPhoneEntryAndPrivacyWithoutSendingSMS() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--morning-status-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.morningStatus"]
        reach(entry, app: app)
        entry.tap()
        let phone = app.textFields["morning.phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["morning.email"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        let send = app.buttons["morning.sendCode"]
        XCTAssertFalse(send.isEnabled)
        phone.tap()
        phone.typeText("20255")
        XCTAssertFalse(send.isEnabled)
        phone.typeText("50100")
        XCTAssertTrue(send.isEnabled)
        app.buttons["Done"].tap()
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        attach(app, "Morning status phone entry — no SMS requested")
        let privacy = app.buttons["morning.privacy"]
        reach(privacy, app: app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Data and Privacy"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
    }

    // The no-network fixture exists only in Debug. Never send a real SMS if
    // someone runs all UI tests against a normal Release app.
    #if DEBUG
    @MainActor
    func testNewPhoneUserEnablesSummaryWithoutAccountForm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--v2-rpe-demo", "--morning-status-ui-fixture", "--morning-new-user-fixture", "-AppleInterfaceStyle", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.morningStatus"]
        reach(entry, app: app)
        entry.tap()
        let phone = app.textFields["morning.phone"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap(); phone.typeText("2025550100")
        app.buttons["morning.sendCode"].tap()
        let code = app.textFields["morning.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap(); code.typeText("123456")
        dismissKeyboardAndVerify(app)
        let enable = app.buttons["morning.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["morning.subscription"].label.contains("Not subscribed"))
        XCTAssertFalse(app.buttons["morning.syncSummary"].exists)
        enable.tap()
        attach(app, "Morning texts — explicit summary consent")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(enable.exists)
        enable.tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Enable Morning Texts", "morning.enable")).firstMatch.tap()
        let sync = app.buttons["morning.syncSummary"]
        reach(sync, app: app)
        XCTAssertTrue(sync.isEnabled)
        sync.tap()
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertTrue(app.staticTexts["Readiness"].exists)
        attach(app, "Morning texts — new user app summary")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testMorningPhoneStaysNativeThroughPrivacySettingsAndDisconnect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--v2-ui-tests", "--morning-status-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.morningStatus"]
        reach(entry, app: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Morning Status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["morning.email"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        attach(app, "Morning status phone entry without an account form")
        let phone = app.textFields["morning.phone"]
        phone.tap()
        phone.typeText("2025550100")
        app.buttons["morning.sendCode"].tap()
        let code = app.textFields["morning.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["morning.resend"].isEnabled)
        attach(app, "Morning status one-time verification code")
        code.tap()
        code.typeText("000000")
        dismissKeyboardAndVerify(app)
        let error = app.staticTexts["The code is incorrect or expired. Check it or request a new code."]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        code.tap()
        code.typeText("123456")
        dismissKeyboardAndVerify(app)
        let connected = app.staticTexts["morning.connectedPhone"]
        XCTAssertTrue(connected.waitForExistence(timeout: 5))
        XCTAssertTrue(connected.label.contains("0100"))
        attach(app, "Native morning status with verified synthetic phone")

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
        let sideBack = app.buttons["BackButton"]
        if sideBack.exists {
            sideBack.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["Morning Status"].waitForExistence(timeout: 5))

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
        XCTAssertTrue(app.textFields["morning.phone"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["morning.code"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
    #endif

    @MainActor
    private func dismissKeyboardAndVerify(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        let verify = app.buttons["morning.verify"]
        reach(verify, app: app)
        XCTAssertTrue(verify.isEnabled)
        verify.tap()
    }

    @MainActor
    private func reach(_ element: XCUIElement, app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let viewport = app.frame
            let tabBar = app.tabBars.firstMatch
            let tabFrame = tabBar.exists ? tabBar.frame : .zero
            // iOS can place the tab controls on the side without exposing a
            // TabBar element. Only a bottom bar limits the vertical viewport.
            let hasBottomBar = !tabFrame.isEmpty && tabFrame.minY > top
                && tabFrame.width >= viewport.width * 0.5
            let bottom = hasBottomBar ? min(viewport.maxY, tabFrame.minY) : viewport.maxY
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
