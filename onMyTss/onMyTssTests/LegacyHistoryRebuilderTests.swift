import XCTest
import SwiftData
@testable import onMyTss

/// Synthetic stores only; batch interleavings do not depend on scheduler timing.
@MainActor
final class LegacyHistoryRebuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000).startOfDay

    private func context(url: URL? = nil) throws -> ModelContext {
        let schema = Schema(AppSchema.models)
        let config = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    @discardableResult
    private func workout(_ context: ModelContext, id: String, daysAgo: Int, tss: Double = 100) -> Workout {
        let date = now.addingDays(-daysAgo)
        let row = Workout(id: id, date: date, startTime: date, duration: 600,
                          workoutType: "Strength", tss: tss, calculationMethod: "synthetic", source: .manual)
        context.insert(row)
        return row
    }

    private func values(_ store: onMyTss.DataStore) throws -> [[Double]] {
        try store.fetchAllDayAggregates().map {
            [$0.date.timeIntervalSince1970, $0.totalTSS, $0.ctl, $0.atl, $0.tsb,
             Double($0.bodyBatteryScore), $0.rampRate ?? -999, Double($0.workoutCount)]
        }
    }

    private func assertMatchesFreshRebuild(_ store: onMyTss.DataStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try values(store)
        try store.rebuildLegacyLoadHistory(now: now)
        XCTAssertEqual(try values(store), actual, file: file, line: line)
    }

    func testPausedRebuildCannotRestoreDeletedLoad() async throws {
        for daysAgo in [40, 5] {
            let context = try context()
            let store = DataStore(modelContext: context)
            let row = workout(context, id: "deleted", daysAgo: daysAgo)
            workout(context, id: "retained", daysAgo: 45, tss: 20)
            try store.rebuildLegacyLoadHistory(now: now)
            let paused = try LegacyHistoryRebuilder(context: context, from: now.addingDays(-45), now: now)
            XCTAssertFalse(try paused.applyBatch())
            try await V2Store(context: context, clock: { self.now }).deleteSession(row)
            let corrected = try values(store)
            while try !paused.applyBatch() {}
            XCTAssertEqual(try values(store), corrected)
            XCTAssertTrue(row.isTombstoned)
            try assertMatchesFreshRebuild(store)
        }
    }

    func testOverlappingRebuildAdoptsEarlierEditAndLongerTail() throws {
        let context = try context()
        let store = DataStore(modelContext: context)
        let early = workout(context, id: "early", daysAgo: 60)
        workout(context, id: "late", daysAgo: 10)
        try store.rebuildLegacyLoadHistory(now: now)
        let older = try LegacyHistoryRebuilder(context: context, from: now.addingDays(-30), now: now.addingDays(-1))
        XCTAssertFalse(try older.applyBatch())
        early.tss = 250
        let newer = try LegacyHistoryRebuilder(context: context, from: early.date, now: now)
        XCTAssertFalse(try newer.applyBatch())
        // The newer task can be canceled here. The surviving caller must adopt
        // its earlier dirty boundary and end date, not its own cached CTL/ATL.
        while try !older.applyBatch() {}
        let corrected = try values(store)
        XCTAssertTrue(try newer.applyBatch())
        XCTAssertEqual(try values(store), corrected)
        XCTAssertNil(try store.fetchAppState().pendingLegacyHistoryStart)
        try assertMatchesFreshRebuild(store)
    }

    func testRecentDeletePreservesEarlierDaysAndIncludesEarlierAlias() async throws {
        let context = try context()
        let store = DataStore(modelContext: context)
        let old = workout(context, id: "old", daysAgo: 3650, tss: 50)
        let target = workout(context, id: "target", daysAgo: 1)
        let alias = workout(context, id: "alias", daysAgo: 4, tss: 70)
        alias.linkedSessionID = target.id
        alias.isSuppressed = true
        let set = StrengthSetRecord(sessionID: alias.id, exerciseID: "squat", reps: 8, weightKG: 40)
        context.insert(set)
        try store.rebuildLegacyLoadHistory(now: now)
        let oldDay = try XCTUnwrap(store.fetchDayAggregate(for: old.date))
        // A sentinel proves the recent deletion does not rewrite unrelated years.
        oldDay.bodyBatteryScore = 7
        try context.save()
        let prefix = try values(store).filter { $0[0] < alias.date.timeIntervalSince1970 }
        try await V2Store(context: context, clock: { self.now }).deleteSession(target)
        XCTAssertEqual(try values(store).filter { $0[0] < alias.date.timeIntervalSince1970 }, prefix)
        XCTAssertTrue(alias.isTombstoned)
        XCTAssertTrue(target.isTombstoned)
        XCTAssertFalse(old.isTombstoned)
        XCTAssertEqual(set.sessionID, alias.id)
        // Ignore the intentionally noncanonical score when comparing the tail.
        let tail = try values(store).filter { $0[0] >= alias.date.timeIntervalSince1970 }
        try store.rebuildLegacyLoadHistory(now: now)
        XCTAssertEqual(try values(store).filter { $0[0] >= alias.date.timeIntervalSince1970 }, tail)
    }

    func testSynchronousManualLinkInvalidatesPausedRebuild() async throws {
        let context = try context()
        let store = DataStore(modelContext: context)
        let manual = workout(context, id: "manual", daysAgo: 40)
        let target = workout(context, id: "imported", daysAgo: 40, tss: 20)
        target.source = WorkoutSource.healthKit.rawValue
        try store.rebuildLegacyLoadHistory(now: now)
        let paused = try LegacyHistoryRebuilder(context: context, from: manual.date, now: now)
        XCTAssertFalse(try paused.applyBatch())
        try V2Store(context: context, clock: { self.now }).linkSession(manual: manual, to: target)
        while try !paused.applyBatch() {}
        XCTAssertEqual(try store.fetchDayAggregate(for: manual.date)?.totalTSS, 20)
        try assertMatchesFreshRebuild(store)
    }

    func testThresholdRecalculationInvalidatesPausedLoadRecurrence() async throws {
        let context = try context()
        let store = DataStore(modelContext: context)
        let row = workout(context, id: "threshold-edit", daysAgo: 40)
        row.source = WorkoutSource.healthKit.rawValue
        var features = WorkoutFeatures()
        features.heartRate = [.init(start: row.startTime, end: row.startTime.addingTimeInterval(600), value: 150)]
        row.features = features
        let thresholds = try store.fetchUserThresholds()
        thresholds.maxHeartRate = 190
        try store.rebuildLegacyLoadHistory(now: now)
        let paused = try LegacyHistoryRebuilder(context: context, from: row.date, now: now)
        XCTAssertFalse(try paused.applyBatch())
        thresholds.maxHeartRate = 180
        try store.saveUserThresholds(thresholds)
        let changes = try await store.refreshLegacyWorkoutTSS()
        XCTAssertTrue(changes.dates.contains(row.date))
        try await store.refreshLegacyLoadHistory(from: changes.dates.min(), now: now)
        let corrected = try values(store)
        while try !paused.applyBatch() {}
        XCTAssertEqual(try values(store), corrected)
        try assertMatchesFreshRebuild(store)
    }

    func testCanceledDeleteReopensAndRepairsOfflineWithRecordsIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.store")
        let originalInput = Data("synthetic previous input".utf8)
        let originalPayload = Data("synthetic previous payload".utf8)
        do {
            let context = try context(url: url)
            let store = DataStore(modelContext: context)
            let row = workout(context, id: "deleted", daysAgo: 100)
            row.userTags = ["retained tag"]
            context.insert(StrengthSetRecord(sessionID: row.id, exerciseID: "squat", reps: 8, weightKG: 40))
            context.insert(LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2, sessionID: row.id))
            context.insert(LoadEstimateRecord(sessionID: row.id, version: "prior", inputCutoff: now,
                                             computedAt: now, payloadData: originalPayload, inputData: originalInput))
            let state = try store.fetchAppState()
            state.localWorkoutRepairVersion = LocalWorkoutHistoryRepair.currentVersion
            try store.rebuildLegacyLoadHistory(now: now)
            let deletion = Task { try await V2Store(context: context, clock: { self.now }).deleteSession(row) }
            for _ in 0..<1000 where !row.isTombstoned { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(row.isTombstoned)
            deletion.cancel()
            do { try await deletion.value; XCTFail("Deletion should observe cancellation") }
            catch is CancellationError {}
            XCTAssertNotNil(state.pendingLegacyHistoryStart)
            XCTAssertTrue(state.localWorkoutRepairInProgress)
        }
        let reopened = try context(url: url)
        let store = DataStore(modelContext: reopened)
        let state = try store.fetchAppState()
        XCTAssertTrue(LocalWorkoutHistoryRepair.isRequired(state))
        // A later recent request must include the canceled older dirty tail.
        try await store.refreshLegacyLoadHistory(from: now.addingDays(-1), now: now)
        try assertMatchesFreshRebuild(store)
        try await LocalWorkoutHistoryRepair(store: store, reconcile: {}, clock: { self.now }).run()
        XCTAssertFalse(LocalWorkoutHistoryRepair.isRequired(state))
        let row = try XCTUnwrap(store.fetchWorkout(byId: "deleted"))
        XCTAssertTrue(row.isTombstoned)
        XCTAssertEqual(row.deletionOrigin, "user")
        XCTAssertEqual(row.userTags, ["retained tag"])
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<StrengthSetRecord>()), 1)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<LocalObservation>()), 1)
        let prior = try XCTUnwrap(reopened.fetch(FetchDescriptor<LoadEstimateRecord>()).first)
        XCTAssertEqual(prior.inputData, originalInput)
        XCTAssertEqual(prior.payloadData, originalPayload)
    }

    func testSourceSyncWaitsForDeletionAndCancellationBeforeStartDoesNotMutate() async throws {
        let context = try context()
        let store = DataStore(modelContext: context)
        let row = workout(context, id: "deleted", daysAgo: 40)
        try store.rebuildLegacyLoadHistory(now: now)
        let canceled = Task { try await V2Store(context: context).deleteSession(row) }
        canceled.cancel()
        do { try await canceled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(row.isTombstoned)
        let deletion = Task { try await V2Store(context: context, clock: { self.now }).deleteSession(row) }
        for _ in 0..<1000 where !row.isTombstoned { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(row.isTombstoned)
        try await WorkoutMaintenanceGate.acquire(store.workoutMaintenanceKey, kind: .sourceSync)
        defer { WorkoutMaintenanceGate.release(store.workoutMaintenanceKey) }
        XCTAssertNil(try store.fetchAppState().pendingLegacyHistoryStart)
        XCTAssertFalse(try store.fetchAppState().localWorkoutRepairInProgress)
        try await deletion.value
        try assertMatchesFreshRebuild(store)
    }

    func testLongDiskHistoryDeletionYieldsToMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context(url: directory.appendingPathComponent("synthetic.store"))
        let store = DataStore(modelContext: context)
        let row = workout(context, id: "deleted", daysAgo: 3650)
        for index in 0..<1000 { workout(context, id: "retained-\(index)", daysAgo: index * 3, tss: 10) }
        let prior = LoadEstimateRecord(sessionID: row.id, version: "prior", inputCutoff: now,
                                       computedAt: now, payloadData: Data("prior payload".utf8), inputData: Data("prior input".utf8))
        context.insert(prior)
        context.insert(StrengthSetRecord(sessionID: row.id, exerciseID: "squat", reps: 8))
        row.userTags = ["retained tag"]
        try store.rebuildLegacyLoadHistory(now: now)
        let heartbeat = HistoryHeartbeat()
        let monitor = Task { @MainActor in
            var previous = Date()
            while !heartbeat.finished {
                try await Task.sleep(for: .milliseconds(10))
                let current = Date()
                heartbeat.gap = max(heartbeat.gap, current.timeIntervalSince(previous))
                heartbeat.ticks += 1
                previous = current
            }
        }
        defer { monitor.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        let began = Date()
        try await V2Store(context: context, clock: { self.now }).deleteSession(row)
        heartbeat.finished = true
        try await monitor.value
        print("HISTORY_DELETE days=3650 workouts=1001 seconds=\(Date().timeIntervalSince(began)) max_main_gap=\(heartbeat.gap) ticks=\(heartbeat.ticks)")
        XCTAssertLessThan(heartbeat.gap, 0.75)
        XCTAssertGreaterThan(heartbeat.ticks, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 1001)
        XCTAssertTrue(row.isTombstoned)
        XCTAssertEqual(row.userTags, ["retained tag"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StrengthSetRecord>()), 1)
        let priorID = prior.id
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<LoadEstimateRecord>(predicate: #Predicate { $0.id == priorID })).first)
        XCTAssertEqual(retained.inputData, Data("prior input".utf8))
        XCTAssertEqual(retained.payloadData, Data("prior payload".utf8))
        try assertMatchesFreshRebuild(store)
    }
}

@MainActor private final class HistoryHeartbeat {
    var finished = false
    var gap = 0.0
    var ticks = 0
    nonisolated deinit {}
}
