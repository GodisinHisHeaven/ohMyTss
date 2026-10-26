//
//  onMyTssUITestsLaunchTests.swift
//  onMyTssUITests
//
//  Created by Mingjun Liu on 11/7/25.
//

import XCTest

final class onMyTssUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let ready = NSPredicate { _, _ in
            app.navigationBars["Today"].exists || app.buttons["Get Started"].exists
        }
        expectation(for: ready, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
