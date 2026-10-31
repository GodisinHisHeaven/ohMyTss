import Foundation
import XCTest
@testable import onMyTss

@MainActor
final class HealthKitBackgroundObserverTests: XCTestCase {
    private enum TestError: Error { case failed }

    func testEveryDeliveryCompletesOnceAfterSuccessFailureAndCancellation() async {
        for mode in 0..<3 {
            var processed = false
            var completions = 0
            await HealthKitBackgroundObserver.processDelivery(onChange: {
                processed = true
                if mode == 1 { throw TestError.failed }
                if mode == 2 { throw CancellationError() }
            }, completion: {
                XCTAssertTrue(processed)
                completions += 1
            })
            XCTAssertEqual(completions, 1)
        }
    }
}
