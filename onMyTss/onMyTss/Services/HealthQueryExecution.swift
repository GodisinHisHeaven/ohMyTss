import Foundation

/// Coordinates a single callback, task cancellation and a bounded wait.
/// `start` returns a stop function after registering the underlying query.
@MainActor
enum HealthQueryExecution {
    enum QueryError: Error, Equatable { case timedOut }

    static func run<Value>(timeout: Duration = .seconds(15),
                           start: (@escaping (Result<Value, Error>) -> Void) -> (() -> Void)) async throws -> Value {
        let gate = HealthQueryGate<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let timer = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    gate.finish(.failure(QueryError.timedOut))
                }
                gate.installTimer(timer)
                guard !Task.isCancelled, gate.reserveStart() else {
                    gate.finish(.failure(CancellationError()))
                    return
                }
                let stop = start { result in gate.finish(result) }
                // Cancellation may win while start is registering; then the
                // query is stopped immediately after its stop function exists.
                gate.installStop(stop)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

private nonisolated final class HealthQueryGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<Value, Error>?
    nonisolated(unsafe) private var result: Result<Value, Error>?
    nonisolated(unsafe) private var timer: Task<Void, Never>?
    nonisolated(unsafe) private var stop: (() -> Void)?

    nonisolated init() {}

    nonisolated func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    nonisolated func reserveStart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }

    nonisolated func installTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); timer.cancel(); return }
        self.timer = timer
        lock.unlock()
    }

    nonisolated func installStop(_ stop: @escaping () -> Void) {
        lock.lock()
        if result != nil { lock.unlock(); stop(); return }
        self.stop = stop
        lock.unlock()
    }

    nonisolated func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        let stop = self.stop
        self.stop = nil
        lock.unlock()
        timer?.cancel()
        stop?()
        continuation?.resume(with: result)
    }
}
