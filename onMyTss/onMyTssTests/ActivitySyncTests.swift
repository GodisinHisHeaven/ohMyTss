import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class ActivitySyncTests: XCTestCase {
    func testThresholdEditDuringSyncWinsForSavedLoadsAndEstimates() async throws {
        let fixture = try SyncFixture()
        let workout = fixture.health.addWorkout(at: fixture.clock.now.addingDays(-10))
        try await fixture.engine.incrementalUpdate()
        let before = try XCTUnwrap(fixture.store.fetchWorkout(byId: workout.uuid.uuidString)).tss
        let thresholds = try fixture.store.fetchUserThresholds()
        fixture.health.onRecoveryRead = {
            thresholds.maxHeartRate = 205
            thresholds.cardioMaxHeartRate = 205
            thresholds.lastModified = fixture.clock.now.addingTimeInterval(1)
        }
        try await fixture.engine.incrementalUpdate()
        let row = try XCTUnwrap(fixture.store.fetchWorkout(byId: workout.uuid.uuidString))
        XCTAssertLessThan(row.tss, before)
        XCTAssertEqual(row.tss, TSSCalculator.legacyHeartRateTSS(intervals: row.features.heartRate,
            maxHeartRate: 205, restingHeartRate: 60), accuracy: 0.0001)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: row.date)?.totalTSS, row.tss)
        let latest = try XCTUnwrap(V2EstimateBatch.latestEstimates(context: fixture.context)[row.id])
        XCTAssertEqual(try JSONDecoder().decode(SyncThresholdProbe.self, from: latest.inputData).maxHeartRate, 205)
        XCTAssertEqual(fixture.health.featureRequests.count, 1)
    }

    func testFailedSensorRetryQueueRotatesPastPersistentlyFailingBatch() async throws {
        let fixture = try SyncFixture()
        for index in 0..<21 {
            let row = fixture.health.addWorkout(at: fixture.clock.now.addingDays(-index - 5))
            fixture.health.failFeatures.insert(row.uuid.uuidString)
        }
        try await fixture.engine.incrementalUpdate()
        let state = try fixture.store.fetchAppState()
        let last = try XCTUnwrap(state.pendingHealthKitWorkoutIDs.last)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests.last?.count, 20)
        XCTAssertEqual(state.pendingHealthKitWorkoutIDs.first, last)
        fixture.health.failFeatures = []
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests.last?.first, last)
        XCTAssertEqual(state.pendingHealthKitWorkoutIDs.count, 1)
    }

    func testRepeatedSyncUsesCursorsWithoutOldSampleReadsOrEstimateWrites() async throws {
        let fixture = try SyncFixture()
        let old = fixture.health.addWorkout(at: fixture.clock.now.addingDays(-30))
        fixture.strava.listed = [try activity(id: 81, at: fixture.clock.now.addingDays(-1))]
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        try await fixture.engine.incrementalUpdate()
        let first = fixture.clock.now
        let estimates = try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id)
        let savedFeatures = try fixture.store.fetchWorkout(byId: old.uuid.uuidString)?.featuresData
        XCTAssertEqual(fixture.health.featureRequests, [old.uuid.uuidString])
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertNil(fixture.health.anchors[0])
        XCTAssertEqual(fixture.strava.windows[0].after, first.addingDays(-90))

        fixture.clock.now = first.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(fixture.health.anchors[1])
        XCTAssertEqual(fixture.health.featureRequests.count, 1)
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertEqual(fixture.strava.windows[1].after, first.addingDays(-7))
        XCTAssertEqual(Set(try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id)), Set(estimates))
        XCTAssertEqual(try fixture.store.fetchWorkout(byId: old.uuid.uuidString)?.featuresData, savedFeatures)
        XCTAssertEqual(try fixture.store.allWorkouts().count, 2)
        let auth = try XCTUnwrap(fixture.store.fetchStravaAuth())
        XCTAssertEqual(auth.lastSyncDate, fixture.clock.now)
        XCTAssertEqual(auth.lastReconciliationDate, first)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixture.health.physiologyStarts.last), first.addingDays(-18))
    }

    func testOldDeletionAndReplacementUpdateHistoryAndKeepPersonalRecords() async throws {
        let fixture = try SyncFixture()
        let old = fixture.health.addWorkout(at: fixture.clock.now.addingDays(-40))
        try await fixture.engine.incrementalUpdate()
        let rpe = MuscleRPERecord(regionRaw: "quads", sideRaw: "left", rpe: 8, observedAt: old.startDate)
        let observation = LocalObservation(regionRaw: "quads", sessionID: old.uuid.uuidString)
        fixture.context.insert(rpe); fixture.context.insert(observation)
        try fixture.context.save()
        let previousIDs = Set(try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id))
        fixture.health.deleted = [old.uuid.uuidString]
        let corrected = fixture.health.addWorkout(at: old.startDate.addingDays(-1), duration: 1800)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertTrue(try XCTUnwrap(fixture.store.fetchWorkout(byId: old.uuid.uuidString)).isTombstoned)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: old.startDate)?.totalTSS, 0)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.store.fetchDayAggregate(for: corrected.startDate)).totalTSS, 0)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<MuscleRPERecord>()).first?.id, rpe.id)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<LocalObservation>()).first?.sessionID, old.uuid.uuidString)
        XCTAssertTrue(previousIDs.isSubset(of: Set(try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id))))
    }

    func testSourceFailuresDoNotAdvanceTheFailedSourceCursor() async throws {
        let fixture = try SyncFixture()
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        try await fixture.engine.incrementalUpdate()
        let first = fixture.clock.now
        let state = try fixture.store.fetchAppState()
        let anchor = state.healthKitAnchor
        fixture.health.failChanges = true
        fixture.clock.now = first.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.healthKitAnchor, anchor)
        XCTAssertEqual(state.lastHealthKitSyncDate, first)
        XCTAssertEqual(try fixture.store.fetchStravaAuth()?.lastSyncDate, fixture.clock.now)
        let stravaCheckpoint = fixture.clock.now
        fixture.health.failChanges = false
        fixture.strava.failList = true
        fixture.clock.now = first.addingTimeInterval(120)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.lastHealthKitSyncDate, fixture.clock.now)
        XCTAssertEqual(try fixture.store.fetchStravaAuth()?.lastSyncDate, stravaCheckpoint)
        fixture.health.failChanges = true
        do { try await fixture.engine.incrementalUpdate(); XCTFail("Both failures must be reported") }
        catch { XCTAssertFalse(state.isComputationInProgress) }
    }

    func testFailedOlderSensorReadRetriesByIdentityWithoutReplayingHistory() async throws {
        let fixture = try SyncFixture()
        let old = fixture.health.addWorkout(at: fixture.clock.now.addingDays(-50))
        fixture.health.failFeatures = [old.uuid.uuidString]
        try await fixture.engine.incrementalUpdate()
        let state = try fixture.store.fetchAppState()
        XCTAssertEqual(state.pendingHealthKitWorkoutIDs, [old.uuid.uuidString])
        XCTAssertNotNil(state.healthKitAnchor)
        fixture.health.failFeatures = []
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests, [[old.uuid.uuidString]])
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertTrue(state.pendingHealthKitWorkoutIDs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(fixture.store.fetchWorkout(byId: old.uuid.uuidString)).features.heartRate.isEmpty)
    }

    func testLateSampleRefreshIsThrottledAndOlderStravaHistoryIsReconciledWeekly() async throws {
        let fixture = try SyncFixture()
        let recent = fixture.health.addWorkout(at: fixture.clock.now.addingTimeInterval(-3600))
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        try await fixture.engine.incrementalUpdate()
        let first = fixture.clock.now
        fixture.health.recent = [recent]
        fixture.clock.now = first.addingTimeInterval(6 * 3600)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.rangeRequests.count, 1)
        XCTAssertEqual(fixture.health.rangeRequests[0], fixture.clock.now.addingDays(-2))
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.rangeRequests.count, 1)
        fixture.clock.now = first.addingDays(8)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.strava.windows.last?.after, fixture.clock.now.addingDays(-90))
        XCTAssertEqual(try fixture.store.fetchStravaAuth()?.lastReconciliationDate, fixture.clock.now)
    }

    func testNoOpImportAndEmptyDeletionDoNotRebuildSavedHistory() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-20)
        func row() -> Workout {
            let row = Workout(id: "unchanged", date: start.startOfDay, startTime: start, duration: 300,
                              workoutType: "Run", tss: 10, calculationMethod: "duration", source: .healthKit)
            row.featuresData = Data("unchanged opaque sample bytes".utf8)
            return row
        }
        try fixture.store.saveWorkout(row())
        let day = DayAggregate(date: start.startOfDay, totalTSS: 10, ctl: 77, atl: 66, tsb: 11)
        try fixture.store.saveDayAggregate(day)
        let changes = try fixture.store.saveWorkouts([row()])
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(try fixture.store.applySourceDeletions([]).isEmpty)
        XCTAssertEqual(day.ctl, 77)
        XCTAssertEqual(day.atl, 66)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testIncrementalLoadTailMatchesFullRebuildWithoutChangingEarlierDays() async throws {
        let fixture = try SyncFixture()
        for index in 0..<100 {
            let date = fixture.clock.now.addingDays(-index)
            fixture.context.insert(Workout(id: "history-\(index)", date: date.startOfDay, startTime: date,
                duration: 300, workoutType: "Ride", tss: Double(index % 7) * 10,
                calculationMethod: "synthetic", source: .manual))
        }
        try fixture.context.save()
        try fixture.store.rebuildLegacyLoadHistory(now: fixture.clock.now)
        let previous = try fixture.store.fetchAllDayAggregates().filter { $0.date < fixture.clock.now.addingDays(-10).startOfDay }
            .map { [$0.totalTSS, $0.ctl, $0.atl, $0.tsb] }
        let changed = try XCTUnwrap(fixture.store.fetchWorkout(byId: "history-10"))
        changed.tss = 135
        try fixture.context.save()
        try await fixture.store.refreshLegacyLoadHistory(from: changed.date, now: fixture.clock.now)
        let beforeFull = try fixture.store.fetchAllDayAggregates().map { [$0.totalTSS, $0.ctl, $0.atl, $0.tsb, $0.rampRate ?? -999] }
        XCTAssertEqual(previous, try fixture.store.fetchAllDayAggregates().filter { $0.date < changed.date }.map { [$0.totalTSS, $0.ctl, $0.atl, $0.tsb] })
        try fixture.store.rebuildLegacyLoadHistory(now: fixture.clock.now)
        XCTAssertEqual(beforeFull, try fixture.store.fetchAllDayAggregates().map { [$0.totalTSS, $0.ctl, $0.atl, $0.tsb, $0.rampRate ?? -999] })
    }

    func testCancelledImportRetainsCursorAndCanResumeWithoutLosingRows() async throws {
        let fixture = try SyncFixture()
        for index in 0..<80 { _ = fixture.health.addWorkout(at: fixture.clock.now.addingTimeInterval(-Double(index + 1) * 7200)) }
        var finished = false
        let task = Task { defer { finished = true }; try Task.checkCancellation(); try await fixture.engine.incrementalUpdate() }
        defer { task.cancel() }
        try await waitForSyncTestCondition("first imported workout to be persisted", pollInterval: .milliseconds(1)) {
            try !fixture.store.allWorkouts().isEmpty || finished
        }
        if finished {
            try await task.value
            XCTFail("Import completed before a persisted batch could be cancelled")
            return
        }
        task.cancel()
        try await waitForSyncTestCondition("cancelled import to finish") { finished }
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { throw error }
        let state = try fixture.store.fetchAppState()
        XCTAssertNil(state.healthKitAnchor)
        XCTAssertTrue(state.isComputationInProgress)
        let retained = Set(try fixture.store.allWorkouts().map(\.id))
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(try fixture.store.allWorkouts().count, 80)
        XCTAssertTrue(retained.isSubset(of: Set(try fixture.store.allWorkouts().map(\.id))))
        XCTAssertNotNil(state.healthKitAnchor)
        XCTAssertFalse(state.isComputationInProgress)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 80)
    }

    func testThousandDiskRecordsStayResponsiveDuringSyncAndRepeatedSyncDoesNoWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try SyncFixture(url: directory.appendingPathComponent("sync.store"))
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSyncDate = fixture.clock.now
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        state.lastComputationDate = fixture.clock.now
        state.lastRecoverySyncDate = fixture.clock.now
        for index in 0..<1000 {
            let start = fixture.clock.now.addingTimeInterval(-Double(index + 2) * 3600)
            let row = Workout(id: "saved-\(index)", date: start.startOfDay, startTime: start, duration: 300,
                              workoutType: "Ride", tss: 25, calculationMethod: "hr-time-v2 (resting HR assumed 60)", source: .healthKit)
            var features = WorkoutFeatures()
            features.end = start.addingTimeInterval(300)
            features.heartRate = (0..<30).map { sample in
                .init(start: start.addingTimeInterval(Double(sample) * 10), end: start.addingTimeInterval(Double(sample + 1) * 10), value: 150)
            }
            row.features = features
            row.tss = TSSCalculator.legacyHeartRateTSS(intervals: features.heartRate, maxHeartRate: 190, restingHeartRate: 60)
            row.sessionGroupID = row.id // Existing imports are already canonicalized.
            fixture.context.insert(row)
        }
        try fixture.context.save()
        try fixture.store.rebuildLegacyLoadHistory(now: fixture.clock.now)
        try await V2Store(context: fixture.context).refreshEstimates()
        let snapshots = Set(try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id))
        let oldRows = Dictionary(uniqueKeysWithValues: try fixture.store.allWorkouts().map { ($0.id, $0.featuresData) })
        let oldTSS = Dictionary(uniqueKeysWithValues: try fixture.store.allWorkouts().map { ($0.id, $0.tss) })
        let newest = fixture.health.addWorkout(at: fixture.clock.now.addingTimeInterval(-1800))
        fixture.health.sampleCount = 6000
        let heartbeat = SyncHeartbeat()
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
        defer { heartbeat.finished = true; monitor.cancel() }
        let began = Date()
        try await fixture.engine.incrementalUpdate()
        let syncSeconds = Date().timeIntervalSince(began)
        let firstCount = try fixture.context.fetchCount(FetchDescriptor<LoadEstimateRecord>())
        fixture.clock.now = Date().addingTimeInterval(1)
        let repeatBegan = Date()
        try await fixture.engine.incrementalUpdate()
        let repeatSeconds = Date().timeIntervalSince(repeatBegan)
        heartbeat.finished = true
        try await monitor.value
        print("INCREMENTAL_DISK_SYNC seconds=\(syncSeconds) repeated_seconds=\(repeatSeconds) max_main_gap=\(heartbeat.gap) ticks=\(heartbeat.ticks)")
        XCTAssertGreaterThan(heartbeat.ticks, 1)
        XCTAssertLessThan(heartbeat.gap, 0.75)
        XCTAssertEqual(fixture.health.featureRequests, [newest.uuid.uuidString])
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertEqual(try fixture.store.allWorkouts().count, 1001)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), firstCount)
        XCTAssertTrue(snapshots.isSubset(of: Set(try fixture.context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id))))
        for row in try fixture.store.allWorkouts() where row.id != newest.uuid.uuidString {
            XCTAssertEqual(row.featuresData, oldRows[row.id] ?? nil)
            XCTAssertEqual(row.tss, oldTSS[row.id])
        }
        let latest = try V2EstimateBatch.latestEstimates(context: fixture.context)
        for estimate in latest.values {
            XCTAssertEqual(try JSONDecoder().decode(SyncThresholdProbe.self, from: estimate.inputData).maxHeartRate, 190)
        }
    }

    private func activity(id: Int, at date: Date) throws -> StravaActivity {
        let json = try JSONSerialization.data(withJSONObject: ["id": id, "start_date": ISO8601DateFormatter().string(from: date), "moving_time": 600, "sport_type": "Run"])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StravaActivity.self, from: json)
    }
}

