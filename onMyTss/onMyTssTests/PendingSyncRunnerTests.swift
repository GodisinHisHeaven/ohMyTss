import Foundation
import XCTest
@testable import onMyTss

@MainActor
final class PendingSyncRunnerTests: XCTestCase {
    func testTwoObserverDeliveriesBeforeRunnerStartsNeedOnePass() async throws {
        try await withStore { store in
            var passes = 0
            let runner = PendingSyncRunner(store: store) { passes += 1; return true }
            // Both callbacks run before either scheduled runner can start.
            let first = try runner.recordChange()
            let second = try runner.recordChange()
            XCTAssertTrue(first.shouldRun)
            XCTAssertTrue(second.shouldRun)
            XCTAssertEqual(first.revision.epoch, second.revision.epoch)
            XCTAssertGreaterThan(second.revision.value, first.revision.value)
            try await runner.run(through: first.revision)
            try await runner.run(through: second.revision)
            XCTAssertEqual(passes, 1)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testQueuedObserverDeliveryRetriesFailedPass() async throws {
        try await withStore { store in
            var passes = 0
            let runner = PendingSyncRunner(store: store) {
                passes += 1
                if passes == 1 { throw ProbeError.failed }
                return true
            }
            let first = try runner.recordChange()
            let second = try runner.recordChange()
            do { try await runner.run(through: first.revision); XCTFail("Failure must propagate") }
            catch ProbeError.failed { } catch { throw error }
            XCTAssertEqual(try store.pendingRevision(), second.revision)
            try await runner.run(through: second.revision)
            XCTAssertEqual(passes, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testQueuedObserverDeliveryRetriesCancelledPass() async throws {
        try await withStore { store in
            let gate = SyncTestGate()
            var passes = 0
            let runner = PendingSyncRunner(store: store) {
                passes += 1
                if passes == 1 { await gate.wait() }
                return true
            }
            let first = try runner.recordChange()
            let second = try runner.recordChange()
            let task = Task { try await runner.run(through: first.revision) }
            defer { task.cancel(); gate.release() }
            try await waitForSyncTestCondition("observer cancellation gate") { gate.isWaiting }
            task.cancel()
            gate.release()
            do { try await task.value; XCTFail("Cancellation must propagate") }
            catch is CancellationError { } catch { throw error }
            XCTAssertEqual(try store.pendingRevision(), second.revision)
            try await runner.run(through: second.revision)
            XCTAssertEqual(passes, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testManualRevisionDrainedByActiveRunAvoidsThirdPass() async throws {
        try await withStore { store in
            let firstGate = SyncTestGate()
            let secondGate = SyncTestGate()
            var passes = 0
            let runner = PendingSyncRunner(store: store) {
                passes += 1
                if passes == 1 { await firstGate.wait() }
                if passes == 2 { await secondGate.wait() }
                return true
            }
            let automatic = Task { try await runner.markAndRun() }
            defer { automatic.cancel(); firstGate.release(); secondGate.release() }
            try await waitForSyncTestCondition("automatic pass") { firstGate.isWaiting }
            let requested = try store.markPending()
            let manual = Task { try await runner.run(through: requested) }
            defer { manual.cancel() }
            firstGate.release()
            try await waitForSyncTestCondition("manual revision pass") { secondGate.isWaiting }
            XCTAssertEqual(passes, 2)
            secondGate.release()
            try await automatic.value
            try await manual.value
            XCTAssertEqual(passes, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testManualRequestRetriesAfterActivePassFails() async throws {
        try await withStore { store in
            let gate = SyncTestGate()
            var passes = 0
            let runner = PendingSyncRunner(store: store) {
                passes += 1
                if passes == 1 { await gate.wait(); throw ProbeError.failed }
                return true
            }
            let automatic = Task { try await runner.markAndRun() }
            defer { automatic.cancel(); gate.release() }
            try await waitForSyncTestCondition("failing automatic pass") { gate.isWaiting }
            let requested = try store.markPending()
            let manual = Task { try await runner.run(through: requested) }
            defer { manual.cancel() }
            gate.release()
            do { try await automatic.value; XCTFail("The automatic failure must propagate") }
            catch ProbeError.failed { } catch { throw error }
            try await manual.value
            XCTAssertEqual(passes, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testManualRevisionWaitsForChangedThresholdToBeApplied() async throws {
        try await withStore { store in
            let gate = SyncTestGate()
            var threshold = 100
            var applied: [Int] = []
            let runner = PendingSyncRunner(store: store) {
                let captured = threshold
                if applied.isEmpty { await gate.wait() }
                applied.append(captured)
                return true
            }
            let automatic = Task { try await runner.markAndRun() }
            defer { automatic.cancel(); gate.release() }
            try await waitForSyncTestCondition("old threshold pass") { gate.isWaiting }
            threshold = 200
            let requested = try store.markPending()
            let manual = Task { try await runner.run(through: requested) }
            defer { manual.cancel() }
            gate.release()
            try await automatic.value
            try await manual.value
            XCTAssertEqual(applied, [100, 200])
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testManualRequestNeverReusesAnotherEpoch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = PendingSyncStore(url: url)
        var passes = 0
        let runner = PendingSyncRunner(store: store) { passes += 1; return true }
        let requested = try store.markPending()
        try await runner.run(through: requested)
        try Data("corrupt".utf8).write(to: url)
        let recovered = try XCTUnwrap(store.pendingRevision())
        XCTAssertNotEqual(requested.epoch, recovered.epoch)
        try await runner.run(through: requested)
        XCTAssertEqual(passes, 2)
        XCTAssertNil(try store.pendingRevision())
    }

    func testManualRequestWithoutActivePassRunsAndIncompleteRetainsPending() async throws {
        try await withStore { store in
            var passes = 0
            let runner = PendingSyncRunner(store: store) { passes += 1; return false }
            let requested = try store.markPending()
            do { try await runner.run(through: requested); XCTFail("Incomplete source must propagate") }
            catch PendingSyncRunner.RunnerError.incomplete { } catch { throw error }
            XCTAssertEqual(passes, 1)
            XCTAssertEqual(try store.pendingRevision(), requested)
        }
    }

    func testCancelledManualPassRetainsItsRevision() async throws {
        try await withStore { store in
            let gate = SyncTestGate()
            let runner = PendingSyncRunner(store: store) { await gate.wait(); return true }
            let requested = try store.markPending()
            let manual = Task { try await runner.run(through: requested) }
            defer { manual.cancel(); gate.release() }
            try await waitForSyncTestCondition("manual cancellation gate") { gate.isWaiting }
            manual.cancel()
            gate.release()
            do { try await manual.value; XCTFail("Cancellation must propagate") }
            catch is CancellationError { } catch { throw error }
            XCTAssertEqual(try store.pendingRevision(), requested)
        }
    }

    func testRecoveryDuringPassDrainsNewEpochBeforeCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let store = PendingSyncStore(url: url)
        let firstGate = SyncTestGate()
        let secondGate = SyncTestGate()
        var passes = 0
        var completions = 0
        let runner = PendingSyncRunner(store: store, onDrained: { completions += 1; return true }) {
            passes += 1
            if passes == 1 { await firstGate.wait() }
            if passes == 2 { await secondGate.wait() }
            return true
        }
        let task = Task { try await runner.markAndRun() }
        defer { task.cancel(); firstGate.release(); secondGate.release() }
        try await waitForSyncTestCondition("first epoch pass") { firstGate.isWaiting }
        let old = try XCTUnwrap(store.pendingRevision())
        try Data("corrupt during sync".utf8).write(to: url)
        let recovered = try XCTUnwrap(store.pendingRevision())
        XCTAssertEqual(old.value, recovered.value)
        XCTAssertNotEqual(old.epoch, recovered.epoch)
        firstGate.release()
        try await waitForSyncTestCondition("recovered epoch pass") { secondGate.isWaiting }
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(try store.pendingRevision(), recovered)
        secondGate.release()
        try await task.value
        XCTAssertEqual(completions, 1)
        XCTAssertNil(try store.pendingRevision())
    }

    func testDrainCallbackWaitsForEveryRevision() async throws {
        try await withStore { store in
            let firstGate = SyncTestGate()
            let secondGate = SyncTestGate()
            var calls = 0
            var drains = 0
            let runner = PendingSyncRunner(store: store, onDrained: { drains += 1; return true }) {
                calls += 1
                if calls == 1 { await firstGate.wait() }
                if calls == 2 { await secondGate.wait() }
                return true
            }
            let task = Task { try await runner.markAndRun() }
            defer { task.cancel(); firstGate.release(); secondGate.release() }
            try await waitForSyncTestCondition("first revision") { firstGate.isWaiting }
            let change = try runner.recordChange()
            XCTAssertFalse(change.shouldRun)
            XCTAssertEqual(try store.pendingRevision(), change.revision)
            firstGate.release()
            try await waitForSyncTestCondition("second revision") { secondGate.isWaiting }
            XCTAssertEqual(drains, 0, "An earlier pass cannot clear a later pending event")
            XCTAssertNotNil(try store.pendingRevision())
            secondGate.release()
            try await task.value
            XCTAssertEqual(drains, 1)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testDrainFailureCreatesPendingRetry() async throws {
        try await withStore { store in
            var drains = 0
            let runner = PendingSyncRunner(store: store, onDrained: {
                drains += 1
                return drains > 1
            }) { true }
            do { try await runner.markAndRun(); XCTFail("A failed completion must retry") }
            catch PendingSyncRunner.RunnerError.incomplete { } catch { throw error }
            XCTAssertNotNil(try store.pendingRevision())
            try await runner.run()
            XCTAssertEqual(drains, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testManualSyncCanRunWithoutReplacingCorruptPendingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-manual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let corrupt = Data("damaged pending marker".utf8)
        try corrupt.write(to: url)
        let store = PendingSyncStore(url: url, moveForRecovery: { _, _ in throw ProbeError.failed })
        var calls = 0
        let runner = PendingSyncRunner(store: store) { calls += 1; return true }
        XCTAssertThrowsError(try store.markPending())
        try await runner.runWithoutStore()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertThrowsError(try store.pendingRevision())
    }

    func testEventDuringSyncIsDrainedAndNotAcknowledgedEarly() async throws {
        try await withStore { store in
            var calls = 0
            let gate = SyncTestGate()
            let runner = PendingSyncRunner(store: store) {
                calls += 1
                if calls == 1 { await gate.wait() }
                return true
            }
            var finished = false
            let first = Task { defer { finished = true }; try Task.checkCancellation(); try await runner.markAndRun() }
            defer { first.cancel(); gate.release() }
            try await waitForSyncTestCondition("first pending sync to reach its gate") { gate.isWaiting || finished }
            if finished {
                try await first.value
                XCTFail("First pending sync completed without reaching its gate")
                return
            }
            let firstRevision = try XCTUnwrap(store.pendingRevision())
            var secondFinished = false
            let second = Task { defer { secondFinished = true }; try Task.checkCancellation(); try await runner.markAndRun() }
            defer { second.cancel() }
            try await waitForSyncTestCondition("concurrent change to be recorded without waiting for the first sync") { secondFinished }
            try await second.value
            let secondRevision = try XCTUnwrap(store.pendingRevision())
            XCTAssertEqual(secondRevision.epoch, firstRevision.epoch)
            XCTAssertGreaterThan(secondRevision.value, firstRevision.value)
            XCTAssertEqual(calls, 1)
            gate.release()
            try await waitForSyncTestCondition("first pending sync to finish after releasing its gate") { finished }
            try await first.value
            XCTAssertEqual(calls, 2)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testFailedPassAndThrownErrorRetainPending() async throws {
        try await withStore { store in
            let incomplete = PendingSyncRunner(store: store) { false }
            do { try await incomplete.markAndRun(); XCTFail("Incomplete work must throw") } catch {}
            let revision = try XCTUnwrap(store.pendingRevision())
            let throwing = PendingSyncRunner(store: store) { throw ProbeError.failed }
            do { try await throwing.run(); XCTFail("Sync errors must propagate") } catch ProbeError.failed {} catch { throw error }
            XCTAssertEqual(try store.pendingRevision(), revision)
            let recovered = PendingSyncRunner(store: store) { true }
            try await recovered.run()
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testCancelledPassCannotAcknowledgeItsRevision() async throws {
        try await withStore { store in
            let gate = SyncTestGate()
            let runner = PendingSyncRunner(store: store) {
                await gate.wait()
                return true
            }
            var finished = false
            let task = Task { defer { finished = true }; try Task.checkCancellation(); try await runner.markAndRun() }
            defer { task.cancel(); gate.release() }
            try await waitForSyncTestCondition("pending sync to reach its cancellation gate") { gate.isWaiting || finished }
            if finished {
                try await task.value
                XCTFail("Pending sync completed without reaching its cancellation gate")
                return
            }
            let revision = try XCTUnwrap(store.pendingRevision())
            task.cancel()
            gate.release()
            try await waitForSyncTestCondition("cancelled pending sync to finish") { finished }
            do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { throw error }
            XCTAssertEqual(try store.pendingRevision(), revision)
        }
    }

    func testStopsAfterThreePassesAndKeepsNewEvent() async throws {
        try await withStore { store in
            var calls = 0
            let runner = PendingSyncRunner(store: store) {
                calls += 1
                try store.markPending()
                return true
            }
            do { try await runner.markAndRun(); XCTFail("Pending work must be reported") }
            catch PendingSyncRunner.RunnerError.pendingChangesRemain {} catch { throw error }
            XCTAssertEqual(calls, 3)
            XCTAssertNotNil(try store.pendingRevision())
        }
    }

    func testManualRequestWaitsAndRunsAnotherPass() async throws {
        try await withStore { store in
            var calls = 0
            let gate = SyncTestGate()
            let runner = PendingSyncRunner(store: store) {
                calls += 1
                if calls == 1 { await gate.wait() }
                return true
            }
            var firstFinished = false
            let first = Task { defer { firstFinished = true }; try Task.checkCancellation(); try await runner.markAndRun() }
            defer { first.cancel(); gate.release() }
            try await waitForSyncTestCondition("first pending sync to reach its manual-sync gate") { gate.isWaiting || firstFinished }
            if firstFinished {
                try await first.value
                XCTFail("First pending sync completed without reaching its manual-sync gate")
                return
            }
            var secondFinished = false
            let second = Task { defer { secondFinished = true }; try Task.checkCancellation(); try await runner.run() }
            defer { second.cancel() }
            await Task.yield()
            XCTAssertEqual(calls, 1)
            gate.release()
            try await waitForSyncTestCondition("both queued sync requests to finish") { firstFinished && secondFinished }
            try await first.value
            try await second.value
            XCTAssertEqual(calls, 2)
        }
    }

    func testWaitTimeoutNamesTheBlockedOperation() async {
        do {
            try await waitForSyncTestCondition("fixture never started", timeout: .milliseconds(20)) { false }
            XCTFail("A stalled condition must fail with a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture never started"), error.localizedDescription)
        }
    }

    func testGateReleaseBeforeWaitDoesNotSuspend() async throws {
        let gate = SyncTestGate()
        gate.release()
        var completed = false
        let task = Task { await gate.wait(); completed = true }
        defer { task.cancel(); gate.release() }
        try await waitForSyncTestCondition("released gate to let a late waiter finish") { completed }
        await task.value
    }

    private func withStore(_ body: (PendingSyncStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-sync-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(PendingSyncStore(url: directory.appendingPathComponent("state.json")))
    }
}

private enum ProbeError: Error { case failed }

/// A release remains effective even if a cancelled task reaches the gate late.
@MainActor
final class SyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        continuation?.resume()
        continuation = nil
    }
}
