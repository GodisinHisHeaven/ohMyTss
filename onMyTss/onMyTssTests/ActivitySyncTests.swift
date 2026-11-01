import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class ActivitySyncTests: XCTestCase {
    func testHistoricalEndpointReconciliationAndSourceCorrectionRebuildTotals() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-100).startOfDay.addingTimeInterval(3600)
        let garmin = Workout(id: "old-garmin", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 25,
                             calculationMethod: "duration", source: .healthKit)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        var healthFeatures = WorkoutFeatures()
        healthFeatures.end = start.addingTimeInterval(600)
        garmin.features = healthFeatures
        let strava = Workout(id: "old-strava", date: start.startOfDay,
                             startTime: start.addingTimeInterval(30), duration: 570,
                             workoutType: "Run", tss: 35, calculationMethod: "duration", source: .strava)
        var stravaFeatures = WorkoutFeatures()
        stravaFeatures.end = start.addingTimeInterval(600)
        strava.features = stravaFeatures
        fixture.context.insert(garmin)
        fixture.context.insert(strava)
        try fixture.context.save()

        let changes = try fixture.store.finalizeWorkoutSources()
        XCTAssertFalse(changes.isEmpty)
        XCTAssertFalse(garmin.isSuppressed)
        XCTAssertTrue(strava.isSuppressed)
        XCTAssertEqual(strava.linkedSessionID, garmin.id)
        try await fixture.store.refreshLegacyLoadHistory(from: start.startOfDay, now: fixture.clock.now)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: start)?.totalTSS, 25)

        // An upstream correction can disprove the match; both rows must return
        // to totals without losing either original source record.
        stravaFeatures.end = start.addingTimeInterval(900)
        strava.features = stravaFeatures
        let corrected = try fixture.store.reconcileWorkoutSources()
        XCTAssertFalse(corrected.isEmpty)
        XCTAssertFalse(garmin.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
        XCTAssertNil(strava.linkedSessionID)
        try await fixture.store.refreshLegacyLoadHistory(from: start.startOfDay, now: fixture.clock.now)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: start)?.totalTSS, 60)
        XCTAssertEqual(Set(try fixture.store.allWorkouts().map(\.id)), Set([garmin.id, strava.id]))
    }

    func testStravaConnectedDuringHealthReadDefersFinalizationUntilRetry() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingTimeInterval(-3600)
        let health = Workout(id: "changed-auth-health", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 20,
                             calculationMethod: "duration", source: .healthKit)
        health.isTombstoned = true
        health.deletionOrigin = "user"
        let strava = Workout(id: "123", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Run", tss: 30, calculationMethod: "duration", source: .strava, stravaId: 123)
        fixture.context.insert(health)
        fixture.context.insert(strava)
        let state = try fixture.store.fetchAppState()
        state.healthKitSourceBackfillVersion = 1
        fixture.health.pauseNextChange = true
        try fixture.context.save()
        let sync = Task { try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.changesGate?.release(); sync.cancel() }
        try await waitForSyncTestCondition("HealthKit source gate") { fixture.health.changesGate?.isWaiting == true }
        let auth = StravaAuth(connectedAt: fixture.clock.now, isConnected: true)
        try fixture.store.saveStravaAuth(auth)
        fixture.strava.failList = true
        fixture.health.changesGate?.release()
        try await sync.value
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
        XCTAssertFalse(strava.isTombstoned)
        XCTAssertNil(auth.lastSyncDate)

        fixture.strava.failList = false
        fixture.strava.listed = [try activity(id: 123, at: start)]
        try await fixture.engine.incrementalUpdate()
        XCTAssertFalse(state.pendingWorkoutSourceFinalization)
        XCTAssertTrue(strava.isTombstoned)
    }

    func testStravaReconnectedDuringBackfillDoesNotFinalizeOldSources() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingTimeInterval(-3600)
        let deleted = Workout(id: "reconnect-health", date: start.startOfDay, startTime: start,
                              duration: 600, workoutType: "Running", tss: 20,
                              calculationMethod: "duration", source: .healthKit)
        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        let strava = Workout(id: "123", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Run", tss: 30, calculationMethod: "duration", source: .strava, stravaId: 123)
        fixture.context.insert(deleted)
        fixture.context.insert(strava)
        let oldDate = fixture.clock.now.addingDays(-60)
        let oldWorkout = HKWorkout(activityType: .running, start: oldDate, end: oldDate.addingTimeInterval(600))
        fixture.health.all = [oldWorkout]
        let oldRow = Workout(id: oldWorkout.uuid.uuidString, date: oldDate.startOfDay, startTime: oldDate,
                             duration: 600, workoutType: "Running", tss: 10,
                             calculationMethod: "duration", source: .healthKit, healthKitUUID: oldWorkout.uuid.uuidString)
        fixture.context.insert(oldRow)
        let oldAuth = StravaAuth(athleteId: 1, connectedAt: fixture.clock.now.addingDays(-2), isConnected: true)
        try fixture.store.saveStravaAuth(oldAuth)
        fixture.strava.listed = [try activity(id: 123, at: start)]
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        state.healthKitSourceBackfillVersion = 1
        state.pendingHealthKitSourceBackfillIDs = [oldRow.id]
        fixture.health.pauseNextIdentity = true
        try fixture.context.save()
        let sync = Task { try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.identityGate?.release(); sync.cancel() }
        try await waitForSyncTestCondition("historical source gate") { fixture.health.identityGate?.isWaiting == true }
        try fixture.store.deleteStravaAuth(oldAuth)
        let newAuth = StravaAuth(athleteId: 2, connectedAt: fixture.clock.now, isConnected: true)
        try fixture.store.saveStravaAuth(newAuth)
        fixture.health.identityGate?.release()
        try await sync.value
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
        XCTAssertFalse(strava.isTombstoned)
        XCTAssertNil(newAuth.lastSyncDate)
    }

    func testResetAllowsFreshHistoricalSourceBackfillAndRemoval() async throws {
        let fixture = try SyncFixture()
        let state = try fixture.store.fetchAppState()
        state.healthKitSourceBackfillVersion = 1
        state.pendingHealthKitSourceBackfillIDs = ["old-source"]
        state.healthKitTypeBackfillVersion = 1
        state.pendingHealthKitTypeBackfillIDs = ["old-type"]
        state.pendingWorkoutSourceFinalization = true
        try fixture.context.save()
        try fixture.store.deleteAllWorkouts()
        try fixture.store.resetAppState()
        XCTAssertNoThrow(try fixture.store.ensureWorkoutMutationAllowed())

        let start = fixture.clock.now.addingDays(-60)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        fixture.health.all = [workout]
        let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                          duration: 600, workoutType: "Running", tss: 25,
                          calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
        fixture.context.insert(row)
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(row.sourceBundleIdentifier)
        XCTAssertEqual(state.healthKitSourceBackfillVersion, 1)
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
        XCTAssertTrue(state.pendingHealthKitTypeBackfillIDs.isEmpty)
        XCTAssertNoThrow(try fixture.store.deleteWorkout(row))
    }

    func testUnresolvedHistoricalSourceOnlyInvalidatesCurrentWeekWidget() async throws {
        for currentWeek in [false, true] {
            let fixture = try SyncFixture()
            let interval = try XCTUnwrap(Calendar.current.dateInterval(of: .weekOfYear, for: fixture.clock.now))
            let start = currentWeek ? max(interval.start, fixture.clock.now.addingTimeInterval(-1))
                : interval.start.addingTimeInterval(-60)
            let id = UUID().uuidString
            let row = Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                              workoutType: "Running", tss: 25, calculationMethod: "duration",
                              source: .healthKit, healthKitUUID: id)
            fixture.context.insert(row)
            let state = try fixture.store.fetchAppState()
            state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
            state.lastHealthKitSampleRefreshDate = fixture.clock.now
            state.healthKitSourceBackfillVersion = 1
            state.pendingHealthKitSourceBackfillIDs = [id]
            fixture.health.identityUnavailable = true
            try fixture.context.save()

            try await fixture.engine.incrementalUpdate()
            XCTAssertEqual(state.pendingHealthKitSourceBackfillIDs, [id])
            XCTAssertTrue(fixture.engine.lastSyncHadWarnings)
            XCTAssertEqual(fixture.engine.lastSyncRequiresRetry, currentWeek)
        }
    }

    func testUnverifiedStravaMissingActivityDefersFinalizationAndCursor() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingTimeInterval(-3600)
        let health = Workout(id: "unverified-health", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 20,
                             calculationMethod: "duration", source: .healthKit)
        health.isTombstoned = true
        health.deletionOrigin = "user"
        let strava = Workout(id: "123", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Run", tss: 30,
                             calculationMethod: "duration", source: .strava, stravaId: 123)
        fixture.context.insert(health)
        fixture.context.insert(strava)
        let previous = fixture.clock.now.addingDays(-2)
        let auth = StravaAuth(lastSyncDate: previous, isConnected: true)
        try fixture.store.saveStravaAuth(auth)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        fixture.strava.failDetail = true
        try fixture.context.save()

        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(auth.lastSyncDate, previous)
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
        XCTAssertFalse(strava.isTombstoned)
        XCTAssertEqual(health.deletionOrigin, "user")
    }

    func testFailedRecentHealthKitRefreshDefersFinalizationAndFreshness() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingTimeInterval(-3600)
        let health = Workout(id: "refresh-health", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 20,
                             calculationMethod: "duration", source: .healthKit)
        health.isTombstoned = true
        health.deletionOrigin = "user"
        let strava = Workout(id: "refresh-strava", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Run", tss: 30,
                             calculationMethod: "duration", source: .strava)
        fixture.context.insert(health)
        fixture.context.insert(strava)
        let previous = fixture.clock.now.addingDays(-2)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSyncDate = previous
        state.lastHealthKitSampleRefreshDate = previous
        fixture.health.failRange = true
        try fixture.context.save()

        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.lastHealthKitSyncDate, previous)
        XCTAssertEqual(state.lastHealthKitSampleRefreshDate, previous)
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
        XCTAssertFalse(strava.isTombstoned)
    }

    func testDenseHistoricalSourceRecoveryKeepsMainActorResponsive() async throws {
        let fixture = try SyncFixture()
        let firstDate = fixture.clock.now.addingDays(-80).startOfDay.addingTimeInterval(3600)
        let samples = (0..<4000).map { index in
            let start = firstDate.addingTimeInterval(Double(index))
            return TimedValue(start: start, end: start.addingTimeInterval(1), value: 140)
        }
        let encoder = JSONEncoder()
        var rows: [Workout] = []
        for index in 0..<21 {
            let start = firstDate.addingDays(index)
            let id = UUID().uuidString
            let row = Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                              workoutType: "Running", tss: 25, calculationMethod: "duration",
                              source: .healthKit, healthKitUUID: id)
            var features = WorkoutFeatures()
            features.heartRate = samples
            features.provenance = ["HealthKit source: com.garmin.connect.mobile; workout: \(id)"]
            row.featuresData = try encoder.encode(features)
            fixture.context.insert(row)
            rows.append(row)
        }
        // A broken unrelated sensor channel must not prevent reading provenance.
        let malformed = try XCTUnwrap(rows.first)
        malformed.featuresData = try JSONSerialization.data(withJSONObject: [
            "provenance": ["HealthKit source: com.garmin.connect.mobile; workout: \(malformed.id)"],
            "heartRate": "unreadable legacy sensor payload"
        ])
        let originalData = rows.map(\.featuresData)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        state.lastComputationDate = fixture.clock.now
        fixture.health.identityUnavailable = true
        try fixture.context.save()
        let heartbeat = SyncHeartbeat()
        let monitor = Task { @MainActor in
            var previous = Date()
            while !heartbeat.finished {
                try await Task.sleep(for: .milliseconds(10))
                let now = Date()
                heartbeat.gap = max(heartbeat.gap, now.timeIntervalSince(previous))
                heartbeat.ticks += 1
                previous = now
            }
        }
        defer { heartbeat.finished = true; monitor.cancel() }
        try await fixture.engine.incrementalUpdate()
        heartbeat.finished = true
        try await monitor.value
        print("SOURCE_BACKFILL_DENSE count=21 samples_per_workout=4000 max_main_gap=\(heartbeat.gap) ticks=\(heartbeat.ticks)")
        XCTAssertGreaterThan(heartbeat.ticks, 1)
        XCTAssertLessThan(heartbeat.gap, 0.75)
        XCTAssertTrue(rows.allSatisfy { $0.sourceBundleIdentifier == "com.garmin.connect.mobile" })
        XCTAssertEqual(rows.map(\.featuresData), originalData)
        XCTAssertEqual(state.pendingHealthKitSourceBackfillIDs.count, 21)
    }

    func testCompletingSourceLookupRefreshesDeferredPersonalRecordsWithoutMetadataChange() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-60)
        let healthWorkout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        fixture.health.all = [healthWorkout]
        let health = Workout(id: healthWorkout.uuid.uuidString, date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 25, calculationMethod: "duration",
                             source: .healthKit, healthKitUUID: healthWorkout.uuid.uuidString)
        health.sourceBundleIdentifier = healthWorkout.sourceRevision.source.bundleIdentifier
        let strava = Workout(id: "pending-strava", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Run", tss: 30, calculationMethod: "duration", source: .strava)
        health.isSuppressed = true
        health.linkedSessionID = strava.id
        health.sessionGroupID = health.id
        strava.sessionGroupID = health.id
        fixture.context.insert(health)
        fixture.context.insert(strava)
        let set = StrengthSetRecord(sessionID: health.id, exerciseID: "squat", reps: 8, weightKG: 0)
        fixture.context.insert(set)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        state.lastComputationDate = fixture.clock.now
        state.healthKitSourceBackfillVersion = 1
        state.pendingHealthKitSourceBackfillIDs = [health.id]
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
        XCTAssertEqual(set.sessionID, health.id)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<StrengthSetRecord>()), 1)
    }

    func testHistoricalSourceBackfillDrainsBatchesAndRebuildsGarminHistory() async throws {
        let fixture = try SyncFixture()
        let initial = fixture.clock.now.addingDays(-100).startOfDay.addingTimeInterval(3600)
        let device = HKDevice(name: "Forerunner", manufacturer: "Garmin", model: "Forerunner",
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        var legacy: [Workout] = []
        for index in 0..<25 {
            let start = initial.addingTimeInterval(Double(index) * 86400)
            let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600),
                                    duration: 600, totalEnergyBurned: nil, totalDistance: nil,
                                    device: device, metadata: nil)
            fixture.health.all.append(workout)
            let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                              duration: 600, workoutType: "Running", tss: 25,
                              calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
            fixture.context.insert(row)
            legacy.append(row)
        }
        let target = try XCTUnwrap(legacy.first)
        let strava = Workout(id: "historical-strava", date: target.date, startTime: target.startTime,
                             duration: 600, workoutType: "Run", tss: 35,
                             calculationMethod: "duration", source: .strava)
        target.isSuppressed = true
        target.linkedSessionID = strava.id
        target.sessionGroupID = target.id
        strava.sessionGroupID = target.id
        fixture.context.insert(strava)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        state.lastComputationDate = fixture.clock.now
        try fixture.context.save()
        try fixture.store.rebuildLegacyLoadHistory(now: fixture.clock.now)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: target.date)?.totalTSS, 35)

        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests.map(\.count), [20, 5])
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
        XCTAssertTrue(legacy.allSatisfy { $0.deviceManufacturer == "Garmin" && $0.sourceBundleIdentifier != nil })
        XCTAssertFalse(target.isSuppressed)
        XCTAssertTrue(strava.isSuppressed)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: target.date)?.workoutCount, 1)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: target.date)?.totalTSS, 25)
        let firstCount = try fixture.context.fetchCount(FetchDescriptor<LoadEstimateRecord>())
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests.count, 2)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), firstCount)
    }

    func testHistoricalSourceBackfillRetriesUnreadableAndKeepsTombstone() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-100)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        fixture.health.all = [workout]
        let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                          duration: 600, workoutType: "Running", tss: 25,
                          calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
        fixture.context.insert(row)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        try fixture.context.save()
        fixture.health.failIdentity = true
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.pendingHealthKitSourceBackfillIDs, [row.id])
        XCTAssertNil(row.sourceBundleIdentifier)
        fixture.health.failIdentity = false
        fixture.health.identityUnavailable = true
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.pendingHealthKitSourceBackfillIDs, [row.id])
        XCTAssertNil(row.sourceBundleIdentifier)
        fixture.health.identityUnavailable = false
        fixture.health.deleted = [row.id]
        try await fixture.engine.incrementalUpdate()
        XCTAssertTrue(row.isTombstoned)
        XCTAssertEqual(row.deletionOrigin, "source")
        XCTAssertNil(row.sourceBundleIdentifier)
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
    }

    func testCancelledHistoricalSourceBackfillResumesFromPersistedQueue() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-100)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        fixture.health.all = [workout]
        let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                          duration: 600, workoutType: "Running", tss: 25,
                          calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
        fixture.context.insert(row)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        try fixture.context.save()
        fixture.health.pauseNextIdentity = true
        var finished = false
        let task = Task { defer { finished = true }; try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.identityGate?.release(); task.cancel() }
        try await waitForSyncTestCondition("historical source query") { fixture.health.identityGate?.isWaiting == true || finished }
        guard let gate = fixture.health.identityGate else { XCTFail("Query did not pause"); return }
        task.cancel()
        gate.release()
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(state.healthKitSourceBackfillVersion, 1)
        XCTAssertEqual(state.pendingHealthKitSourceBackfillIDs, [row.id])
        XCTAssertNil(row.sourceBundleIdentifier)
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(row.sourceBundleIdentifier)
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
    }

    func testHistoricalSourceBackfillNeverRestoresUserDeletedWorkout() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-100)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        fixture.health.all = [workout]
        let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                          duration: 600, workoutType: "Running", tss: 25,
                          calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
        row.isTombstoned = true
        row.deletionOrigin = "user"
        row.isSuppressed = true
        fixture.context.insert(row)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(row.sourceBundleIdentifier)
        XCTAssertTrue(row.isTombstoned)
        XCTAssertTrue(row.isSuppressed)
        XCTAssertEqual(row.deletionOrigin, "user")
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
    }

    func testHistoricalSourceBackfillPreservesManufacturerWhenDeviceIsUnavailable() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-100)
        let workout = HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(600))
        XCTAssertNil(workout.device?.manufacturer)
        fixture.health.all = [workout]
        let row = Workout(id: workout.uuid.uuidString, date: start.startOfDay, startTime: start,
                          duration: 600, workoutType: "Running", tss: 25,
                          calculationMethod: "duration", source: .healthKit, healthKitUUID: workout.uuid.uuidString)
        row.deviceManufacturer = "Garmin"
        fixture.context.insert(row)
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(row.sourceBundleIdentifier)
        XCTAssertEqual(row.deviceManufacturer, "Garmin")
        XCTAssertTrue(state.pendingHealthKitSourceBackfillIDs.isEmpty)
    }

    func testSavedHealthKitProvenanceRecoversOnlyMatchingUnambiguousBundleOffline() async throws {
        let fixture = try SyncFixture()
        let initial = fixture.clock.now.addingDays(-100).startOfDay.addingTimeInterval(3600)
        var legacy: [Workout] = []
        for index in 0..<3 {
            let start = initial.addingDays(index)
            let id = UUID().uuidString
            let row = Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                              workoutType: "Running", tss: 25, calculationMethod: "duration",
                              source: .healthKit, healthKitUUID: id)
            var features = WorkoutFeatures()
            if index == 0 { features.provenance = ["HealthKit source: com.garmin.connect.mobile; workout: \(id)"] }
            if index == 1 { features.provenance = ["HealthKit source: com.garmin.connect.mobile; workout: \(UUID().uuidString)"] }
            if index == 2 { features.provenance = ["HealthKit source: com.garmin.connect.mobile; workout: \(id)",
                                                   "HealthKit source: com.example.other; workout: \(id)"] }
            row.features = features
            fixture.context.insert(row)
            legacy.append(row)
        }
        let target = try XCTUnwrap(legacy.first)
        let strava = Workout(id: "offline-strava", date: target.date, startTime: target.startTime,
                             duration: 600, workoutType: "Run", tss: 35,
                             calculationMethod: "duration", source: .strava)
        target.isSuppressed = true
        target.linkedSessionID = strava.id
        target.sessionGroupID = target.id
        strava.sessionGroupID = target.id
        fixture.context.insert(strava)
        let state = try fixture.store.fetchAppState()
        state.lastComputationDate = fixture.clock.now
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        fixture.health.failChanges = true
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(target.sourceBundleIdentifier, "com.garmin.connect.mobile")
        XCTAssertNil(target.deviceManufacturer)
        XCTAssertNil(legacy[1].sourceBundleIdentifier, "A different UUID must not prove provenance")
        XCTAssertNil(legacy[2].sourceBundleIdentifier, "Conflicting provenance must stay unresolved")
        XCTAssertEqual(Set(state.pendingHealthKitSourceBackfillIDs), Set(legacy.map(\.id)))
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: target.date)?.totalTSS, 25)
        XCTAssertTrue(fixture.health.identityRequests.isEmpty)
        XCTAssertTrue(fixture.engine.lastSyncHadWarnings)
    }

    func testPartialSourceSyncDefersIrreversibleEffectsUntilAmbiguityIsKnown() async throws {
        let fixture = try SyncFixture()
        let date = fixture.clock.now.addingDays(-1)
        let health = fixture.health.addWorkout(at: date)
        let deleted = Workout(id: health.uuid.uuidString, date: date.startOfDay, startTime: date, duration: 600,
                              workoutType: "Running", tss: 20, calculationMethod: "duration", source: .healthKit,
                              healthKitUUID: health.uuid.uuidString)
        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        deleted.userTags = ["personal"]
        let existing = Workout(id: "81", date: date.startOfDay, startTime: date, duration: 600,
                               workoutType: "Run", tss: 30, calculationMethod: "duration", source: .strava,
                               stravaId: 81)
        fixture.context.insert(deleted)
        fixture.context.insert(existing)
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        fixture.strava.listed = [try activity(id: 81, at: date), try activity(id: 82, at: date)]
        fixture.strava.failList = true
        try fixture.context.save()

        try await fixture.engine.incrementalUpdate()
        let state = try fixture.store.fetchAppState()
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        XCTAssertFalse(state.isComputationInProgress)
        XCTAssertFalse(existing.isTombstoned)
        XCTAssertEqual(deleted.userTags, ["personal"])
        XCTAssertTrue(existing.userTags.isEmpty)
        try fixture.store.reconcileWorkoutSources()
        try await fixture.store.refreshV2Estimates()
        XCTAssertFalse(existing.isTombstoned)
        XCTAssertEqual(deleted.userTags, ["personal"])

        let next = fixture.health.addWorkout(at: date.addingTimeInterval(3600))
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertNotNil(try fixture.store.fetchWorkout(byId: next.uuid.uuidString))
        XCTAssertTrue(state.pendingWorkoutSourceFinalization)
        fixture.strava.failList = false
        try await fixture.engine.incrementalUpdate()
        XCTAssertFalse(state.pendingWorkoutSourceFinalization)
        XCTAssertFalse(existing.isTombstoned)
        XCTAssertFalse(try XCTUnwrap(fixture.store.fetchWorkout(byId: "82")).isTombstoned)
        XCTAssertTrue(deleted.isTombstoned)
        XCTAssertEqual(deleted.userTags, ["personal"])
    }

    func testRemovalAndManualLinkWaitUntilSyncCompletes() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-2)
        let imported = Workout(id: "guard-hk", date: start.startOfDay, startTime: start,
                               duration: 600, workoutType: "Strength", tss: 10,
                               calculationMethod: "duration", source: .healthKit)
        try fixture.store.saveWorkout(imported)
        let store = V2Store(context: fixture.context, clock: { fixture.clock.now })
        let manual = try store.createStrengthSession(start: start, duration: 600)
        let set = StrengthSetRecord(sessionID: manual.id, exerciseID: "squat", reps: 8, weightKG: 0)
        fixture.context.insert(set)
        let state = try fixture.store.fetchAppState()
        state.isComputationInProgress = true
        try fixture.context.save()
        XCTAssertThrowsError(try fixture.store.deleteWorkout(imported)) { error in
            XCTAssertTrue(error is WorkoutMutationError)
            XCTAssertTrue(error.localizedDescription.contains("try again"))
        }
        do { try await store.deleteSession(imported); XCTFail("Removal must wait for sync") }
        catch is WorkoutMutationError { }
        XCTAssertThrowsError(try store.linkSession(manual: manual, to: imported)) { error in
            XCTAssertTrue(error is WorkoutMutationError)
        }
        XCTAssertFalse(imported.isTombstoned)
        XCTAssertNil(manual.linkedSessionID)
        XCTAssertEqual(set.sessionID, manual.id)
        state.isComputationInProgress = false
        state.pendingWorkoutSourceFinalization = true
        try fixture.context.save()
        XCTAssertThrowsError(try fixture.store.deleteWorkout(imported)) { XCTAssertTrue($0 is WorkoutMutationError) }
        do { try await store.deleteSession(imported); XCTFail("Removal must wait for source recovery") }
        catch is WorkoutMutationError { }
        XCTAssertThrowsError(try store.linkSession(manual: manual, to: imported)) { XCTAssertTrue($0 is WorkoutMutationError) }
        XCTAssertFalse(imported.isTombstoned)
        XCTAssertEqual(set.sessionID, manual.id)
        state.pendingWorkoutSourceFinalization = false
        try fixture.context.save()
        try store.linkSession(manual: manual, to: imported)
        XCTAssertEqual(set.sessionID, imported.id)
        try await store.deleteSession(imported)
        XCTAssertTrue(imported.isTombstoned)
    }

    func testConcurrentEstimateRefreshDoesNotMoveAliasesDuringImport() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-2)
        let health = Workout(id: "alias-hk", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Strength", tss: 10,
                             calculationMethod: "duration", source: .healthKit)
        let strava = Workout(id: "alias-strava", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Strength", tss: 10,
                             calculationMethod: "duration", source: .strava)
        try fixture.store.saveWorkouts([health, strava])
        let row = StrengthSetRecord(sessionID: health.id, exerciseID: "squat", reps: 8, weightKG: 0)
        fixture.context.insert(row)
        let state = try fixture.store.fetchAppState()
        state.isComputationInProgress = true
        try fixture.context.save()
        try await V2Store(context: fixture.context).refreshEstimates()
        XCTAssertEqual(row.sessionID, health.id)
        try await fixture.store.refreshV2Estimates()
        XCTAssertEqual(row.sessionID, health.id)
    }

    func testAmbiguityInLaterImportBatchDoesNotDeleteEarlierSource() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-2)
        let deleted = Workout(id: "deleted-hk", date: start.startOfDay, startTime: start,
                              duration: 600, workoutType: "Running", tss: 10,
                              calculationMethod: "duration", source: .healthKit)
        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        try fixture.store.saveWorkout(deleted)
        let earlier = Workout(id: "new-strava", date: start.startOfDay, startTime: start,
                              duration: 600, workoutType: "Run", tss: 20,
                              calculationMethod: "duration", source: .strava)
        let filler = (0..<19).map { index in
            Workout(id: "filler-\(index)", date: start.startOfDay,
                    startTime: start.addingTimeInterval(Double(3600 * (index + 1))),
                    duration: 600, workoutType: "Running", tss: 1,
                    calculationMethod: "duration", source: .healthKit)
        }
        let later = Workout(id: "later-hk", date: start.startOfDay, startTime: start,
                            duration: 600, workoutType: "Running", tss: 30,
                            calculationMethod: "duration", source: .healthKit)
        _ = try await fixture.store.applyImportedWorkouts([earlier] + filler + [later], deletedIDs: [])
        XCTAssertFalse(try XCTUnwrap(fixture.store.fetchWorkout(byId: earlier.id)).isTombstoned)
        XCTAssertFalse(try XCTUnwrap(fixture.store.fetchWorkout(byId: later.id)).isSuppressed)
        XCTAssertTrue(try XCTUnwrap(fixture.store.fetchWorkout(byId: deleted.id)).isTombstoned)
    }

    func testInterruptedBatchKeepsTagsUntilCompleteReconciliation() async throws {
        let fixture = try SyncFixture()
        let start = fixture.clock.now.addingDays(-2)
        let original = Workout(id: "tagged-hk", date: start.startOfDay, startTime: start,
                               duration: 600, workoutType: "Running", tss: 10,
                               calculationMethod: "duration", source: .healthKit)
        original.userTags = ["test-tag"]
        try fixture.store.saveWorkout(original)
        let earlier = Workout(id: "tag-strava", date: start.startOfDay, startTime: start,
                              duration: 600, workoutType: "Run", tss: 20,
                              calculationMethod: "duration", source: .strava)
        _ = try fixture.store.saveWorkouts([earlier], reconcileSideEffects: false)
        XCTAssertEqual(original.userTags, ["test-tag"])
        XCTAssertTrue(earlier.userTags.isEmpty)
        // A cancelled continuation must not finalize the partial batch.
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.store.applyImportedWorkouts([earlier], deletedIDs: [])
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(original.userTags, ["test-tag"])
        let later = Workout(id: "tag-later-hk", date: start.startOfDay, startTime: start,
                            duration: 600, workoutType: "Running", tss: 30,
                            calculationMethod: "duration", source: .healthKit)
        _ = try await fixture.store.applyImportedWorkouts([earlier, later], deletedIDs: [])
        XCTAssertEqual(original.userTags, ["test-tag"])
        XCTAssertTrue(earlier.userTags.isEmpty)
        XCTAssertFalse(original.isSuppressed)
        XCTAssertFalse(earlier.isSuppressed)
    }

    func testHistoricalOtherTypesBackfillByIdentityOnceAndPreserveData() async throws {
        let fixture = try SyncFixture()
        let date = fixture.clock.now.addingDays(-45).startOfDay.addingTimeInterval(10 * 3600)
        let hike = HKWorkout(activityType: .hiking, start: date, end: date.addingTimeInterval(600))
        let unknown = HKWorkout(activityType: .basketball, start: date.addingTimeInterval(3600), end: date.addingTimeInterval(4200))
        fixture.health.all = [hike, unknown]
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        for item in [hike, unknown] {
            let row = Workout(id: item.uuid.uuidString, date: item.startDate.startOfDay, startTime: item.startDate,
                              duration: item.duration, workoutType: "Other", tss: 17, calculationMethod: "duration",
                              source: .healthKit, healthKitUUID: item.uuid.uuidString)
            row.userTags = ["personal"]
            fixture.context.insert(row)
        }
        fixture.context.insert(Workout(id: "historical-strava-hike", date: date.startOfDay, startTime: date,
            duration: 600, workoutType: "Hike", tss: 30, calculationMethod: "duration", source: .strava))
        let note = LocalObservation(regionRaw: "quads", sessionID: hike.uuid.uuidString)
        fixture.context.insert(note)
        try fixture.context.save()
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(try fixture.store.fetchWorkout(byId: hike.uuid.uuidString)?.workoutType, "Hiking")
        XCTAssertTrue(try XCTUnwrap(fixture.store.fetchWorkout(byId: hike.uuid.uuidString)).isSuppressed)
        XCTAssertEqual(try fixture.store.fetchDayAggregate(for: date)?.workoutCount, 2)
        XCTAssertEqual(try fixture.store.fetchWorkout(byId: unknown.uuid.uuidString)?.workoutType, "Other")
        let savedHike = try XCTUnwrap(fixture.store.fetchWorkout(byId: hike.uuid.uuidString))
        let canonical = try XCTUnwrap(fixture.store.fetchWorkout(byId: "historical-strava-hike"))
        XCTAssertEqual(savedHike.userTags, ["personal"])
        XCTAssertTrue(canonical.userTags.isEmpty)
        XCTAssertEqual(savedHike.linkedSessionID, canonical.id)
        XCTAssertEqual(note.sessionID, savedHike.id)
        let graph = WorkoutLinkGraph(try fixture.store.allWorkouts().map { .init(id: $0.id, parentID: $0.linkedSessionID) })
        XCTAssertTrue(graph.relatedIDs(to: canonical.id).contains(try XCTUnwrap(note.sessionID)))
        let pending = try V2EstimateBatch(context: fixture.context, includePrevious: false).calculate(now: fixture.clock.now)
        let estimate = try XCTUnwrap(pending.first { $0.sessionID == canonical.id })
        let estimateInput = try XCTUnwrap(JSONSerialization.jsonObject(with: estimate.inputData) as? [String: Any])
        XCTAssertEqual(estimateInput["tags"] as? [String], ["personal"])
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<LocalObservation>()).first?.id, note.id)
        XCTAssertEqual(state.healthKitTypeBackfillVersion, 1)
        XCTAssertTrue(state.pendingHealthKitTypeBackfillIDs.isEmpty)
        XCTAssertEqual(fixture.health.identityRequests.count, 2) // Type and source metadata are independently backfilled.
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertTrue(fixture.health.featureRequests.isEmpty)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests.count, 2)
    }

    func testHistoricalTypeBackfillRetainsUnreadableRowsAndDoesNotRestoreDeletion() async throws {
        let fixture = try SyncFixture()
        let date = fixture.clock.now.addingDays(-30)
        let hike = HKWorkout(activityType: .hiking, start: date, end: date.addingTimeInterval(600))
        fixture.health.all = [hike]
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        let row = Workout(id: hike.uuid.uuidString, date: date.startOfDay, startTime: date, duration: 600,
                          workoutType: "Other", tss: 20, calculationMethod: "duration", source: .healthKit,
                          healthKitUUID: hike.uuid.uuidString)
        fixture.context.insert(row)
        try fixture.context.save()
        fixture.health.failIdentity = true
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.pendingHealthKitTypeBackfillIDs, [row.id])
        fixture.health.failIdentity = false
        fixture.health.identityUnavailable = true
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(state.pendingHealthKitTypeBackfillIDs, [row.id])
        XCTAssertEqual(row.workoutType, "Other")
        fixture.health.identityUnavailable = false
        fixture.health.deleted = [row.id]
        try await fixture.engine.incrementalUpdate()
        XCTAssertTrue(row.isTombstoned)
        XCTAssertEqual(row.deletionOrigin, "source")
        XCTAssertEqual(row.workoutType, "Other")
        XCTAssertTrue(state.pendingHealthKitTypeBackfillIDs.isEmpty)
    }

    func testCancelledHistoricalTypeBackfillRetries() async throws {
        let fixture = try SyncFixture()
        let date = fixture.clock.now.addingDays(-30)
        let hike = HKWorkout(activityType: .hiking, start: date, end: date.addingTimeInterval(600))
        fixture.health.all = [hike]
        let state = try fixture.store.fetchAppState()
        state.healthKitAnchor = fixture.health.encodeAnchor(HKQueryAnchor(fromValue: 1))
        state.lastHealthKitSampleRefreshDate = fixture.clock.now
        let row = Workout(id: hike.uuid.uuidString, date: date.startOfDay, startTime: date, duration: 600,
                          workoutType: "Other", tss: 20, calculationMethod: "duration", source: .healthKit,
                          healthKitUUID: hike.uuid.uuidString)
        fixture.context.insert(row)
        try fixture.context.save()
        fixture.health.pauseNextIdentity = true
        var finished = false
        let task = Task { defer { finished = true }; try await fixture.engine.incrementalUpdate() }
        defer { fixture.health.identityGate?.release(); task.cancel() }
        try await waitForSyncTestCondition("historical type query") { fixture.health.identityGate?.isWaiting == true || finished }
        guard let gate = fixture.health.identityGate else { XCTFail("Query did not pause"); return }
        task.cancel()
        gate.release()
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { throw error }
        XCTAssertEqual(state.healthKitTypeBackfillVersion, 0)
        XCTAssertEqual(row.workoutType, "Other")
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(row.workoutType, "Hiking")
        XCTAssertTrue(state.pendingHealthKitTypeBackfillIDs.isEmpty)
    }

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
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
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
        XCTAssertTrue(fixture.engine.lastSyncRequiresRetry)
        XCTAssertNotNil(state.healthKitAnchor)
        fixture.health.failFeatures = []
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        try await fixture.engine.incrementalUpdate()
        XCTAssertEqual(fixture.health.identityRequests, [[old.uuid.uuidString]])
        XCTAssertTrue(fixture.health.rangeRequests.isEmpty)
        XCTAssertTrue(state.pendingHealthKitWorkoutIDs.isEmpty)
        XCTAssertFalse(fixture.engine.lastSyncRequiresRetry)
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

    func testInterruptedRecoveryRequiresAllConnectedSourcesBeforeFinalizing() async throws {
        let fixture = try SyncFixture()
        try fixture.store.saveStravaAuth(StravaAuth(isConnected: true))
        try await fixture.engine.incrementalUpdate()
        let state = try fixture.store.fetchAppState()
        let anchor = state.healthKitAnchor
        let auth = try XCTUnwrap(fixture.store.fetchStravaAuth())
        let stravaDate = auth.lastSyncDate
        let start = fixture.clock.now.addingDays(-2)
        let health = Workout(id: "recover-deleted", date: start.startOfDay, startTime: start,
                             duration: 600, workoutType: "Running", tss: 10,
                             calculationMethod: "duration", source: .healthKit)
        health.isTombstoned = true
        health.deletionOrigin = "user"
        try fixture.store.saveWorkout(health)
        let candidate = Workout(id: "recover-strava", date: start.startOfDay, startTime: start,
                                duration: 600, workoutType: "Run", tss: 10,
                                calculationMethod: "duration", source: .strava)
        state.isComputationInProgress = true
        try fixture.store.saveWorkouts([candidate], reconcileSideEffects: false)
        fixture.health.failChanges = true
        fixture.clock.now = fixture.clock.now.addingTimeInterval(60)
        do { try await fixture.engine.incrementalUpdate(); XCTFail("Expected retryable recovery failure") }
        catch EngineError.interruptedRecoveryUnavailable { }
        XCTAssertTrue(state.isComputationInProgress)
        XCTAssertEqual(state.healthKitAnchor, anchor)
        XCTAssertEqual(auth.lastSyncDate, stravaDate)
        XCTAssertFalse(candidate.isTombstoned)
        fixture.health.failChanges = false
        fixture.strava.failList = true
        do { try await fixture.engine.incrementalUpdate(); XCTFail("Expected retryable recovery failure") }
        catch EngineError.interruptedRecoveryUnavailable { }
        XCTAssertTrue(state.isComputationInProgress)
        XCTAssertEqual(state.healthKitAnchor, anchor)
        XCTAssertEqual(auth.lastSyncDate, stravaDate)
        XCTAssertFalse(candidate.isTombstoned)
        fixture.strava.failList = false
        try await fixture.engine.incrementalUpdate()
        XCTAssertFalse(state.isComputationInProgress)
        XCTAssertTrue(candidate.isTombstoned)
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

    func testManualSyncWaitsForRunningAutomaticSyncAndFetchesNewChanges() async throws {
        let fixture = try SyncFixture()
        let firstWorkout = fixture.health.addWorkout(at: fixture.clock.now.addingTimeInterval(-1800))
        fixture.health.pauseNextChange = true
        var automaticFinished = false
        let automatic = Task { defer { automaticFinished = true }; try Task.checkCancellation(); try await fixture.engine.incrementalUpdate() }
        defer {
            fixture.health.pauseNextChange = false
            fixture.health.changesGate?.release()
            automatic.cancel()
        }
        try await waitForSyncTestCondition("automatic import to reach its source gate") {
            fixture.health.changesGate?.isWaiting == true || automaticFinished
        }
        if automaticFinished {
            try await automatic.value
            XCTFail("Automatic sync completed without reaching its source gate")
            return
        }

        let laterWorkout = fixture.health.addWorkout(at: fixture.clock.now.addingTimeInterval(-900))
        var manualStarted = false
        var manualCompleted = false
        var manualFinished = false
        let manual = Task {
            defer { manualFinished = true }
            try Task.checkCancellation()
            manualStarted = true
            try await fixture.engine.recomputeAll()
            manualCompleted = true
        }
        defer { manual.cancel() }
        try await waitForSyncTestCondition("manual sync request to start") { manualStarted }
        await Task.yield()
        XCTAssertFalse(manualCompleted)
        XCTAssertEqual(fixture.health.anchors.count, 1)
        fixture.health.changesGate?.release()
        try await waitForSyncTestCondition("automatic and manual sync requests to finish") {
            automaticFinished && manualFinished
        }
        try await automatic.value
        try await manual.value

        XCTAssertEqual(fixture.health.anchors.count, 2)
        XCTAssertNotNil(fixture.health.anchors.last!)
        XCTAssertNotNil(try fixture.store.fetchWorkout(byId: firstWorkout.uuid.uuidString))
        XCTAssertNotNil(try fixture.store.fetchWorkout(byId: laterWorkout.uuid.uuidString))
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
    var identityUnavailable = false
    var failIdentity = false
    var pauseNextIdentity = false
    var identityGate: SyncTestGate?
    var physiologyStarts: [Date] = []
    var failChanges = false
    var failRange = false
    var failFeatures: Set<String> = []
    var sampleCount = 1
    var onRecoveryRead: (() -> Void)?
    var pauseNextChange = false
    var changesGate: SyncTestGate?

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
        if pauseNextChange {
            pauseNextChange = false
            let gate = SyncTestGate()
            changesGate = gate
            await gate.wait()
            changesGate = nil
        }
        return (result, deleted, HKQueryAnchor(fromValue: anchors.count))
    }
    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        rangeRequests.append(startDate)
        if failRange { throw URLError(.notConnectedToInternet) }
        return recent
    }
    override func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] {
        identityRequests.append(ids)
        if failIdentity { throw URLError(.notConnectedToInternet) }
        if pauseNextIdentity {
            pauseNextIdentity = false
            let gate = SyncTestGate()
            identityGate = gate
            await gate.wait()
            identityGate = nil
        }
        return identityUnavailable ? [] : all.filter { ids.contains($0.uuid.uuidString) }
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
    var failDetail = false
    nonisolated deinit {}
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity] {
        windows.append(Window(after: after, before: before, page: page))
        if failList { throw URLError(.notConnectedToInternet) }
        return listed.filter { ($0.startDateTime ?? .distantPast) > after && ($0.startDateTime ?? .distantFuture) < before }
    }
    func activity(accessToken: String, id: Int) async throws -> StravaActivity? {
        if failDetail { throw URLError(.notConnectedToInternet) }
        return listed.first { $0.id == id }
    }
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
