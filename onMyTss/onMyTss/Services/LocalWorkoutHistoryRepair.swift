import Foundation

/// Serializes source imports and local repair across engine instances that use
/// the same container. All access is confined to the main actor.
@MainActor
enum WorkoutMaintenanceGate {
    enum Kind: Equatable { case sourceSync, localRepair }
    private static var active: [ObjectIdentifier: Kind] = [:]

    static func acquire(_ key: ObjectIdentifier, kind: Kind) async throws {
        while active[key] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        active[key] = kind
    }

    static func release(_ key: ObjectIdentifier) { active[key] = nil }
    static func isRepairing(_ key: ObjectIdentifier) -> Bool { active[key] == .localRepair }
}

/// Coordinates a durable local-only repair. The caller must hold the same
/// engine serialization used by source sync for the entire operation.
@MainActor
final class LocalWorkoutHistoryRepair {
    static let currentVersion = 1

    static func isRequired(_ state: AppState) -> Bool {
        state.localWorkoutRepairInProgress || state.localWorkoutRepairVersion < currentVersion
    }

    /// Only an explicit retry may request a source recovery. Ordinary launch
    /// remains local-only and never initiates network work on its own.
    static func retry(state: AppState, isProcessing: @MainActor () -> Bool = { false },
                      synchronize: @MainActor () async throws -> Void,
                      repair: @MainActor () async throws -> Void) async throws {
        while isProcessing() {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        if state.isComputationInProgress || state.pendingWorkoutSourceFinalization {
            do {
                try await synchronize()
            } catch PendingSyncRunner.RunnerError.incomplete
                where !state.isComputationInProgress && !state.pendingWorkoutSourceFinalization {
                // Runtime also reports an incomplete pass when widget
                // publication is intentionally held for this repair. Source
                // markers are already saved; leave its pending revision intact.
            }
            guard !state.isComputationInProgress && !state.pendingWorkoutSourceFinalization else {
                throw RepairError.sourceRecoveryPending
            }
        }
        try await repair()
    }

    enum RepairError: LocalizedError {
        case sourceRecoveryPending

        var errorDescription: String? {
            switch self {
            case .sourceRecoveryPending:
                return "Workout history needs an interrupted sync to finish before it can be repaired."
            }
        }
    }

    private let store: DataStore
    private let hasSavedHistory: @MainActor () throws -> Bool
    private let reconcile: @MainActor () async throws -> Void
    private let rebuildLegacy: @MainActor (Date) async throws -> Void
    private let rebuildEstimates: @MainActor () async throws -> Void
    private let clock: () -> Date

    init(store: DataStore,
         reconcile: @escaping @MainActor () async throws -> Void,
         hasSavedHistory: (@MainActor () throws -> Bool)? = nil,
         rebuildLegacy: (@MainActor (Date) async throws -> Void)? = nil,
         rebuildEstimates: (@MainActor () async throws -> Void)? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.hasSavedHistory = hasSavedHistory ?? { try store.hasSavedTrainingHistory() }
        self.reconcile = reconcile
        self.rebuildLegacy = rebuildLegacy ?? { try await store.refreshLegacyLoadHistory(from: nil, now: $0) }
        // Local repair must not migrate user-authored children between aliases.
        self.rebuildEstimates = rebuildEstimates ?? { try await store.refreshV2Estimates() }
        self.clock = clock
    }

    /// Repeats all derived work after interruption, including when a previous
    /// attempt already saved every grouping change before it was canceled.
    func run() async throws {
        let state = try store.fetchAppState()
        guard Self.isRequired(state) else { return }
        // The import marker can represent a partially persisted source batch.
        // Offline maintenance must not make its provisional data look final.
        guard !state.isComputationInProgress else { throw RepairError.sourceRecoveryPending }
        try Task.checkCancellation()
        if try !hasSavedHistory() {
            // A new installation has no totals to repair. In particular, do
            // not ask the legacy rebuilder to synthesize an empty day.
            let previousVersion = state.localWorkoutRepairVersion
            let wasInProgress = state.localWorkoutRepairInProgress
            state.localWorkoutRepairVersion = Self.currentVersion
            state.localWorkoutRepairInProgress = false
            do { try store.saveAppState(state) }
            catch {
                state.localWorkoutRepairVersion = previousVersion
                state.localWorkoutRepairInProgress = wasInProgress
                throw error
            }
            return
        }
        if !state.localWorkoutRepairInProgress {
            state.localWorkoutRepairInProgress = true
            do { try store.saveAppState(state) }
            catch {
                state.localWorkoutRepairInProgress = false
                throw error
            }
        }
        try await reconcile()
        try Task.checkCancellation()
        try await rebuildLegacy(clock())
        try Task.checkCancellation()
        try await rebuildEstimates()
        try Task.checkCancellation()
        guard !state.isComputationInProgress else { throw RepairError.sourceRecoveryPending }
        let previousVersion = state.localWorkoutRepairVersion
        state.localWorkoutRepairVersion = Self.currentVersion
        state.localWorkoutRepairInProgress = false
        do {
            try store.saveAppState(state)
        } catch {
            // A failed save must also remain retryable in this live context.
            state.localWorkoutRepairVersion = previousVersion
            state.localWorkoutRepairInProgress = true
            throw error
        }
    }
}
