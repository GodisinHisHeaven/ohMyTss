import XCTest
import SwiftData
@testable import onMyTss

/// Synthetic records only. These tests require Apple's real SwiftData runtime.
@MainActor
final class V2PersistenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func imported(id: String = "synthetic-hk", source: WorkoutSource = .healthKit,
                          tss: Double = 25) -> Workout {
        let workout = Workout(id: id, date: Calendar.current.startOfDay(for: start),
                              startTime: start, duration: 600, workoutType: "Strength",
                              tss: tss, calculationMethod: "hr", source: source,
                              healthKitUUID: source == .healthKit ? id : nil)
        var features = WorkoutFeatures()
        features.heartRate = (0..<60).map { index in
            let sampleStart = start.addingTimeInterval(Double(index * 10))
            return TimedValue(start: sampleStart, end: sampleStart.addingTimeInterval(10), value: 150)
        }
        features.end = start.addingTimeInterval(600)
        features.provenance = ["Synthetic unit-test samples"]
        workout.features = features
        return workout
    }

    private func latest(_ context: ModelContext, sessionID: String) throws -> LoadEstimateRecord {
        let estimates = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
            .filter { $0.sessionID == sessionID }
            .sorted { $0.computedAt > $1.computedAt }
        return try XCTUnwrap(estimates.first)
    }

    func testImportedSessionSetsAndRepeatedSyncRetainUserRecords() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        let thresholds = try dataStore.fetchUserThresholds()
        thresholds.maxHeartRate = 190
        thresholds.cardioMaxHeartRate = 190
        try dataStore.saveUserThresholds(thresholds)
        try dataStore.saveWorkouts([imported()])
        let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        session.userTags = ["Synthetic test tag"]
        try store.recalculate(session)
        let cardioBefore = try latest(context, sessionID: session.id).value?.cardio?.points
        let row = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 8, weightKG: 40, rir: 0)
        try store.saveSet(row)
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2,
                                           observedAt: start.addingTimeInterval(7200), sessionID: session.id)
        try store.saveObservation(observation)
        try dataStore.saveWorkouts([imported()])
        try dataStore.saveWorkouts([imported(tss: 30)])
        let reread = try XCTUnwrap(dataStore.fetchWorkout(byId: session.id))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 1)
        XCTAssertEqual(reread.userTags, ["Synthetic test tag"])
        XCTAssertEqual(row.rir, 0)
        XCTAssertEqual(reread.tss, 30)
        try store.recalculate(reread)
        XCTAssertNotNil(cardioBefore)
        XCTAssertEqual(try latest(context, sessionID: session.id).value?.cardio?.points, cardioBefore,
                       "Adding manual strength detail must not add cardio a second time")
    }

    func testManualThenImportedExplicitLinkHasOneContributionAndRetainsDetails() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        let manual = try store.createStrengthSession(start: start, duration: 600)
        let row = StrengthSetRecord(sessionID: manual.id, exerciseID: "squat", reps: 5, weightKG: 50)
        try store.saveSet(row)
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "right", severity: 1,
                                           observedAt: start, sessionID: manual.id)
        try store.saveObservation(observation)
        try dataStore.saveWorkouts([imported()])
        let external = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        try store.linkSession(manual: manual, to: external)
        try dataStore.saveWorkouts([imported()])
        let active = try context.fetch(FetchDescriptor<Workout>()).filter { !$0.isTombstoned && !$0.isSuppressed }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, external.id)
        XCTAssertEqual(row.sessionID, external.id)
        XCTAssertEqual(observation.sessionID, external.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 1)
    }

    func testSetMutationUpdatesEstimateWithoutDeletingPriorSnapshot() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let session = try store.createStrengthSession(start: start, duration: 600)
        let row = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 5, weightKG: 20, rir: 0)
        try store.saveSet(row)
        let initial = try latest(context, sessionID: session.id)
        let initialData = initial.inputData
        row.reps = 20
        row.weightKG = 30
        try store.saveSet(row)
        let edited = try latest(context, sessionID: session.id)
        XCTAssertNotEqual(initial.id, edited.id)
        XCTAssertNotEqual(initialData, edited.inputData)
        XCTAssertEqual(initial.inputData, initialData)
        let originalExposure = try XCTUnwrap(initial.value?.regions.first { $0.region == .quads }?.exposure)
        let editedExposure = try XCTUnwrap(edited.value?.regions.first { $0.region == .quads }?.exposure)
        XCTAssertGreaterThan(editedExposure, originalExposure)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).first?.reps, 20)
        try store.deleteSet(row)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StrengthSetRecord>()).isEmpty)
        XCTAssertNotEqual(try latest(context, sessionID: session.id).inputData, edited.inputData)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).contains { $0.id == initial.id })
    }

    func testObservationZeroMissingSidesAndBackdateRemainDistinct() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let left = LocalObservation(regionRaw: "calves", sideRaw: "left", severity: 0, observedAt: start)
        let right = LocalObservation(regionRaw: "calves", sideRaw: "right", severity: nil, observedAt: start)
        right.tightness = true
        try store.saveObservation(left)
        try store.saveObservation(right)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 2)
        XCTAssertEqual(left.severity, 0)
        XCTAssertNil(right.severity)
        XCTAssertNotEqual(left.sideRaw, right.sideRaw)
        XCTAssertLessThan(left.observedAt, left.recordedAt)
        let originalRecordedAt = right.recordedAt
        right.severity = 3
        right.discomfortRaw = "jointPain"
        try store.saveObservation(right)
        XCTAssertEqual(right.recordedAt, originalRecordedAt)
        XCTAssertGreaterThanOrEqual(right.updatedAt, right.recordedAt)
        try store.deleteObservation(left)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).map(\.id), [right.id])
    }

    func testDeleteSessionRemovesContributionButRetainsUserHistory() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        try dataStore.saveWorkouts([imported()])
        let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        try store.saveSet(StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 5))
        try store.saveObservation(LocalObservation(regionRaw: "quads", severity: 2, sessionID: session.id))
        try await store.deleteSession(session)
        XCTAssertTrue(session.isTombstoned)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 1)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Workout>()).contains { !$0.isTombstoned && !$0.isSuppressed })
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS ?? 0, 0)
        try dataStore.saveWorkouts([imported()])
        XCTAssertTrue(try XCTUnwrap(dataStore.fetchWorkout(byId: session.id)).isTombstoned,
                      "A user's local tombstone must survive a repeated external snapshot")
    }

    func testCrossMidnightSessionUsesLocalStartDayAndRetainsAbsoluteTime() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let calendar = Calendar.current
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 11, day: 3, hour: 23, minute: 55)))
        let session = try store.createStrengthSession(start: late, duration: 1200)
        XCTAssertEqual(session.startTime, late)
        XCTAssertEqual(session.date, calendar.startOfDay(for: late))
        XCTAssertNotEqual(calendar.startOfDay(for: late.addingTimeInterval(session.duration)), session.date)
        let reloaded = try XCTUnwrap(context.fetch(FetchDescriptor<Workout>()).first)
        XCTAssertEqual(reloaded.startTime.timeIntervalSince1970, late.timeIntervalSince1970)
        XCTAssertEqual(reloaded.duration, 1200)
    }

    func testRepeatedEstimationWithSameInputIsIdempotent() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let session = try store.createStrengthSession(start: start, duration: 600)
        try store.saveSet(StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 8))
        let before = try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count
        try store.recalculate(session)
        try store.recalculate(session)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, before)
    }

    func testBackfillKeepsCurrentSnapshotsAndUpgradesOnlyMissingOrOldEstimates() async throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let current = imported(id: "current")
        let missing = imported(id: "missing")
        let outdated = imported(id: "outdated")
        let suppressed = imported(id: "suppressed")
        suppressed.isSuppressed = true
        let deleted = imported(id: "deleted")
        deleted.isTombstoned = true
        for row in [current, missing, outdated, suppressed, deleted] { context.insert(row) }
        try store.recalculate(current)
        let original = try latest(context, sessionID: current.id)
        let originalPayload = original.payloadData
        let old = LoadEstimateRecord(sessionID: outdated.id, version: "old-model", inputCutoff: start,
                                     computedAt: start, payloadData: Data(), inputData: Data())
        context.insert(old)
        try context.save()

        try await store.backfillEstimates()

        let snapshots = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(try latest(context, sessionID: current.id).id, original.id)
        XCTAssertEqual(original.payloadData, originalPayload)
        XCTAssertEqual(try latest(context, sessionID: missing.id).version, LoadModel.version)
        XCTAssertEqual(try latest(context, sessionID: outdated.id).version, LoadModel.version)
        XCTAssertTrue(snapshots.contains { $0.id == old.id })
        XCTAssertFalse(snapshots.contains { $0.sessionID == suppressed.id || $0.sessionID == deleted.id })
        XCTAssertEqual(missing.tss, 25)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 5)
        try await store.backfillEstimates()
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, 4)
    }

    func testBackfillCompletesInterruptedHeartRateUpdateAfterDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("interrupted.store")
        func seedPartialUpdate() throws -> Set<UUID> {
            let context = ModelContext(try container(url: url))
            let dataStore = DataStore(modelContext: context)
            let store = V2Store(context: context)
            let thresholds = try dataStore.fetchUserThresholds()
            thresholds.cardioMaxHeartRate = 190
            try dataStore.saveUserThresholds(thresholds)
            let first = imported(id: "finished")
            let second = imported(id: "interrupted")
            context.insert(first)
            context.insert(second)
            try store.recalculate(first)
            try store.recalculate(second)
            thresholds.cardioMaxHeartRate = 180
            try dataStore.saveUserThresholds(thresholds)
            // Simulate termination after only the first session has been updated.
            try store.recalculate(first)
            return Set(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).map(\.id))
        }
        let oldIDs = try seedPartialUpdate()
        let context = ModelContext(try container(url: url))
        let store = V2Store(context: context)
        try await store.backfillEstimates()
        let rows = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(rows.count, 4, "Only the unfinished session needs a new snapshot")
        XCTAssertTrue(oldIDs.isSubset(of: Set(rows.map(\.id))))
        XCTAssertEqual(try latest(context, sessionID: "finished").value?.cardio?.points,
                       try latest(context, sessionID: "interrupted").value?.cardio?.points)
        try await store.backfillEstimates()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 4)
    }

    func testBackfillAllowsMainActorCancellationAndResumesWithoutDuplicateSnapshots() async throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        for index in 0..<300 { context.insert(imported(id: "cancel-\(index)")) }
        try context.save()
        let task = Task { try await store.backfillEstimates() }
        // This main-actor continuation must run while backfill still has work.
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            try await task.value
            XCTFail("Backfill should yield before processing the entire history")
        } catch is CancellationError {}
        let saved = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertLessThan(saved.count, 300)
        let savedIDs = Set(saved.map(\.id))

        try await store.backfillEstimates()
        let resumed = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(resumed.count, 300)
        XCTAssertTrue(savedIDs.isSubset(of: Set(resumed.map(\.id))))
    }

    func testResetAllDataClearsPendingSourceBackfillsAndFinalization() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let state = try dataStore.fetchAppState()
        state.healthKitTypeBackfillVersion = 1
        state.pendingHealthKitTypeBackfillIDs = ["old-type-uuid"]
        state.healthKitSourceBackfillVersion = 1
        state.pendingHealthKitSourceBackfillIDs = ["old-source-uuid"]
        state.pendingWorkoutSourceFinalization = true
        try dataStore.saveWorkout(imported())
        try dataStore.deleteAllWorkouts()
        try dataStore.resetAppState()

        let reset = try dataStore.fetchAppState()
        XCTAssertEqual(reset.healthKitTypeBackfillVersion, 0)
        XCTAssertTrue(reset.pendingHealthKitTypeBackfillIDs.isEmpty)
        XCTAssertEqual(reset.healthKitSourceBackfillVersion, 0)
        XCTAssertTrue(reset.pendingHealthKitSourceBackfillIDs.isEmpty)
        XCTAssertFalse(reset.pendingWorkoutSourceFinalization)
        XCTAssertNoThrow(try dataStore.ensureWorkoutMutationAllowed())
        XCTAssertTrue(try dataStore.allWorkouts().isEmpty)
    }

    func testCrossSourceDuplicateAndSourceDeletionKeepOneActiveContribution() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let hk = imported()
        try dataStore.saveWorkouts([hk])
        try dataStore.saveWorkouts([imported(id: "synthetic-strava", source: .strava, tss: 35)])
        try dataStore.rebuildLegacyLoadHistory(now: start.addingTimeInterval(600))
        let all = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(all.count, 2, "Keep both original source rows for audit")
        XCTAssertEqual(all.filter { !$0.isSuppressed && !$0.isTombstoned }.count, 1)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 35)
        try dataStore.applyHealthKitDeletions(["synthetic-hk"])
        XCTAssertEqual(all.filter { !$0.isSuppressed && !$0.isTombstoned }.count, 1)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 35,
                       "A deleted duplicate source must not delete the surviving source's contribution")
    }

    func testTemplateCopiesSetsWithNewIDsAndKeepsUnknownEffort() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let original = try store.createStrengthSession(start: start, duration: 600)
        let row = StrengthSetRecord(sessionID: original.id, exerciseID: "squat", reps: 8, weightKG: 0)
        try store.saveSet(row)
        try store.saveTemplate(name: "Synthetic lower-body template", sets: [row])
        let template = try XCTUnwrap(context.fetch(FetchDescriptor<StrengthTemplate>()).first)
        let next = try store.createStrengthSession(start: start.addingTimeInterval(3600), duration: 600)
        try store.applyTemplate(template, to: next)
        let copied = try XCTUnwrap(context.fetch(FetchDescriptor<StrengthSetRecord>()).first { $0.sessionID == next.id })
        XCTAssertNotEqual(copied.id, row.id)
        XCTAssertEqual(copied.exerciseID, "squat")
        XCTAssertEqual(copied.reps, 8)
        XCTAssertEqual(copied.weightKG, 0)
        XCTAssertNil(copied.rir)
        XCTAssertNil(copied.effortRaw)
        XCTAssertFalse(try latest(context, sessionID: next.id).value?.regions.isEmpty ?? true)
    }

    func testWalkAliasesStayDeduplicatedAcrossRepeatedSyncs() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        for _ in 0..<2 {
            let health = imported(id: "walk-hk", tss: 25)
            health.workoutType = "Walking"
            let strava = imported(id: "walk-strava", source: .strava, tss: 35)
            strava.workoutType = "Walk"
            try dataStore.saveWorkouts([health, strava])
            try dataStore.rebuildLegacyLoadHistory(now: start.addingTimeInterval(600))
        }
        let rows = try dataStore.allWorkouts()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.sessionGroupID)).count, 1)
        XCTAssertEqual(rows.filter { !$0.isSuppressed && !$0.isTombstoned }.map(\.id), ["walk-strava"])
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 35)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.workoutCount, 1)
    }

    func testGarminHealthKitWinsThreeSourceHistoricalGroupAndKeepsOneLoad() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let garmin = imported(id: "garmin-hk", tss: 45)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let apple = imported(id: "apple-hk", tss: 25)
        apple.sourceBundleIdentifier = "com.apple.Health"
        let strava = imported(id: "garmin-strava", source: .strava, tss: 35)
        for _ in 0..<2 {
            try store.saveWorkouts([apple, strava, garmin])
            try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        }
        let rows = try store.allWorkouts()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter { !$0.isSuppressed && !$0.isTombstoned }.map(\.id), [garmin.id])
        XCTAssertEqual(Set(rows.compactMap(\.sessionGroupID)).count, 1)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 1)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 45)
    }

    func testSameAppOrUnknownHealthKitSourceBlocksAmbiguousThreeWayMerge() throws {
        for secondBundle in ["com.apple.Health", nil] as [String?] {
            let context = ModelContext(try container())
            let store = DataStore(modelContext: context)
            let first = imported(id: "ambiguous-first", tss: 10)
            first.sourceBundleIdentifier = "com.apple.Health"
            let second = imported(id: "ambiguous-second", tss: 20)
            second.sourceBundleIdentifier = secondBundle
            let strava = imported(id: "ambiguous-strava", source: .strava, tss: 30)
            try store.saveWorkouts([first, strava, second])
            try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
            XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 3)
            XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 60)
        }
    }

    func testSourceCorrectionSplitsGarminGroupAndPreservesIndependentLoad() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let garmin = imported(id: "corrected-garmin", tss: 45)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let apple = imported(id: "corrected-apple", tss: 25)
        apple.sourceBundleIdentifier = "com.apple.Health"
        let strava = imported(id: "corrected-three-strava", source: .strava, tss: 35)
        try store.saveWorkouts([garmin, apple, strava])
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), [garmin.id])
        let corrected = imported(id: garmin.id, tss: 45)
        corrected.sourceBundleIdentifier = "com.apple.Health"
        let changes = try store.saveWorkouts([corrected])
        XCTAssertTrue(changes.dates.contains(start.startOfDay))
        try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 3)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 105)
    }

    func testMissingSourceMetadataOnRepeatedImportKeepsKnownGarminPriority() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let garmin = imported(id: "metadata-garmin", tss: 45)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        garmin.deviceManufacturer = "Garmin"
        garmin.deviceName = "Garmin watch"
        let strava = imported(id: "metadata-strava", source: .strava, tss: 35)
        try store.saveWorkouts([garmin, strava])
        let incomplete = imported(id: garmin.id, tss: 46)
        try store.saveWorkouts([incomplete])
        let saved = try XCTUnwrap(store.fetchWorkout(byId: garmin.id))
        XCTAssertEqual(saved.sourceBundleIdentifier, "com.garmin.connect.mobile")
        XCTAssertEqual(saved.deviceManufacturer, "Garmin")
        XCTAssertEqual(saved.deviceName, "Garmin watch")
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), [garmin.id])
        XCTAssertEqual(saved.tss, 46)
    }

    func testUnresolvedSourceDefersOnlyItsGroupAndAllowsUnrelatedDeletion() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let v2 = V2Store(context: context, clock: { self.start.addingTimeInterval(7200) })
        let state = try store.fetchAppState()
        let health = imported(id: "pending-group-hk")
        health.userTags = ["saved-tag"]
        let strava = imported(id: "pending-group-strava", source: .strava)
        let single = imported(id: "pending-single-hk")
        single.startTime = start.addingTimeInterval(3600)
        var features = single.features
        features.end = single.startTime.addingTimeInterval(600)
        single.features = features
        state.pendingHealthKitSourceBackfillIDs = [health.id, single.id]
        try store.saveWorkouts([health, strava, single])
        let set = StrengthSetRecord(sessionID: health.id, exerciseID: "squat", reps: 8, rir: 0)
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 1,
                                           observedAt: start, sessionID: health.id)
        context.insert(set)
        context.insert(observation)
        try context.save()
        try await v2.refreshEstimates()
        XCTAssertEqual(health.userTags, ["saved-tag"])
        XCTAssertTrue(strava.userTags.isEmpty)
        XCTAssertEqual(set.sessionID, health.id)
        XCTAssertEqual(observation.sessionID, health.id)
        XCTAssertThrowsError(try store.deleteWorkout(strava)) { XCTAssertTrue($0 is WorkoutMutationError) }
        do { try await v2.deleteSession(strava); XCTFail("Unresolved group deletion must wait") }
        catch is WorkoutMutationError { }
        let manual = try v2.createStrengthSession(start: start, duration: 600)
        XCTAssertThrowsError(try v2.linkSession(manual: manual, to: strava)) { XCTAssertTrue($0 is WorkoutMutationError) }
        try store.deleteWorkout(single)
        XCTAssertTrue(single.isTombstoned, "An unrelated unresolved singleton can still be deleted")

        state.pendingHealthKitSourceBackfillIDs = []
        _ = try store.finalizeWorkoutSources()
        try await v2.refreshEstimates()
        XCTAssertTrue(strava.userTags.isEmpty)
        XCTAssertEqual(health.userTags, ["saved-tag"])
        XCTAssertEqual(set.sessionID, health.id)
        XCTAssertEqual(observation.sessionID, health.id)
    }

    func testUnresolvedSourceDoesNotSpreadUserTombstoneUntilResolved() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let state = try store.fetchAppState()
        let health = imported(id: "pending-deleted-hk")
        health.isTombstoned = true
        health.deletionOrigin = "user"
        let strava = imported(id: "pending-deleted-strava", source: .strava)
        state.pendingHealthKitSourceBackfillIDs = [health.id]
        try store.saveWorkouts([health, strava])
        XCTAssertFalse(strava.isTombstoned)
        XCTAssertTrue(strava.isSuppressed)
        state.pendingHealthKitSourceBackfillIDs = []
        _ = try store.finalizeWorkoutSources()
        XCTAssertTrue(strava.isTombstoned)
        XCTAssertEqual(strava.deletionOrigin, "user")
    }

    func testGarminCanonicalSwitchAfterSourceDeletionRetainsPersonalRows() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let v2 = V2Store(context: context)
        let garmin = imported(id: "remove-garmin", tss: 45)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let apple = imported(id: "remove-apple", tss: 25)
        apple.sourceBundleIdentifier = "com.apple.Health"
        let strava = imported(id: "remove-strava", source: .strava, tss: 35)
        try store.saveWorkouts([garmin, apple, strava])
        let set = StrengthSetRecord(sessionID: garmin.id, exerciseID: "squat", reps: 8, rir: 0)
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 1,
                                           observedAt: start, sessionID: garmin.id)
        try v2.saveSet(set)
        try v2.saveObservation(observation)
        try store.applyHealthKitDeletions([garmin.id])
        try await v2.refreshEstimates()
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), [strava.id])
        XCTAssertEqual(set.sessionID, garmin.id)
        XCTAssertEqual(observation.sessionID, garmin.id)
        XCTAssertTrue(garmin.isTombstoned)
        XCTAssertFalse(apple.isTombstoned)
    }

    func testCrossSourceElapsedTimeMatchesDifferentMovingDurations() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        for _ in 0..<2 {
            let health = imported(id: "elapsed-hk", tss: 25)
            health.workoutType = "Running"
            let strava = imported(id: "elapsed-strava", source: .strava, tss: 35)
            strava.workoutType = "Run"
            strava.duration = 540
            // Both sources end after 600 seconds, but Strava reports 540 moving seconds.
            try store.saveWorkouts([health, strava])
            try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        }
        let rows = try store.allWorkouts()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { !$0.isSuppressed && !$0.isTombstoned }.map(\.id), ["elapsed-strava"])
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 1)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 35)
    }

    func testHikingAndYogaAliasesMatchAcrossSources() throws {
        for (healthType, stravaType) in [("Hiking", "Hike"), ("Yoga", "Yoga")] {
            let context = ModelContext(try container())
            let store = DataStore(modelContext: context)
            let health = imported(id: "sport-hk")
            health.workoutType = healthType
            let strava = imported(id: "sport-strava", source: .strava)
            strava.workoutType = stravaType
            try store.saveWorkouts([health, strava])
            XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), ["sport-strava"], healthType)
        }
    }

    func testSameSourceWorkoutsAreNotAutomaticallyMerged() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let first = imported(id: "same-source-first", tss: 25)
        let second = imported(id: "same-source-second", tss: 35)
        second.startTime = start.addingTimeInterval(20)
        try store.saveWorkouts([first, second])
        try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 2)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 2)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 60)
    }

    func testAmbiguousCrossSourceBridgeDoesNotMergeEitherWorkout() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let first = imported(id: "bridge-first", tss: 25)
        let second = imported(id: "bridge-second", tss: 30)
        second.startTime = start.addingTimeInterval(100)
        second.duration = 500
        var secondFeatures = second.features
        secondFeatures.end = start.addingTimeInterval(600)
        second.features = secondFeatures
        let bridge = imported(id: "bridge-strava", source: .strava, tss: 35)
        bridge.startTime = start.addingTimeInterval(50)
        bridge.duration = 550
        var bridgeFeatures = bridge.features
        bridgeFeatures.end = start.addingTimeInterval(600)
        bridge.features = bridgeFeatures
        XCTAssertTrue(WorkoutAggregator.areDuplicates(first, bridge))
        XCTAssertTrue(WorkoutAggregator.areDuplicates(second, bridge))
        try store.saveWorkouts([first, bridge, second])
        let rows = try store.allWorkouts()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter { !$0.isSuppressed && !$0.isTombstoned }.count, 3)
        XCTAssertNotEqual(first.sessionGroupID, second.sessionGroupID)
        try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 3)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 90)
    }

    func testRepeatedUnchangedSyncRepairsLegacyIncorrectGroup() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let health = imported(id: "legacy-group-hk", tss: 25)
        let strava = imported(id: "legacy-group-strava", source: .strava, tss: 35)
        strava.startTime = start.addingTimeInterval(3600)
        var features = strava.features
        features.end = strava.startTime.addingTimeInterval(600)
        strava.features = features
        // Simulate a group written before the source corrected its start time.
        health.sessionGroupID = health.id
        health.linkedSessionID = strava.id
        health.isSuppressed = true
        strava.sessionGroupID = health.id
        context.insert(health)
        context.insert(strava)
        try context.save()

        for _ in 0..<2 {
            let unchangedHealth = imported(id: "legacy-group-hk", tss: 25)
            let unchangedStrava = imported(id: "legacy-group-strava", source: .strava, tss: 35)
            unchangedStrava.startTime = start.addingTimeInterval(3600)
            var unchangedFeatures = unchangedStrava.features
            unchangedFeatures.end = unchangedStrava.startTime.addingTimeInterval(600)
            unchangedStrava.features = unchangedFeatures
            _ = try await store.applyImportedWorkouts([unchangedHealth, unchangedStrava], deletedIDs: [])
        }
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 2)
        XCTAssertNotEqual(health.sessionGroupID, strava.sessionGroupID)
        try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(4800))
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 2)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 60)
    }

    func testCorrectedSourceSplitsGroupAndRebuildsBothDays() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let health = imported(id: "corrected-hk", tss: 25)
        let strava = imported(id: "corrected-strava", source: .strava, tss: 35)
        try store.saveWorkouts([health, strava])
        let later = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: start))
        try store.rebuildLegacyLoadHistory(now: later.addingTimeInterval(1200))
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 35)

        for _ in 0..<2 {
            let corrected = imported(id: "corrected-strava", source: .strava, tss: 40)
            corrected.startTime = later
            corrected.date = Calendar.current.startOfDay(for: later)
            var features = corrected.features
            features.end = later.addingTimeInterval(600)
            corrected.features = features
            try store.saveWorkouts([corrected])
            try store.rebuildLegacyLoadHistory(now: later.addingTimeInterval(1200))
        }
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), ["corrected-hk"])
        XCTAssertEqual(try store.fetchWorkoutsForDay(later).map(\.id), ["corrected-strava"])
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 25)
        XCTAssertEqual(try store.fetchDayAggregate(for: later)?.totalTSS, 40)
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.workoutCount, 1)
        XCTAssertEqual(try store.fetchDayAggregate(for: later)?.workoutCount, 1)

        try store.deleteWorkout(try XCTUnwrap(store.fetchWorkout(byId: "corrected-strava")))
        let surviving = try XCTUnwrap(store.fetchWorkout(byId: "corrected-hk"))
        XCTAssertFalse(surviving.isTombstoned)
        XCTAssertFalse(surviving.isSuppressed)
    }

    func testCorrectedTypeOrDurationSplitsPreviouslyMatchedSources() throws {
        for correction in ["type", "duration"] {
            let context = ModelContext(try container())
            let store = DataStore(modelContext: context)
            try store.saveWorkouts([imported(id: "changed-hk"), imported(id: "changed-strava", source: .strava)])
            let corrected = imported(id: "changed-strava", source: .strava)
            if correction == "type" {
                corrected.workoutType = "Run"
            } else {
                corrected.duration = 900
                var features = corrected.features
                features.end = start.addingTimeInterval(900)
                corrected.features = features
            }
            try store.saveWorkouts([corrected])
            XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 2, "Correction: \(correction)")
        }
    }

    func testLocalDeletionRebuildsDependentScoresAndRampRates() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let end = start.addingDays(10)
        let store = V2Store(context: context, clock: { end })
        let session = imported(tss: 1000)
        try dataStore.saveWorkouts([session])
        for offset in 0...10 {
            try dataStore.saveDayAggregate(DayAggregate(
                date: start.startOfDay.addingDays(offset), avgHRV: 45, avgRHR: 55,
                hrvModifier: -8, rhrModifier: 2, sleepDuration: 7.5
            ))
        }
        try dataStore.rebuildLegacyLoadHistory(now: end)
        let oldLast = try XCTUnwrap(dataStore.fetchDayAggregate(for: end))
        let oldScore = oldLast.bodyBatteryScore
        let oldRampRate = oldLast.rampRate

        try await store.deleteSession(session)

        let expectedScore = BodyBatteryCalculator.calculateScoreWithModifiers(tsb: 0, hrvModifier: -8, rhrModifier: 2)
        XCTAssertNotEqual(oldScore, expectedScore)
        XCTAssertNotEqual(oldRampRate, 0)
        for (index, day) in try dataStore.fetchAllDayAggregates().enumerated() {
            XCTAssertEqual(day.totalTSS, 0)
            XCTAssertEqual(day.tsb, 0)
            XCTAssertEqual(day.bodyBatteryScore, expectedScore)
            XCTAssertEqual(day.rampRate, index >= 7 ? 0 : nil)
            XCTAssertEqual(day.avgHRV, 45)
            XCTAssertEqual(day.avgRHR, 55)
            XCTAssertEqual(day.sleepDuration, 7.5)
        }
    }

    func testCorrectedWorkoutDateClearsPreviousDayContribution() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        try dataStore.saveWorkouts([imported(tss: 25)])
        let later = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: start))
        try dataStore.rebuildLegacyLoadHistory(now: later)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 25)
        let corrected = imported(tss: 30)
        corrected.startTime = later
        corrected.date = Calendar.current.startOfDay(for: later)
        try dataStore.saveWorkouts([corrected])
        try dataStore.rebuildLegacyLoadHistory(now: later)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 0)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.workoutCount, 0)
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: later)?.totalTSS, 30)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Workout>()).count, 1)
    }

    func testCanonicalSourceSwitchAndDeletionRetainUserRowsOnOriginalSource() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        try dataStore.saveWorkouts([imported()])
        let row = StrengthSetRecord(sessionID: "synthetic-hk", exerciseID: "squat", reps: 8, rir: 0)
        let report = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 1,
                                      observedAt: start, sessionID: "synthetic-hk")
        try store.saveSet(row)
        try store.saveObservation(report)
        try dataStore.saveWorkouts([imported(id: "synthetic-strava", source: .strava)])
        try await store.refreshEstimates()
        XCTAssertEqual(row.sessionID, "synthetic-hk")
        XCTAssertEqual(report.sessionID, "synthetic-hk")
        let linked = try dataStore.allWorkouts()
        let graph = WorkoutLinkGraph(linked.map { .init(id: $0.id, parentID: $0.linkedSessionID) })
        let linkedIDs = graph.relatedIDs(to: "synthetic-strava")
        XCTAssertTrue(linkedIDs.contains(row.sessionID))
        XCTAssertTrue(linkedIDs.contains(try XCTUnwrap(report.sessionID)))
        let stravaInput = try XCTUnwrap(JSONSerialization.jsonObject(with:
            try latest(context, sessionID: "synthetic-strava").inputData) as? [String: Any])
        let sets = try XCTUnwrap(stravaInput["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?["id"] as? String, row.id.uuidString)
        try dataStore.applySourceDeletions(["synthetic-strava"])
        try await store.refreshEstimates()
        XCTAssertEqual(row.sessionID, "synthetic-hk")
        XCTAssertEqual(report.sessionID, "synthetic-hk")
        XCTAssertEqual(row.rir, 0)
        XCTAssertEqual(report.sideRaw, "left")
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 1)
        let active = try context.fetch(FetchDescriptor<Workout>()).filter { !$0.isTombstoned && !$0.isSuppressed }
        XCTAssertEqual(active.map(\.id), ["synthetic-hk"])
        XCTAssertFalse(try latest(context, sessionID: "synthetic-hk").value?.regions.isEmpty ?? true)
        let restoredInput = try XCTUnwrap(JSONSerialization.jsonObject(with:
            try latest(context, sessionID: "synthetic-hk").inputData) as? [String: Any])
        let restoredSets = try XCTUnwrap(restoredInput["sets"] as? [[String: Any]])
        XCTAssertEqual(restoredSets.count, 1)
        XCTAssertEqual(restoredSets.first?["id"] as? String, row.id.uuidString)
    }

    func testSaveSetsValidatesWholeBatchBeforeInserting() throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        let session = try store.createStrengthSession(start: start, duration: 600)
        let before = try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count
        let valid = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 8, rir: 0)
        let invalid = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 0)
        XCTAssertThrowsError(try store.saveSets([valid, invalid]))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StrengthSetRecord>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, before)
        invalid.reps = 8
        try store.saveSets([valid, invalid])
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 2)
    }

    func testLateNewSourceCannotResurrectUserDeletedLogicalSession() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        try dataStore.saveWorkouts([imported()])
        try dataStore.deleteWorkout(XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk")))
        try dataStore.saveWorkouts([imported(id: "synthetic-late-strava", source: .strava)])
        let all = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.isTombstoned && $0.isSuppressed && $0.deletionOrigin == "user" })
        try dataStore.rebuildLegacyLoadHistory(now: start.addingTimeInterval(600))
        XCTAssertEqual(try dataStore.fetchDayAggregate(for: start)?.totalTSS, 0)
    }

    func testRepeatedImportOfUserDeletedSourceIDsDoesNotRestoreGroup() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        try store.saveWorkouts([imported(id: "deleted-hk"), imported(id: "deleted-strava", source: .strava)])
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).count, 1)
        try store.deleteWorkout(try XCTUnwrap(store.fetchWorkout(byId: "deleted-strava")))
        for _ in 0..<2 {
            _ = try await store.applyImportedWorkouts([
                imported(id: "deleted-hk", tss: 40),
                imported(id: "deleted-strava", source: .strava, tss: 45)
            ], deletedIDs: [])
        }
        let rows = try store.allWorkouts()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.isTombstoned && $0.isSuppressed && $0.deletionOrigin == "user" })
        XCTAssertTrue(try store.fetchWorkoutsForDay(start).isEmpty)
        try store.rebuildLegacyLoadHistory(now: start.addingTimeInterval(1200))
        XCTAssertEqual(try store.fetchDayAggregate(for: start)?.totalTSS, 0)
    }

    func testAmbiguousDeletedHistoryDoesNotDeleteNewSource() throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let first = imported(id: "deleted-candidate-first")
        let second = imported(id: "deleted-candidate-second")
        try store.saveWorkouts([first, second])
        try store.deleteWorkout(first)
        try store.deleteWorkout(second)
        let newSource = imported(id: "new-ambiguous-strava", source: .strava)
        XCTAssertTrue(WorkoutAggregator.areDuplicates(first, newSource))
        XCTAssertTrue(WorkoutAggregator.areDuplicates(second, newSource))
        try store.saveWorkouts([newSource])
        XCTAssertFalse(newSource.isTombstoned)
        XCTAssertFalse(newSource.isSuppressed)
        XCTAssertEqual(try store.fetchWorkoutsForDay(start).map(\.id), [newSource.id])
    }

    func testPositiveSourceSnapshotCanRestoreSourceDeletion() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        try dataStore.saveWorkouts([imported()])
        try dataStore.applySourceDeletions(["synthetic-hk"])
        let deleted = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        XCTAssertTrue(deleted.isTombstoned)
        XCTAssertEqual(deleted.deletionOrigin, "source")
        try dataStore.saveWorkouts([imported(tss: 32)])
        let restored = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        XCTAssertFalse(restored.isTombstoned)
        XCTAssertFalse(restored.isSuppressed)
        XCTAssertNil(restored.deletionOrigin)
        XCTAssertEqual(restored.tss, 32)
    }

    func testUnreadableChannelsPreservePreviousMeasurementsAndTSSButObservedZeroReplaces() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let original = imported(tss: 42)
        original.calculationMethod = "power"
        original.averagePower = 200
        original.normalizedPower = 210
        original.averageHeartRate = 150
        original.maxHeartRate = 170
        var originalFeatures = original.features
        originalFeatures.power = originalFeatures.heartRate.map { TimedValue(start: $0.start, end: $0.end, value: 200) }
        original.features = originalFeatures
        try dataStore.saveWorkouts([original])
        let unreadable = imported(tss: 1)
        unreadable.calculationMethod = "duration"
        var unavailable = WorkoutFeatures()
        unavailable.failedChannels = ["power"]
        unavailable.unavailableChannels = ["heartRate"]
        unreadable.features = unavailable
        try dataStore.saveWorkouts([unreadable])
        let retained = try XCTUnwrap(dataStore.fetchWorkout(byId: original.id))
        XCTAssertEqual(retained.tss, 42)
        XCTAssertEqual(retained.calculationMethod, "power")
        XCTAssertEqual(retained.features.power, originalFeatures.power)
        XCTAssertEqual(retained.features.heartRate, originalFeatures.heartRate)
        XCTAssertEqual(retained.averagePower, 200)
        XCTAssertEqual(retained.normalizedPower, 210)
        XCTAssertEqual(retained.averageHeartRate, 150)
        XCTAssertEqual(retained.maxHeartRate, 170)
        let observedZero = imported(tss: 0)
        observedZero.calculationMethod = "power"
        observedZero.averagePower = 0
        observedZero.normalizedPower = 0
        var zeroFeatures = originalFeatures
        zeroFeatures.power = zeroFeatures.power.map { TimedValue(start: $0.start, end: $0.end, value: 0) }
        observedZero.features = zeroFeatures
        try dataStore.saveWorkouts([observedZero])
        XCTAssertEqual(retained.tss, 0)
        XCTAssertEqual(retained.averagePower, 0)
        XCTAssertTrue(retained.features.power.allSatisfy { $0.value == 0 })
    }

    func testRemovingCanonicalTagAfterManualLinkDoesNotResurrectAliasTag() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        let manual = try store.createStrengthSession(start: start, duration: 600)
        manual.userTags = ["paddles"]
        try dataStore.saveWorkouts([imported()])
        let external = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        try store.linkSession(manual: manual, to: external)
        XCTAssertEqual(external.userTags, ["paddles"])
        XCTAssertTrue(manual.userTags.isEmpty)
        external.userTags = []
        try store.recalculate(external)
        try dataStore.saveWorkouts([imported()])
        try await store.refreshEstimates()
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: latest(context, sessionID: external.id).inputData)
        XCTAssertTrue(external.userTags.isEmpty)
        XCTAssertTrue(snapshot.tags.isEmpty)
    }

    func testSourceWithMoreValidTimeCoverageWinsOverMoreDuplicateSamples() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        let thresholds = try dataStore.fetchUserThresholds()
        thresholds.cardioMaxHeartRate = 190
        try dataStore.saveUserThresholds(thresholds)
        let full = imported()
        let dense = imported(id: "synthetic-strava", source: .strava)
        var denseFeatures = dense.features
        denseFeatures.heartRate = Array(repeating: TimedValue(start: start, end: start.addingTimeInterval(1), value: 180), count: 120)
        dense.features = denseFeatures
        try dataStore.saveWorkouts([full, dense])
        try await store.refreshEstimates()
        let estimate = try latest(context, sessionID: dense.id)
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: estimate.inputData)
        XCTAssertEqual(snapshot.features.heartRate, full.features.heartRate)
        XCTAssertEqual(try XCTUnwrap(estimate.value?.cardio?.coverage), 1, accuracy: 0.000001)
    }

    func testOverlappingRunIsExcludedFromPriorPersonalExposure() async throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        let current = imported(id: "synthetic-current-run")
        current.workoutType = "Run"
        let overlapping = imported(id: "synthetic-overlapping-run")
        overlapping.workoutType = "Run"
        overlapping.startTime = start.addingTimeInterval(-300)
        overlapping.date = Calendar.current.startOfDay(for: overlapping.startTime)
        var overlapFeatures = WorkoutFeatures()
        overlapFeatures.end = start.addingTimeInterval(300)
        overlapping.features = overlapFeatures
        let completed = imported(id: "synthetic-completed-run")
        completed.workoutType = "Run"
        completed.startTime = start.addingTimeInterval(-3600)
        completed.date = Calendar.current.startOfDay(for: completed.startTime)
        var completedFeatures = WorkoutFeatures()
        completedFeatures.end = start.addingTimeInterval(-3000)
        completed.features = completedFeatures
        try dataStore.saveWorkouts([current, overlapping, completed])
        try await store.refreshEstimates()
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: latest(context, sessionID: current.id).inputData)
        XCTAssertEqual(snapshot.recentRunningMinutes, 10,
                       "Only the completed ten-minute run belongs to the input available before this session")
    }

    func testSingleSessionRecalculationMatchesFullHistoryAcrossRunningWindow() throws {
        let context = ModelContext(try container())
        let now = start.addingTimeInterval(3_600)
        let targetRun = imported(id: "target-run")
        targetRun.workoutType = "Running"
        let targetStrength = imported(id: "target-strength")
        targetStrength.workoutType = "Strength"
        context.insert(targetRun)
        context.insert(targetStrength)

        func addRun(_ id: String, offset: TimeInterval, endOffset: TimeInterval? = nil,
                    deleted: Bool = false, suppressed: Bool = false, payload: Int = 0) {
            let date = start.addingTimeInterval(offset)
            let row = Workout(id: id, date: date.startOfDay, startTime: date, duration: 600,
                              workoutType: "Running", tss: 10, calculationMethod: "duration", source: .healthKit)
            row.isTombstoned = deleted
            row.isSuppressed = suppressed
            if payload == 1 {
                row.featuresData = Data("{bad json".utf8)
            } else if payload == 2 {
                row.featuresData = nil
            } else {
                var features = WorkoutFeatures()
                features.end = endOffset.map { start.addingTimeInterval($0) } ?? date.addingTimeInterval(600)
                row.features = features
            }
            context.insert(row)
        }
        // The lower bound is inclusive; concurrent or unfinished runs cannot
        // contribute, and invalid/missing payloads use the saved duration.
        addRun("at-boundary", offset: -28 * 86_400)
        addRun("outside-boundary", offset: -28 * 86_400 - 1)
        addRun("finished", offset: -3_600)
        addRun("ends-at-start", offset: -600, endOffset: 0)
        addRun("unfinished", offset: -300, endOffset: 60)
        addRun("same-start", offset: 0)
        addRun("future", offset: 600)
        addRun("deleted", offset: -7_200, deleted: true)
        addRun("suppressed", offset: -10_800, suppressed: true)
        addRun("invalid-json", offset: -2_400, payload: 1)
        addRun("missing-payload", offset: -4_800, payload: 2)

        let batch = try V2EstimateBatch(context: context, includePrevious: false)
        let allResults = try batch.calculate(now: now)
        for target in [targetRun, targetStrength] {
            let expected = try XCTUnwrap(allResults.first { $0.sessionID == target.id })
            let single = try XCTUnwrap(batch.calculate(now: now, sessionID: target.id).first)
            XCTAssertEqual(single.inputData, expected.inputData)
            XCTAssertEqual(single.payloadData, expected.payloadData)
            let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: single.inputData)
            XCTAssertEqual(snapshot.recentRunningMinutes, 50)
        }
    }

    func testSingleSessionRecalculationHandlesNoPriorRunsAndInactiveTargets() throws {
        let context = ModelContext(try container())
        let target = imported(id: "target")
        target.workoutType = "Strength"
        let inactive = imported(id: "inactive")
        inactive.isSuppressed = true
        let deleted = imported(id: "deleted")
        deleted.isTombstoned = true
        context.insert(target)
        context.insert(inactive)
        context.insert(deleted)
        let batch = try V2EstimateBatch(context: context, includePrevious: false)
        let now = start.addingTimeInterval(3_600)
        let full = try batch.calculate(now: now)
        let single = try XCTUnwrap(batch.calculate(now: now, sessionID: target.id).first)
        let expected = try XCTUnwrap(full.first { $0.sessionID == target.id })
        XCTAssertEqual(single.inputData, expected.inputData)
        XCTAssertEqual(single.payloadData, expected.payloadData)
        XCTAssertNil(try JSONDecoder().decode(V2SnapshotProbe.self, from: single.inputData).recentRunningMinutes)
        XCTAssertTrue(try batch.calculate(now: now, sessionID: inactive.id).isEmpty)
        XCTAssertTrue(try batch.calculate(now: now, sessionID: deleted.id).isEmpty)
        XCTAssertTrue(try batch.calculate(now: now, sessionID: "missing").isEmpty)
    }

    func testSingleSessionGarminAliasesMatchFullHistoryWithoutDuplicateVersion() throws {
        let context = ModelContext(try container())
        let now = start.addingTimeInterval(3_600)
        let garmin = imported(id: "garmin")
        garmin.workoutType = "Running"
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let strava = imported(id: "strava", source: .strava)
        strava.workoutType = "Run"
        strava.isSuppressed = true
        strava.linkedSessionID = garmin.id
        var stravaFeatures = strava.features
        stravaFeatures.heartRate = [TimedValue(start: start, end: start.addingTimeInterval(600), value: 110)]
        strava.features = stravaFeatures

        let sourceDeleted = imported(id: "source-deleted")
        sourceDeleted.isTombstoned = true
        sourceDeleted.deletionOrigin = "source"
        sourceDeleted.isSuppressed = true
        sourceDeleted.linkedSessionID = garmin.id
        sourceDeleted.userTags = ["retained-source-tag"]
        let userDeleted = imported(id: "user-deleted")
        userDeleted.isTombstoned = true
        userDeleted.deletionOrigin = "user"
        userDeleted.isSuppressed = true
        userDeleted.linkedSessionID = garmin.id
        userDeleted.userTags = ["deleted-user-tag"]
        let prior = imported(id: "prior-run")
        prior.workoutType = "Run"
        prior.startTime = start.addingTimeInterval(-86_400)
        prior.date = prior.startTime.startOfDay
        var priorFeatures = WorkoutFeatures()
        priorFeatures.end = prior.startTime.addingTimeInterval(600)
        prior.features = priorFeatures
        for row in [garmin, strava, sourceDeleted, userDeleted, prior] { context.insert(row) }
        let retainedSet = StrengthSetRecord(sessionID: sourceDeleted.id, exerciseID: "squat", reps: 8, rir: 2)
        let excludedSet = StrengthSetRecord(sessionID: userDeleted.id, exerciseID: "squat", reps: 4)
        context.insert(retainedSet)
        context.insert(excludedSet)
        context.insert(LoadEstimateRecord(sessionID: garmin.id, version: "old-model", inputCutoff: start,
                                          computedAt: start, payloadData: Data([1]), inputData: Data([2])))
        context.insert(LoadEstimateRecord(sessionID: garmin.id, version: LoadModel.version, inputCutoff: start,
                                          computedAt: start.addingTimeInterval(60), payloadData: Data([3]), inputData: Data([4])))
        // Creating the thresholds singleton can save the fixture, so capture the
        // batch only after all source and personal details have been inserted.
        let batch = try V2EstimateBatch(context: context)
        let full = try XCTUnwrap(batch.calculate(now: now).first { $0.sessionID == garmin.id })
        let single = try XCTUnwrap(batch.calculate(now: now, sessionID: garmin.id).first)
        XCTAssertEqual(single.inputData, full.inputData)
        XCTAssertEqual(single.payloadData, full.payloadData)
        let probe = try JSONDecoder().decode(SingleSessionAliasProbe.self, from: single.inputData)
        XCTAssertEqual(probe.recentRunningMinutes, 10)
        XCTAssertTrue(probe.tags.contains("retained-source-tag"))
        XCTAssertFalse(probe.tags.contains("deleted-user-tag"))
        XCTAssertEqual(probe.sets.map(\.id), [retainedSet.id])
        XCTAssertEqual(probe.features.heartRate.first?.value, 150)

        context.insert(LoadEstimateRecord(sessionID: garmin.id, version: single.value.version,
                                          inputCutoff: single.value.inputCutoff, computedAt: now,
                                          payloadData: single.payloadData, inputData: single.inputData))
        try context.save()
        let count = try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count
        try V2Store(context: context, clock: { now }).recalculate(garmin)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, count)
    }

    func testDiskReopenRetainsUserTombstoneAfterResync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-tombstone.store")
        func seedAndDelete() async throws {
            let context = ModelContext(try container(url: url))
            let dataStore = DataStore(modelContext: context)
            try dataStore.saveWorkouts([imported()])
            let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
            try await V2Store(context: context, clock: { self.start.addingTimeInterval(600) }).deleteSession(session)
            XCTAssertTrue(session.isTombstoned)
            XCTAssertFalse(session.isDeleted, "A retained tombstone is not a SwiftData object deletion")
        }
        try await seedAndDelete()
        try autoreleasepool {
            let context = ModelContext(try container(url: url))
            let dataStore = DataStore(modelContext: context)
            try dataStore.saveWorkouts([imported(tss: 40)])
            let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
            XCTAssertTrue(session.isTombstoned)
            XCTAssertTrue(session.isSuppressed)
            XCTAssertEqual(session.deletionOrigin, "user")
            XCTAssertTrue(try dataStore.fetchWorkoutsForDay(start).isEmpty)
            let tombstones = try context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.isTombstoned }))
            XCTAssertEqual(tombstones.map(\.id), ["synthetic-hk"])
        }
    }

    func testDiskReopenPreservesObservationsSetsUnknownAndExplicitZero() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-v2.store")
        var sessionID = ""
        var originalRecordedAt = Date.distantPast
        try autoreleasepool {
            let context = ModelContext(try container(url: url))
            let store = V2Store(context: context)
            let session = try store.createStrengthSession(start: start, duration: 600)
            sessionID = session.id
            try store.saveSet(StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 5, weightKG: 0, rir: 0))
            try store.saveSet(StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 5))
            let feedback = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 0,
                                            observedAt: start, sessionID: session.id)
            originalRecordedAt = feedback.recordedAt
            try store.saveObservation(feedback)
            try context.save()
        }
        try autoreleasepool {
            let context = ModelContext(try container(url: url))
            let rows = try context.fetch(FetchDescriptor<StrengthSetRecord>())
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.contains { $0.rir == 0 && $0.weightKG == 0 })
            XCTAssertTrue(rows.contains { $0.rir == nil && $0.weightKG == nil })
            XCTAssertTrue(rows.allSatisfy { $0.sessionID == sessionID })
            let feedback = try XCTUnwrap(context.fetch(FetchDescriptor<LocalObservation>()).first)
            XCTAssertEqual(feedback.observedAt, start)
            XCTAssertEqual(feedback.recordedAt, originalRecordedAt)
            XCTAssertEqual(feedback.severity, 0)
            XCTAssertEqual(feedback.sideRaw, "left")
        }
    }
}

private struct V2SnapshotProbe: Decodable {
    var features: WorkoutFeatures
    var tags: [String]
    var recentRunningMinutes: Double?
}

private struct SingleSessionAliasProbe: Decodable {
    let features: WorkoutFeatures
    let tags: [String]
    let sets: [StrengthSetInput]
    let recentRunningMinutes: Double?
}