@MainActor private final class SyncFixture {
    let container: ModelContainer
    let context: ModelContext
    let store: onMyTss.DataStore
    let clock = SyncClock()
    let health = SyncHealthSource()
    let strava = SyncStravaSource()
    lazy var engine = BodyBatteryEngine(healthKitManager: health, dataStore: store,
        stravaAuthManager: SyncToken(), stravaClient: strava, clock: { [clock] in clock.now })
    nonisolated deinit {}

    init(url: URL? = nil) throws {
        let schema = Schema(AppSchema.models)
        let config = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        store = DataStore(modelContext: context)
        let thresholds = try store.fetchUserThresholds()
        thresholds.hasCompletedOnboarding = true
        thresholds.cardioMaxHeartRate = 190
        thresholds.maxHeartRate = 190
        thresholds.lastModified = clock.now.addingDays(-2)
        try context.save()
    }
}

@MainActor private final class SyncHealthSource: HealthKitManager {
    var all: [HKWorkout] = []
    var delta: [HKWorkout] = []
    var deleted: [String] = []
    var recent: [HKWorkout] = []
    var anchors: [HKQueryAnchor?] = []
    var featureRequests: [String] = []
    var rangeRequests: [Date] = []
    var identityRequests: [[String]] = []
    var physiologyStarts: [Date] = []
    var failChanges = false
    var failFeatures: Set<String> = []
    var sampleCount = 1
    var onRecoveryRead: (() -> Void)?

