import XCTest
@testable import onMyTss

@MainActor
final class AutoSyncCoordinatorTests: XCTestCase {
    func testFirstSyncThenThrottleUntilFifteenMinutes() async {
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: nil)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 1)
        clock.advance(899)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 1)
        clock.advance(1)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 2)
    }

    func testPersistedLastComputationPreventsSyncAfterRelaunch() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(calendar: calendar, clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: clock.now.addingTimeInterval(-60))
        XCTAssertEqual(calls, 0)
        await coordinator.requestIfNeeded(lastComputation: clock.now.addingTimeInterval(-900))
        XCTAssertEqual(calls, 1)
    }

    func testPersistedLastComputationAcrossLocalMidnightRunsAfterRelaunch() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(calendar: calendar, clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: clock.now.addingTimeInterval(-60))
        XCTAssertEqual(calls, 1)
    }

    func testNewLocalDayRunsBeforeFifteenMinutes() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let clock = TestClock(now: midnight.addingTimeInterval(-30))
        var calls = 0
        let coordinator = AutoSyncCoordinator(calendar: calendar, clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: nil)
        clock.advance(60)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 2)
    }

    func testDataChangeIsLimitedToOncePerMinute() async {
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: nil)
        clock.advance(59)
        await coordinator.requestIfNeeded(lastComputation: nil, force: true)
        XCTAssertEqual(calls, 1)
        clock.advance(1)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 2)
    }

    func testFailedSyncBacksOffEvenForDataChangesThenRetries() async {
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) {
            calls += 1
            if calls == 1 { throw TestError.failed }
        }

        await coordinator.requestIfNeeded(lastComputation: nil)
        clock.advance(299)
        await coordinator.requestIfNeeded(lastComputation: nil, force: true)
        XCTAssertEqual(calls, 1)
        clock.advance(1)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentRequestsDoNotStartAnotherSync() async throws {
        let clock = TestClock()
        var calls = 0
        let gate = SyncTestGate()
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) {
            calls += 1
            if calls == 1 { await gate.wait() }
        }
        var finished = false
        let first = Task {
            defer { finished = true }
            guard !Task.isCancelled else { return }
            await coordinator.requestIfNeeded(lastComputation: nil)
        }
        defer { first.cancel(); gate.release() }
        try await waitForSyncTestCondition("automatic sync to reach its concurrent-request gate") { gate.isWaiting || finished }
        guard gate.isWaiting else {
            XCTFail("Automatic sync completed without reaching its concurrent-request gate")
            return
        }
        await coordinator.requestIfNeeded(lastComputation: nil, force: true)
        XCTAssertEqual(calls, 1)
        gate.release()
        try await waitForSyncTestCondition("automatic sync to finish after releasing its gate") { finished }
        await first.value
        clock.advance(59)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 1)
        clock.advance(1)
        await coordinator.requestIfNeeded(lastComputation: nil)
        XCTAssertEqual(calls, 2)
    }

    func testFailedPendingChangeRetriesAfterBackoffDespiteRecentComputation() async {
        let clock = TestClock()
        let lastComputation = clock.now.addingTimeInterval(-60)
        var calls = 0
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) {
            calls += 1
            if calls == 1 { throw TestError.failed }
        }
        await coordinator.requestIfNeeded(lastComputation: lastComputation, force: true)
        clock.advance(300)
        await coordinator.requestIfNeeded(lastComputation: lastComputation)
        XCTAssertEqual(calls, 2)
    }

    func testFuturePersistedTimestampDoesNotBlockSync() async {
        let clock = TestClock()
        var calls = 0
        let coordinator = AutoSyncCoordinator(clock: { clock.now }) { calls += 1 }

        await coordinator.requestIfNeeded(lastComputation: clock.now.addingTimeInterval(3600))
        XCTAssertEqual(calls, 1)
    }
}

private final class TestClock {
    var now: Date
    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(_ interval: TimeInterval) { now.addTimeInterval(interval) }
}

private enum TestError: Error { case failed }
