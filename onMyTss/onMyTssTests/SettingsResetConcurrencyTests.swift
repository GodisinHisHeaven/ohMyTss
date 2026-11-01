#if DEBUG
import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class SettingsResetConcurrencyTests: XCTestCase {
    func testLocalHistoryRepairWaitsForInFlightSourceSync() async throws {
        let fixture = try ResetFixture(count: 1, pauseQuery: true)
        try fixture.store.saveWorkout(fixture.manualWorkout())
        var sourceFinished = false
        let source = Task { defer { sourceFinished = true }; try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.release(); source.cancel() }
        try await waitFor { fixture.health.waiting || sourceFinished }
        XCTAssertTrue(fixture.health.waiting)

        var repairFinished = false
        let repair = Task { defer { repairFinished = true }; try await fixture.runtime.repairLocalWorkoutHistoryIfNeeded() }
        defer { repair.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(repairFinished)
        XCTAssertFalse(try fixture.store.fetchAppState().localWorkoutRepairInProgress)

        fixture.health.release()
        try await source.value
        try await repair.value
        XCTAssertEqual(try fixture.store.fetchAppState().localWorkoutRepairVersion, LocalWorkoutHistoryRepair.currentVersion)
    }

    func testSourceSyncWaitsForInFlightLocalHistoryRepair() async throws {
        let fixture = try ResetFixture(count: 1, pauseQuery: true)
        try fixture.store.saveWorkout(fixture.manualWorkout())
        let gate = LocalRepairGate()
        let repair = Task {
            try await fixture.engine.repairLocalWorkoutHistoryIfNeeded(reconcile: { await gate.wait() })
        }
        defer { gate.release(); repair.cancel(); fixture.health.release() }
        try await waitFor { gate.waiting }
        XCTAssertTrue(fixture.runtime.isProcessing)
        XCTAssertTrue(try fixture.store.fetchAppState().localWorkoutRepairInProgress)

        var sourceFinished = false
        let source = Task { defer { sourceFinished = true }; try await fixture.engine.incrementalUpdate() }
        defer { source.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(sourceFinished)
        XCTAssertFalse(fixture.health.waiting, "Source reads must not begin during local repair")
        gate.release()
        try await repair.value
        try await waitFor { fixture.health.waiting || sourceFinished }
        XCTAssertTrue(fixture.health.waiting)
        fixture.health.release()
        try await source.value
    }

    func testRepairProtectsWorkoutMutationsButFailureDoesNotPermanentlyLockEditing() async throws {
        let fixture = try ResetFixture(count: 0, pauseQuery: false)
        let original = fixture.manualWorkout()
        try fixture.store.saveWorkout(original)
        let gate = LocalRepairGate()
        let repair = Task {
            try await fixture.engine.repairLocalWorkoutHistoryIfNeeded(reconcile: {
                await gate.wait()
                throw LocalRepairTestError.failed
            })
        }
        defer { gate.release(); repair.cancel() }
        try await waitFor { gate.waiting }
        XCTAssertThrowsError(try fixture.store.deleteWorkout(original)) { error in
            guard case .localRepairInProgress? = error as? WorkoutMutationError else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try V2Store(context: fixture.context).createStrengthSession(start: Date().addingTimeInterval(-60), duration: 30))
        XCTAssertFalse(original.isTombstoned)
        gate.release()
        do { try await repair.value; XCTFail("Injected failure must propagate") }
        catch LocalRepairTestError.failed { }
        XCTAssertTrue(try fixture.store.fetchAppState().localWorkoutRepairInProgress)
        // Durable retry state does not permanently lock user edits.
        try fixture.store.deleteWorkout(original)
        XCTAssertTrue(original.isTombstoned)
    }

    func testDifferentEngineForSameContainerWaitsForLocalRepair() async throws {
        let fixture = try ResetFixture(count: 1, pauseQuery: true)
        try fixture.store.saveWorkout(fixture.manualWorkout())
        let secondStore = onMyTss.DataStore(modelContext: ModelContext(fixture.container))
        let secondEngine = BodyBatteryEngine(healthKitManager: fixture.health, dataStore: secondStore,
                                             stravaAuthManager: ResetToken())
        let gate = LocalRepairGate()
        let repair = Task { try await fixture.engine.repairLocalWorkoutHistoryIfNeeded(reconcile: { await gate.wait() }) }
        defer { gate.release(); repair.cancel(); fixture.health.release() }
        try await waitFor { gate.waiting }
        var sourceFinished = false
        let source = Task { defer { sourceFinished = true }; try await secondEngine.incrementalUpdate() }
        defer { source.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(sourceFinished)
        XCTAssertFalse(fixture.health.waiting)
        gate.release()
        try await repair.value
        try await waitFor { fixture.health.waiting || sourceFinished }
        XCTAssertTrue(fixture.health.waiting)
        fixture.health.release()
        try await source.value
    }

    func testResetWaitsForInFlightHealthKitQueryAndAllowsInterruptedRecovery() async throws {
        let fixture = try ResetFixture(count: 1, pauseQuery: true)
        let saved = fixture.manualWorkout()
        try fixture.store.saveWorkout(saved)
        var finished = false
        let task = Task { defer { finished = true }; try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.release(); task.cancel() }
        try await waitFor { fixture.health.waiting || finished }
        XCTAssertTrue(fixture.health.waiting)
        XCTAssertTrue(fixture.runtime.isProcessing)

        await fixture.viewModel.resetAllData()
        XCTAssertTrue(fixture.viewModel.errorMessage?.contains("Sync is in progress") == true)
        XCTAssertNil(fixture.viewModel.successMessage)
        XCTAssertNotNil(try fixture.store.fetchWorkout(byId: saved.id))

        fixture.health.release()
        try await task.value
        XCTAssertFalse(fixture.runtime.isProcessing)
        let state = try fixture.store.fetchAppState()
        state.isComputationInProgress = true // Persisted interrupted work is not an active task.
        try fixture.context.save()
        await fixture.viewModel.resetAllData()
        XCTAssertNil(fixture.viewModel.errorMessage)
        XCTAssertEqual(fixture.viewModel.successMessage, "All data reset successfully")
        XCTAssertTrue(try fixture.store.allWorkouts().isEmpty)
        XCTAssertFalse(state.isComputationInProgress)
    }

    func testResetWaitsForActualBoundedImportAndPreservesSavedRows() async throws {
        let fixture = try ResetFixture(count: 400, pauseQuery: false)
        var finished = false
        let task = Task { defer { finished = true }; try await fixture.engine.incrementalUpdate() }
        defer { task.cancel() }
        try await waitFor { try fixture.store.allWorkouts().count >= 20 || finished }
        XCTAssertFalse(finished, "The test must exercise a live import batch")
        XCTAssertTrue(fixture.runtime.isProcessing)
        let before = try fixture.store.allWorkouts().count
        XCTAssertGreaterThanOrEqual(before, 20)
        await fixture.viewModel.resetAllData()
        XCTAssertTrue(fixture.viewModel.errorMessage?.contains("Sync is in progress") == true)
        XCTAssertGreaterThanOrEqual(try fixture.store.allWorkouts().count, before)

        task.cancel()
        do { try await task.value } catch is CancellationError { } catch { throw error }
        XCTAssertFalse(fixture.runtime.isProcessing)
        await fixture.viewModel.resetAllData()
        XCTAssertNil(fixture.viewModel.errorMessage)
        XCTAssertTrue(try fixture.store.allWorkouts().isEmpty)
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<1000 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for sync")
    }
}

@MainActor
private final class LocalRepairGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private enum LocalRepairTestError: Error { case failed }

@MainActor
private final class ResetFixture {
    let container: ModelContainer
    let context: ModelContext
    let store: onMyTss.DataStore
    let health: ResetHealthSource
    let engine: BodyBatteryEngine
    let runtime: AppSyncRuntime
    let viewModel: SettingsViewModel

    init(count: Int, pauseQuery: Bool) throws {
        let schema = Schema(AppSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        store = onMyTss.DataStore(modelContext: context)
        health = ResetHealthSource(count: count, pauseQuery: pauseQuery)
        engine = BodyBatteryEngine(healthKitManager: health, dataStore: store, stravaAuthManager: ResetToken())
        let pendingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        runtime = AppSyncRuntime(testEngine: engine, pendingURL: pendingURL)
        viewModel = SettingsViewModel(dataStore: store, engine: runtime)
        let thresholds = try store.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        try store.saveUserThresholds(thresholds)
    }

    func manualWorkout() -> Workout {
        let start = Date().addingTimeInterval(-3600)
        return Workout(id: "saved-before-reset", date: start.startOfDay, startTime: start, duration: 600,
                       workoutType: "Run", tss: 20, calculationMethod: "duration", source: .manual)
    }
}

@MainActor
private final class ResetHealthSource: HealthKitManager {
    private let workouts: [HKWorkout]
    private let pauseQuery: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }

    init(count: Int, pauseQuery: Bool) {
        self.pauseQuery = pauseQuery
        workouts = (0..<count).map { index in
            let start = Date().addingTimeInterval(-Double(index + 1) * 3600)
            return HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        }
        super.init()
    }
    func release() { continuation?.resume(); continuation = nil }
    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        if pauseQuery { await withCheckedContinuation { continuation = $0 } }
        return (workouts, [], HKQueryAnchor(fromValue: 1))
    }
    override func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures { WorkoutFeatures() }
    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] { [] }
}

@MainActor
private final class ResetToken: StravaAuthManaging {
    func getValidAccessToken() async throws -> String { "test-token" }
}
#endif