    func addWorkout(at start: Date, duration: Double = 600) -> HKWorkout {
        let row = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(duration))
        all.append(row); delta.append(row)
        return row
    }
    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        if failChanges { throw URLError(.notConnectedToInternet) }
        anchors.append(anchor)
        let result = anchor == nil ? all : delta
        delta = []
        return (result, deleted, HKQueryAnchor(fromValue: anchors.count))
    }
    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        rangeRequests.append(startDate); return recent
    }
    override func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] {
        identityRequests.append(ids); return all.filter { ids.contains($0.uuid.uuidString) }
    }
    override func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        featureRequests.append(workout.uuid.uuidString)
        if failFeatures.contains(workout.uuid.uuidString) { throw HealthKitError.noData }
        var features = WorkoutFeatures()
        features.heartRate = (0..<sampleCount).map { index in
            let length = workout.duration / Double(sampleCount)
            return .init(start: workout.startDate.addingTimeInterval(Double(index) * length),
                         end: workout.startDate.addingTimeInterval(Double(index + 1) * length), value: 150)
        }
        return features
    }
    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        let action = onRecoveryRead
        onRecoveryRead = nil
        action?()
        physiologyStarts.append(startDate); return []
    }
    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] { [] }
}

@MainActor private final class SyncStravaSource: StravaActivityFetching {
    struct Window { let after: Date; let before: Date; let page: Int }
    var windows: [Window] = []
    var listed: [StravaActivity] = []
    var failList = false
    nonisolated deinit {}
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity] {
        windows.append(Window(after: after, before: before, page: page))
        if failList { throw URLError(.notConnectedToInternet) }
        return listed.filter { ($0.startDateTime ?? .distantPast) > after && ($0.startDateTime ?? .distantFuture) < before }
    }
    func activity(accessToken: String, id: Int) async throws -> StravaActivity? { listed.first { $0.id == id } }
}

@MainActor private final class SyncToken: StravaAuthManaging {
    nonisolated deinit {}
    func getValidAccessToken() async throws -> String { "synthetic-sync-token" }
}
@MainActor private final class SyncClock {
    var now = Date()
    nonisolated deinit {}
}
@MainActor private final class SyncHeartbeat {
    var finished = false
    var ticks = 0
    var gap: TimeInterval = 0
    nonisolated deinit {}
}
private struct SyncThresholdProbe: Decodable { var maxHeartRate: Int? }
