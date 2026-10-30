import Foundation
import XCTest
@testable import onMyTss

@MainActor
final class HealthQueryExecutionTests: XCTestCase {
    func testTimeoutStopsQueryAndLaterCallbackIsIgnored() async throws {
        let probe = QueryProbe<Int>()
        do {
            _ = try await HealthQueryExecution.run(timeout: .milliseconds(30)) { finish in
                probe.register(finish)
                return { probe.stopped() }
            }
            XCTFail("The query should time out")
        } catch HealthQueryExecution.QueryError.timedOut { } catch { throw error }
        XCTAssertEqual(probe.stopCount, 1)
        probe.complete(.success(5))
        XCTAssertEqual(probe.stopCount, 1)
    }

    func testCancellationStopsInFlightQueryAndLateCallbackIsIgnored() async throws {
        let probe = QueryProbe<Int>()
        let task = Task {
            try await HealthQueryExecution.run(timeout: .seconds(5)) { finish in
                probe.register(finish)
                return { probe.stopped() }
            }
        }
        try await waitForSyncTestCondition("query to start") { probe.started }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { } catch { throw error }
        XCTAssertEqual(probe.stopCount, 1)
        probe.complete(.success(4))
        XCTAssertEqual(probe.stopCount, 1)
    }

    func testPreCancelledTaskDoesNotStartQuery() async throws {
        let probe = QueryProbe<Int>()
        let task = Task {
            try await HealthQueryExecution.run(timeout: .seconds(5)) { finish in
                probe.register(finish)
                return { probe.stopped() }
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { } catch { throw error }
        XCTAssertFalse(probe.started)
    }

    func testCancellationDuringRegistrationStopsAsSoonAsHandleExists() async throws {
        let probe = QueryProbe<Int>()
        let releaseRegistration = DispatchSemaphore(value: 0)
        let task = Task {
            try await HealthQueryExecution.run(timeout: .seconds(5)) { finish in
                probe.register(finish)
                releaseRegistration.wait()
                return { probe.stopped() }
            }
        }
        let cancel = Task.detached {
            while !probe.started && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            guard !Task.isCancelled else { releaseRegistration.signal(); return }
            task.cancel()
            releaseRegistration.signal()
        }
        defer { task.cancel(); cancel.cancel(); releaseRegistration.signal() }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { } catch { throw error }
        await cancel.value
        XCTAssertEqual(probe.stopCount, 1)
        probe.complete(.success(1))
        XCTAssertEqual(probe.stopCount, 1)
    }

    func testSynchronousCallbackAndRetryAfterTimeout() async throws {
        let first = QueryProbe<Int>()
        do {
            _ = try await HealthQueryExecution.run(timeout: .milliseconds(30)) { finish in
                first.register(finish)
                return { first.stopped() }
            }
            XCTFail("First query should time out")
        } catch HealthQueryExecution.QueryError.timedOut { } catch { throw error }
        let next = QueryProbe<Int>()
        let result = try await HealthQueryExecution.run(timeout: .seconds(1)) { finish in
            next.register(finish)
            finish(.success(42))
            return { next.stopped() }
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(next.stopCount, 1)
        first.complete(.success(99))
    }
}

private nonisolated final class QueryProbe<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var callback: ((Result<Value, Error>) -> Void)?
    nonisolated(unsafe) private var stops = 0
    nonisolated var started: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    nonisolated var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    nonisolated func register(_ callback: @escaping (Result<Value, Error>) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    nonisolated func stopped() { lock.lock(); stops += 1; lock.unlock() }
    nonisolated func complete(_ result: Result<Value, Error>) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(result)
    }
}
