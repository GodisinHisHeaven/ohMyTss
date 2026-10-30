import Foundation

/// Serializes all sync entry points and acknowledges only successfully processed changes.
@MainActor
final class PendingSyncRunner {
    enum RunnerError: Error {
        case incomplete
        case pendingChangesRemain
    }

    private let store: PendingSyncStore
    private let sync: () async throws -> Bool
    private let onDrained: () -> Bool
    private var running = false
    private let maximumPasses = 3

    init(store: PendingSyncStore, onDrained: @escaping () -> Bool = { true },
         sync: @escaping () async throws -> Bool) {
        self.store = store
        self.sync = sync
        self.onDrained = onDrained
    }

    /// Persist the event before returning to the source, even if another sync is running.
    func markAndRun() async throws {
        guard try recordChange() else { return }
        try await run()
    }

    /// Returns whether this caller should start a run; an existing run will
    /// drain the newly persisted event when it finishes its current pass.
    func recordChange() throws -> Bool {
        try store.markPending()
        return !running
    }

    /// A manual request waits its turn and performs its own pass.
    func run() async throws {
        try await acquire()
        defer { running = false }

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
                return
            }
        }
        throw RunnerError.pendingChangesRemain
    }

    /// Preserve manual sync even when the retry marker is damaged or unavailable.
    /// This does not read, replace or acknowledge any pending marker.
    func runWithoutStore() async throws {
        try await acquire()
        defer { running = false }
        let complete = try await sync()
        try Task.checkCancellation()
        guard complete else { throw RunnerError.incomplete }
    }

    private func acquire() async throws {
        while running {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        running = true
    }
}
