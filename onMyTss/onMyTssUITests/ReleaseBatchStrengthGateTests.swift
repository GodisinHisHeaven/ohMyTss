import Foundation
import XCTest

/// Operates on the preinstalled synthetic Release store only. The runner must
/// compare the resulting database against the captured pre-test baseline.
@MainActor
final class ReleaseBatchStrengthGateTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testReleaseSavesTwentySetsInOneBatch() {
        let app = XCUIApplication()
        XCTAssertTrue(app.launchArguments.isEmpty, "Do not enable Debug fixtures in the Release app")
        app.launch()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 90))

        // The old-version seed puts this workout in the recent list and gives
        // it one personal set. External SQLite verification checks that set.
        let workout = app.buttons["today.workout.synthetic-launch-0"].firstMatch
        guard reachDashboardButton(workout, in: app) else {
            XCTFail("Synthetic workout is not safely tappable.\n\(app.debugDescription)")
            return
        }
        workout.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Run"].waitForExistence(timeout: 30), app.debugDescription)
        let add = app.buttons["activity.addSets"].firstMatch
        guard reach(add, in: app) else {
            XCTFail("Add sets is not reachable.\n\(app.debugDescription)")
            return
        }
        add.tap()
        XCTAssertTrue(app.navigationBars["Add sets"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["strength.exercise"].waitForExistence(timeout: 20), app.debugDescription)

        // The set-count Stepper has no explicit accessibility identifier.
        // Resolve each increment by its current exact label or its labeled
        // stepper parent; fail closed if the platform exposes neither.
        func increment(for count: Int) -> XCUIElement? {
            let title = "Sets: \(count)"
            let direct = app.buttons["\(title)-Increment"].firstMatch
            if direct.exists && direct.isEnabled { return direct }
            let parent = app.steppers.matching(NSPredicate(format: "label == %@", title)).firstMatch
            let nested = parent.buttons["Increment"].firstMatch
            if parent.exists && nested.exists && nested.isEnabled { return nested }
            return nil
        }
        for count in 1..<20 {
            guard let button = increment(for: count), reach(button, in: app) else {
                XCTFail("Could not resolve enabled increment at Sets: \(count).\n\(app.debugDescription)")
                return
            }
            button.tap()
        }
        let expected = "Sets: 20"
        let displayed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@ OR identifier == %@", expected, expected, "\(expected)-Increment")
        ).firstMatch
        XCTAssertTrue(displayed.waitForExistence(timeout: 10), "20-set state not observable.\n\(app.debugDescription)")
        let save = app.buttons["strength.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        let clock = ContinuousClock()
        let started = clock.now
        save.tap() // One action must save the whole batch.
        let editorDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                         object: app.navigationBars["Add sets"])
        XCTAssertEqual(XCTWaiter.wait(for: [editorDismissed], timeout: 120), .completed,
                       "20-set editor did not dismiss.\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Run"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.otherElements["v2.error"].exists, app.debugDescription)
        let elapsed = started.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("RELEASE_BATCH_STRENGTH_SUBMITTED count=20 session=synthetic-launch-0 elapsed_seconds=\(seconds)")
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<16 {
            if element.exists && element.isHittable { return true }
            lower.press(forDuration: 0.05, thenDragTo: upper)
        }
        for _ in 0..<16 {
            if element.exists && element.isHittable { return true }
            upper.press(forDuration: 0.05, thenDragTo: lower)
        }
        return element.exists && element.isHittable
    }

    private func reachDashboardButton(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let navigationBar = app.navigationBars["Today"]
        guard navigationBar.exists else { return false }
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for attempt in 0...16 {
            let viewport = app.frame
            let tab = app.tabBars.firstMatch
            let tabFrame = tab.exists ? tab.frame : .zero
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
                let outsideRail = rail.isNull || frame.midX < rail.minX - 8 || frame.midX > rail.maxX + 8
                if frame.width > 0, frame.height > 0, frame.minY >= safeTop, frame.maxY <= safeBottom,
                   frame.midX >= viewport.minX + 8, frame.midX <= viewport.maxX - 8,
                   outsideRail, element.isHittable { return true }
                if frame.height > 0, frame.minY < safeTop { scrollDown = false }
            }
            if attempt == 16 { break }
            if scrollDown { lower.press(forDuration: 0.05, thenDragTo: upper) }
            else { upper.press(forDuration: 0.05, thenDragTo: lower) }
        }
        return false
    }
}
