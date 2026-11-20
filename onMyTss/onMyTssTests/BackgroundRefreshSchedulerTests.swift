import XCTest
@testable import onMyTss

@MainActor
final class BackgroundRefreshSchedulerTests: XCTestCase {
    func testRepeatedRecoveryKeepsEarlierRequestAcrossLaunches() async {
        var scheduled: [Date] = []
        var pending = true
        let scheduler = BackgroundRefreshScheduler(hasPendingRequest: { pending }, submitRequest: {
            scheduled.append($0)
            pending = true
        }, sync: {})
        await scheduler.schedule().value
        XCTAssertTrue(scheduled.isEmpty)
        pending = false
        let first = scheduler.schedule()
        let second = scheduler.schedule()
        await first.value
        await second.value
        await scheduler.schedule().value
        XCTAssertEqual(scheduled.count, 1)
    }

    func testDeliveryDuringPendingLookupSchedulesSuccessor() async throws {
        var submissions = 0
        let lookup = SyncTestGate()
        let scheduler = BackgroundRefreshScheduler(hasPendingRequest: {
            await lookup.wait()
            return true
        }, submitRequest: { _ in submissions += 1 }, sync: {})
        let launch = scheduler.schedule()
        defer { lookup.release() }
        try await waitForSyncTestCondition("pending request lookup") { lookup.isWaiting }
        let delivery = scheduler.schedule(afterDelivery: true)
        lookup.release()
        await delivery.value
        await launch.value
        XCTAssertEqual(submissions, 1)
    }

    func testSubmissionFailureCanBeRetried() async {
        var attempts = 0
        let scheduler = BackgroundRefreshScheduler(hasPendingRequest: { false }, submitRequest: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
        }, sync: {})
        await scheduler.schedule().value
        await scheduler.schedule().value
        XCTAssertEqual(attempts, 2)
    }

    func testExpirationCompletesOnceWhileSyncIsSuspended() async throws {
        let gate = SyncTestGate()
        var cancelled = false
        var completions: [Bool] = []
        let execution = BackgroundRefreshExecution(sync: {
            await gate.wait()
            cancelled = Task.isCancelled
        }, completion: { completions.append($0) })
        defer { gate.release() }
        try await waitForSyncTestCondition("refresh to enter query") { gate.isWaiting }
        execution.expire()
        XCTAssertEqual(completions, [false])
        gate.release()
        try await waitForSyncTestCondition("cancelled query to unwind") { cancelled }
        execution.expire()
        XCTAssertEqual(completions, [false])
    }

    func testExpirationAfterSuccessKeepsOriginalResult() async throws {
        var completions: [Bool] = []
        let execution = BackgroundRefreshExecution(sync: {}, completion: { completions.append($0) })
        try await waitForSyncTestCondition("successful refresh") { !completions.isEmpty }
        execution.expire()
        XCTAssertEqual(completions, [true])
    }
}
