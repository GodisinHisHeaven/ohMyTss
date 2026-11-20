import Foundation

/// Serializes all sync entry points and acknowledges only successfully processed changes.
@MainActor
final class PendingSyncRunner {
    struct RecordedChange {
        let revision: PendingSyncStore.Revision
        let shouldRun: Bool
    }

    enum RunnerError: Error {
        case incomplete
        case pendingChangesRemain
    }

    private let store: PendingSyncStore
    private let sync: () async throws -> Bool
    private let onDrained: () -> Bool
    private var running = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var lastSuccessfulDrain: PendingSyncStore.Revision?
    private let maximumPasses = 3

    init(store: PendingSyncStore, onDrained: @escaping () -> Bool = { true },
         sync: @escaping () async throws -> Bool) {
        self.store = store
        self.sync = sync
        self.onDrained = onDrained
    }

    /// Persist the event before returning to the source, even if another sync is running.
    func markAndRun() async throws {
        let change = try recordChange()
        guard change.shouldRun else { return }
        try await run(through: change.revision)
    }

    /// Persist the revision and indicate whether this caller should start a run.
    /// An existing run will drain the event after its current pass.
    func recordChange() throws -> RecordedChange {
        let revision = try store.markPending()
        return RecordedChange(revision: revision, shouldRun: !running)
    }

    /// A manual request waits its turn and performs its own pass.
    func run() async throws {
        try await withExclusiveAccess { try await drain() }
    }

    /// A reset must wait for the pass and its revision acknowledgement.
    func withExclusiveAccess(_ operation: () async throws -> Void) async throws {
        try await acquire()
        defer { release() }
        try await operation()
    }

    /// A request can reuse a pass that processed its revision while it waited.
    /// Failures and later pending work still require another pass.
    func run(through requested: PendingSyncStore.Revision) async throws {
        try await acquire()
        defer { release() }
        if let drained = lastSuccessfulDrain,
           drained.epoch == requested.epoch, drained.value >= requested.value,
           try store.isAcknowledged(requested), try store.pendingRevision() == nil {
            return
        }
        try await drain()
    }

    private func drain() async throws {
        for _ in 0..<maximumPasses {
            try Task.checkCancellation()
            let revision = try store.pendingRevision()
            let complete = try await sync()
            try Task.checkCancellation()
            guard complete else { throw RunnerError.incomplete }
            if let revision { try store.acknowledge(through: revision) }
            if try store.pendingRevision() == nil {
                // No await between the final pending check and completion:
                // another event cannot interleave on the main actor.
                guard onDrained() else {
                    // A failed publication must remain eligible for retry.
                    try store.markPending()
                    throw RunnerError.incomplete
                }
                lastSuccessfulDrain = revision
                return
            }
        }
        throw RunnerError.pendingChangesRemain
    }

    /// Preserve manual sync even when the retry marker is damaged or unavailable.
    /// This does not read, replace or acknowledge any pending marker.
    func runWithoutStore() async throws {
        try await acquire()
        defer { release() }
        let complete = try await sync()
        try Task.checkCancellation()
        guard complete else { throw RunnerError.incomplete }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard running else { running = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if running { waiters.append((id, continuation)) }
                else {
                    running = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiters.firstIndex(where: { $0.id == id }) {
                    self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
        // Cancellation may race with release handing this task ownership.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if waiters.isEmpty { running = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
