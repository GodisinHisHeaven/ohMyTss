import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class LocalWorkoutHistoryRepairTests: XCTestCase {
    private enum ExpectedFailure: Error { case interrupted }

    private func container() throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    func testCompletedVersionDoesNoFurtherWork() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let state = try store.fetchAppState()
        state.localWorkoutRepairVersion = LocalWorkoutHistoryRepair.currentVersion
        try context.save()
        var calls = 0
        let repair = LocalWorkoutHistoryRepair(store: store, reconcile: { calls += 1 },
                                               rebuildLegacy: { _ in calls += 1 },
                                               rebuildEstimates: { calls += 1 })
        try await repair.run()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(state.localWorkoutRepairInProgress)
    }

    func testInterruptedRepairPersistsAndRebuildsEvenWhenRegroupingIsNowUnchanged() async throws {
        let container = try container()
        let context = ModelContext(container)
        let store = DataStore(modelContext: context)
        let state = try store.fetchAppState()
        var phases: [String] = []
        let first = LocalWorkoutHistoryRepair(store: store, reconcile: {
            XCTAssertTrue(state.localWorkoutRepairInProgress)
            phases.append("reconcile")
        }, hasSavedHistory: { true }, rebuildLegacy: { _ in phases.append("legacy") }, rebuildEstimates: {
            phases.append("estimates")
            throw ExpectedFailure.interrupted
        })
        do { try await first.run(); XCTFail("Failure must remain visible") }
        catch ExpectedFailure.interrupted { }
        XCTAssertEqual(phases, ["reconcile", "legacy", "estimates"])
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<AppState>()).first)
        XCTAssertTrue(persisted.localWorkoutRepairInProgress)
        XCTAssertEqual(persisted.localWorkoutRepairVersion, 0)

        phases.removeAll()
        let retry = LocalWorkoutHistoryRepair(store: store, reconcile: { phases.append("reconcile") },
                                               hasSavedHistory: { true },
                                               rebuildLegacy: { _ in phases.append("legacy") },
                                               rebuildEstimates: { phases.append("estimates") })
        try await retry.run()
        XCTAssertEqual(phases, ["reconcile", "legacy", "estimates"])
        XCTAssertFalse(state.localWorkoutRepairInProgress)
        XCTAssertEqual(state.localWorkoutRepairVersion, LocalWorkoutHistoryRepair.currentVersion)
    }

    func testInterruptedSourceImportIsNotFinalizedByOfflineRepair() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let state = try store.fetchAppState()
        state.isComputationInProgress = true
        try context.save()
        var called = false
        let repair = LocalWorkoutHistoryRepair(store: store, reconcile: { called = true })
        do { try await repair.run(); XCTFail("Partial source imports require source recovery") }
        catch LocalWorkoutHistoryRepair.RepairError.sourceRecoveryPending { }
        XCTAssertFalse(called)
        XCTAssertTrue(state.isComputationInProgress)
        XCTAssertEqual(state.localWorkoutRepairVersion, 0)
    }

    func testCancellationRetainsDurableRepairMarker() async throws {
        let container = try container()
        let context = ModelContext(container)
        let store = DataStore(modelContext: context)
        let repair = LocalWorkoutHistoryRepair(store: store, reconcile: { throw CancellationError() },
                                               hasSavedHistory: { true })
        do { try await repair.run(); XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<AppState>()).first)
        XCTAssertTrue(persisted.localWorkoutRepairInProgress)
        XCTAssertEqual(persisted.localWorkoutRepairVersion, 0)
    }

    func testFreshInstallDoesNotCreateEmptyAggregate() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        var called = false
        let repair = LocalWorkoutHistoryRepair(store: store, reconcile: { called = true })
        try await repair.run()
        XCTAssertFalse(called)
        XCTAssertTrue(try store.fetchAllDayAggregates().isEmpty)
        XCTAssertEqual(try store.fetchAppState().localWorkoutRepairVersion, LocalWorkoutHistoryRepair.currentVersion)
    }

    func testOfflineRepairResumesAfterGroupingAndPreservesAliasDetails() async throws {
        let container = try container()
        let context = ModelContext(container)
        let store = DataStore(modelContext: context)
        let start = Date().addingTimeInterval(-3600)
        let garmin = Workout(id: "garmin", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Ride", tss: 25, calculationMethod: "duration", source: .healthKit)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let alias = Workout(id: "strava", date: start.startOfDay, startTime: start, duration: 600,
                            workoutType: "Ride", tss: 35, calculationMethod: "duration", source: .strava)
        alias.userTags = ["standing"]
        let set = StrengthSetRecord(sessionID: alias.id, exerciseID: "squat", reps: 5)
        let day = DayAggregate(date: start.startOfDay, totalTSS: 60, workoutCount: 2)
        day.hasWorkoutDetails = true
        context.insert(garmin); context.insert(alias); context.insert(set); context.insert(day)
        let state = try store.fetchAppState()
        let previousSync = start.addingTimeInterval(-60)
        state.lastComputationDate = previousSync
        try context.save()

        let interrupted = LocalWorkoutHistoryRepair(store: store, reconcile: {
            _ = try await store.repairWorkoutSourcesLocally()
        }, rebuildLegacy: { _ in throw ExpectedFailure.interrupted }, clock: { start.addingTimeInterval(1200) })
        do { try await interrupted.run(); XCTFail("Interrupted aggregate rebuild must not finish") }
        catch ExpectedFailure.interrupted { }
        XCTAssertTrue(state.localWorkoutRepairInProgress)
        XCTAssertTrue(alias.isSuppressed)
        XCTAssertEqual(day.totalTSS, 60, "Persisted marker must prevent incomplete totals being considered final")

        let reopened = ModelContext(container)
        let reopenedStore = DataStore(modelContext: reopened)
        let resumed = LocalWorkoutHistoryRepair(store: reopenedStore, reconcile: {
            _ = try await reopenedStore.repairWorkoutSourcesLocally()
        }, clock: { start.addingTimeInterval(1200) })
        try await resumed.run()
        let repairedState = try reopenedStore.fetchAppState()
        XCTAssertFalse(repairedState.localWorkoutRepairInProgress)
        XCTAssertEqual(repairedState.lastComputationDate, previousSync, "Local work must not advance a source cursor")
        let active = try reopenedStore.fetchWorkouts(from: start, to: start)
        XCTAssertEqual(active.map(\.id), ["garmin"])
        XCTAssertEqual(try reopenedStore.fetchDayAggregate(for: start)?.totalTSS, 25)
        XCTAssertEqual(try reopenedStore.fetchDayAggregate(for: start)?.workoutCount, 1)
        let retainedSet = try XCTUnwrap(reopened.fetch(FetchDescriptor<StrengthSetRecord>()).first)
        let retainedAlias = try XCTUnwrap(reopenedStore.fetchWorkout(byId: "strava"))
        XCTAssertEqual(retainedSet.sessionID, retainedAlias.id)
        XCTAssertEqual(retainedAlias.userTags, ["standing"])
        XCTAssertEqual(retainedAlias.linkedSessionID, "garmin")
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<LoadEstimateRecord>()).filter { $0.sessionID == "garmin" }.count, 1)
    }

    func testEstimateRefreshCanLeaveAliasChildrenWithTheirOriginalSession() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let canonical = Workout(id: "garmin", date: now.startOfDay, startTime: now, duration: 600,
                                workoutType: "Strength", tss: 20, calculationMethod: "duration", source: .healthKit)
        let alias = Workout(id: "other", date: now.startOfDay, startTime: now, duration: 600,
                            workoutType: "Strength", tss: 20, calculationMethod: "duration", source: .strava)
        alias.isSuppressed = true
        alias.linkedSessionID = canonical.id
        let child = StrengthSetRecord(sessionID: alias.id, exerciseID: "squat", reps: 5)
        context.insert(canonical); context.insert(alias); context.insert(child)
        try context.save()
        try await store.refreshV2Estimates()
        XCTAssertEqual(child.sessionID, alias.id)
    }

    func testLinkedAliasDetailsStayVisibleAndReturnToSourceAfterSplit() throws {
        let context = ModelContext(try container())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let now = start.addingTimeInterval(3600)
        let canonical = Workout(id: "garmin", date: start.startOfDay, startTime: start, duration: 1800,
                                workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .healthKit)
        let alias = Workout(id: "source-alias", date: start.startOfDay, startTime: start, duration: 1800,
                            workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .strava)
        alias.isSuppressed = true
        alias.linkedSessionID = canonical.id
        alias.userTags = ["standing"]
        let child = StrengthSetRecord(sessionID: alias.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        context.insert(canonical); context.insert(alias); context.insert(child)
        try context.save()

        let combined = MuscleRPESummary(records: [], workouts: [canonical, alias], sets: [child], now: now)
        XCTAssertNotNil(combined.reading(.core, side: .left), "Alias standing tag contributes to its current group")
        XCTAssertEqual(combined.reading(.chest, side: .left)?.source, .sets)
        let before = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: now)
        let canonicalBefore = try XCTUnwrap(before.first { $0.sessionID == canonical.id })
        let beforeInput = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalBefore.inputData) as? [String: Any])
        XCTAssertEqual(beforeInput["tags"] as? [String], ["standing"])
        alias.isTombstoned = true
        alias.deletionOrigin = "source"
        let deletedAliasSummary = MuscleRPESummary(records: [], workouts: [canonical, alias], sets: [child], now: now)
        XCTAssertEqual(deletedAliasSummary.reading(.chest, side: .left)?.source, .sets)
        let afterSourceDeletion = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: now)
        let retainedInput = try XCTUnwrap(afterSourceDeletion.first { $0.sessionID == canonical.id })
        let retainedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: retainedInput.inputData) as? [String: Any])
        XCTAssertEqual(retainedJSON["tags"] as? [String], ["standing"])

        // A later source correction breaks the link; user data stays with the
        // original source and must not follow the previous canonical row.
        alias.linkedSessionID = nil
        alias.isSuppressed = false
        alias.isTombstoned = false
        alias.deletionOrigin = nil
        try context.save()
        XCTAssertEqual(child.sessionID, alias.id)
        let after = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: now)
        let canonicalAfter = try XCTUnwrap(after.first { $0.sessionID == canonical.id })
        let aliasAfter = try XCTUnwrap(after.first { $0.sessionID == alias.id })
        let canonicalInput = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalAfter.inputData) as? [String: Any])
        let aliasInput = try XCTUnwrap(JSONSerialization.jsonObject(with: aliasAfter.inputData) as? [String: Any])
        XCTAssertEqual(canonicalInput["tags"] as? [String], [])
        XCTAssertEqual(aliasInput["tags"] as? [String], ["standing"])
        let originalOnly = MuscleRPESummary(records: [], workouts: [canonical], sets: [child], now: now)
        XCTAssertNil(originalOnly.reading(.core, side: .left))
        XCTAssertNil(originalOnly.reading(.chest, side: .left))
    }

    func testConflictingSourceOwnedLabelsAreUnknownUntilGroupSplits() throws {
        let context = ModelContext(try container())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let now = start.addingTimeInterval(3600)
        let garmin = Workout(id: "garmin", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .healthKit)
        let alias = Workout(id: "strava", date: start.startOfDay, startTime: start, duration: 600,
                            workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .strava)
        garmin.userTags = ["seated"]
        alias.userTags = ["standing"]
        alias.isSuppressed = true
        alias.linkedSessionID = garmin.id
        context.insert(garmin); context.insert(alias)
        try context.save()
        let combined = MuscleRPESummary(records: [], workouts: [garmin, alias], now: now)
        XCTAssertNil(combined.reading(.core, side: .left), "Conflicting posture labels cannot establish standing")
        let before = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: now)
        let row = try XCTUnwrap(before.first { $0.sessionID == garmin.id })
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: row.inputData) as? [String: Any])
        XCTAssertEqual(input["tags"] as? [String], [])
        XCTAssertEqual(garmin.userTags, ["seated"])
        XCTAssertEqual(alias.userTags, ["standing"])
        XCTAssertEqual(WorkoutTagProjection.merged([["freestyle", "paddles"], ["backstroke"]]), ["paddles"])

        alias.linkedSessionID = nil
        alias.isSuppressed = false
        try context.save()
        let after = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: now)
        let split = try XCTUnwrap(after.first { $0.sessionID == alias.id })
        let splitInput = try XCTUnwrap(JSONSerialization.jsonObject(with: split.inputData) as? [String: Any])
        XCTAssertEqual(splitInput["tags"] as? [String], ["standing"])
    }
    func testCompletedSourceFinalizationThenCorrectionKeepsPersonalRecordsOnOriginalSource() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let garmin = Workout(id: "garmin-final", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .healthKit)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let strava = Workout(id: "strava-final", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .strava)
        strava.userTags = ["standing"]
        let set = StrengthSetRecord(sessionID: strava.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 1,
                                           observedAt: start, sessionID: strava.id)
        context.insert(set); context.insert(observation)
        try store.saveWorkouts([garmin, strava])
        _ = try store.finalizeWorkoutSources()
        try await store.refreshV2Estimates()
        XCTAssertEqual(strava.linkedSessionID, garmin.id)
        XCTAssertEqual(strava.userTags, ["standing"])
        XCTAssertEqual(set.sessionID, strava.id)
        XCTAssertEqual(observation.sessionID, strava.id)
        let merged = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: start.addingTimeInterval(7200))
        let mergedRow = try XCTUnwrap(merged.first { $0.sessionID == garmin.id })
        let mergedInput = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedRow.inputData) as? [String: Any])
        XCTAssertEqual(mergedInput["tags"] as? [String], ["standing"])
        XCTAssertEqual((mergedInput["sets"] as? [[String: Any]])?.count, 1)

        let correctedStart = start.addingTimeInterval(3600)
        let correction = Workout(id: strava.id, date: correctedStart.startOfDay, startTime: correctedStart,
                                 duration: 600, workoutType: "Ride", tss: 20,
                                 calculationMethod: "duration", source: .strava)
        try store.saveWorkouts([correction])
        _ = try store.finalizeWorkoutSources()
        try await store.refreshV2Estimates()
        XCTAssertNil(strava.linkedSessionID)
        XCTAssertEqual(strava.userTags, ["standing"])
        XCTAssertEqual(set.sessionID, strava.id)
        XCTAssertEqual(observation.sessionID, strava.id)
        let split = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: start.addingTimeInterval(7200))
        let first = try XCTUnwrap(split.first { $0.sessionID == garmin.id })
        let second = try XCTUnwrap(split.first { $0.sessionID == strava.id })
        let firstInput = try XCTUnwrap(JSONSerialization.jsonObject(with: first.inputData) as? [String: Any])
        let secondInput = try XCTUnwrap(JSONSerialization.jsonObject(with: second.inputData) as? [String: Any])
        XCTAssertEqual(firstInput["tags"] as? [String], [])
        XCTAssertEqual((firstInput["sets"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(secondInput["tags"] as? [String], ["standing"])
        XCTAssertEqual((secondInput["sets"] as? [[String: Any]])?.count, 1)
    }

    func testUserDeletedAliasAndItsDescendantsDoNotContributeToActiveGroup() throws {
        let context = ModelContext(try container())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let canonical = Workout(id: "active", date: start.startOfDay, startTime: start, duration: 600,
                                workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .healthKit)
        let alias = Workout(id: "deleted", date: start.startOfDay, startTime: start, duration: 600,
                            workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .strava)
        alias.linkedSessionID = canonical.id; alias.isSuppressed = true
        alias.isTombstoned = true; alias.deletionOrigin = "user"; alias.userTags = ["standing"]
        let child = Workout(id: "descendant", date: start.startOfDay, startTime: start, duration: 600,
                            workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .manual)
        child.linkedSessionID = alias.id; child.isSuppressed = true; child.userTags = ["standing"]
        let firstSet = StrengthSetRecord(sessionID: alias.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        let secondSet = StrengthSetRecord(sessionID: child.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        context.insert(canonical); context.insert(alias); context.insert(child)
        context.insert(firstSet); context.insert(secondSet); try context.save()
        let rows = try V2EstimateBatch(context: context, includePrevious: false).calculate(now: start.addingTimeInterval(3600))
        let row = try XCTUnwrap(rows.first { $0.sessionID == canonical.id })
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: row.inputData) as? [String: Any])
        XCTAssertEqual(input["tags"] as? [String], [])
        XCTAssertEqual((input["sets"] as? [[String: Any]])?.count, 0)
        let summary = MuscleRPESummary(records: [], workouts: [canonical, alias, child], sets: [firstSet, secondSet], now: start.addingTimeInterval(3600))
        XCTAssertNil(summary.reading(.chest, side: .left))
        XCTAssertNil(summary.reading(.core, side: .left))
    }

    func testMuscleSourceWindowIncludesSixtySecondAlias() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cutoff = MuscleRPESummary.cutoff(for: now)
        let sourceCutoff = MuscleRPESummary.sourceCutoff(for: now)
        XCTAssertEqual(cutoff.timeIntervalSince(sourceCutoff), 60)
        let canonical = Workout(id: "window-active", date: cutoff.startOfDay, startTime: cutoff, duration: 600,
                                workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .healthKit)
        let alias = Workout(id: "window-alias", date: sourceCutoff.startOfDay, startTime: sourceCutoff, duration: 600,
                            workoutType: "Ride", tss: 20, calculationMethod: "duration", source: .strava)
        alias.linkedSessionID = canonical.id; alias.isSuppressed = true
        let sourceSet = StrengthSetRecord(sessionID: alias.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        let queried = [canonical, alias].filter { $0.startTime >= sourceCutoff }
        XCTAssertEqual(Set(queried.map(\.id)), [canonical.id, alias.id])
        let summary = MuscleRPESummary(records: [], workouts: queried, sets: [sourceSet], now: now)
        XCTAssertEqual(summary.reading(.chest, side: .left)?.source, .sets)
    }

    func testExplicitRetryOnlySynchronizesWhenSourceRecoveryIsPending() async throws {
        let state = AppState()
        var syncs = 0
        var repairs = 0
        try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: { syncs += 1 }, repair: { repairs += 1 })
        XCTAssertEqual(syncs, 0)
        XCTAssertEqual(repairs, 1)
        state.isComputationInProgress = true
        try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: {
            syncs += 1
            state.isComputationInProgress = false
        }, repair: { repairs += 1 })
        XCTAssertEqual(syncs, 1)
        XCTAssertEqual(repairs, 2)
        state.pendingWorkoutSourceFinalization = true
        do {
            try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: { syncs += 1 }, repair: { repairs += 1 })
            XCTFail("An incomplete source recovery must retain the warning")
        } catch LocalWorkoutHistoryRepair.RepairError.sourceRecoveryPending { }
        XCTAssertEqual(repairs, 2)
        do {
            try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: { throw ExpectedFailure.interrupted }, repair: { repairs += 1 })
            XCTFail("Source failure must propagate")
        } catch ExpectedFailure.interrupted { }
        XCTAssertEqual(repairs, 2)
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        // Source recovery can succeed while the runtime correctly leaves its
        // widget revision pending until the local repair completes.
        try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: {
            state.pendingWorkoutSourceFinalization = false
            throw PendingSyncRunner.RunnerError.incomplete
        }, repair: { repairs += 1 })
        XCTAssertEqual(repairs, 3)
        state.pendingWorkoutSourceFinalization = true
        do {
            try await LocalWorkoutHistoryRepair.retry(state: state, synchronize: {
                throw PendingSyncRunner.RunnerError.incomplete
            }, repair: { repairs += 1 })
            XCTFail("An incomplete source must not be mistaken for a deferred widget")
        } catch PendingSyncRunner.RunnerError.incomplete { }
        XCTAssertEqual(repairs, 3)
    }

    func testExplicitRetryWaitsForExistingSyncWithoutDuplicatingIt() async throws {
        let state = AppState(isComputationInProgress: true)
        var checks = 0
        var syncs = 0
        var repairs = 0
        try await LocalWorkoutHistoryRepair.retry(state: state, isProcessing: {
            checks += 1
            if checks == 1 { return true }
            state.isComputationInProgress = false
            return false
        }, synchronize: { syncs += 1 }, repair: { repairs += 1 })
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertEqual(syncs, 0)
        XCTAssertEqual(repairs, 1)
    }

}
