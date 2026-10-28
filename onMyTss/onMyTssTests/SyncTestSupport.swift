import Foundation
import XCTest

private struct SyncTestTimeout: LocalizedError {
    let operation: String
    var errorDescription: String? { "Timed out waiting for \(operation)." }
}

/// Bounded, monotonic polling keeps a regression from hanging the test runner.
@MainActor
func waitForSyncTestCondition(_ operation: String, timeout: Duration = .seconds(10),
                              pollInterval: Duration = .milliseconds(10),
                              condition: @MainActor () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try !condition() {
        guard clock.now < deadline else { throw SyncTestTimeout(operation: operation) }
        try await Task.sleep(for: pollInterval)
    }
}

@MainActor
final class SyncTestSupportTests: XCTestCase {
    func testTimeoutNamesTheBlockedOperation() async {
        do {
            try await waitForSyncTestCondition("fixture never started", timeout: .milliseconds(20)) { false }
            XCTFail("A stalled condition must fail with a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture never started"), error.localizedDescription)
        }
    }
}
