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

    func testDeleteSessionRemovesContributionButRetainsUserHistory() throws {
        let context = ModelContext(try container())
        let dataStore = DataStore(modelContext: context)
        let store = V2Store(context: context)
        try dataStore.saveWorkouts([imported()])
        let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
        try store.saveSet(StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 5))
        try store.saveObservation(LocalObservation(regionRaw: "quads", severity: 2, sessionID: session.id))
        try store.deleteSession(session)
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

    func testBackfillAllowsMainActorCancellationAndResumesWithoutDuplicateSnapshots() async throws {
        let context = ModelContext(try container())
        let store = V2Store(context: context)
        for index in 0..<30 { context.insert(imported(id: "cancel-\(index)")) }
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
        XCTAssertLessThan(saved.count, 30)
        let savedIDs = Set(saved.map(\.id))

        try await store.backfillEstimates()
        let resumed = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(resumed.count, 30)
        XCTAssertTrue(savedIDs.isSubset(of: Set(resumed.map(\.id))))
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

    func testLocalDeletionRebuildsDependentScoresAndRampRates() throws {
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

        try store.deleteSession(session)

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

    func testCanonicalSourceSwitchAndDeletionRetainUserRowsOnSurvivingSource() throws {
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
        try store.refreshEstimates()
        XCTAssertEqual(row.sessionID, "synthetic-strava")
        XCTAssertEqual(report.sessionID, "synthetic-strava")
        try dataStore.applySourceDeletions(["synthetic-strava"])
        try store.refreshEstimates()
        XCTAssertEqual(row.sessionID, "synthetic-hk")
        XCTAssertEqual(report.sessionID, "synthetic-hk")
        XCTAssertEqual(row.rir, 0)
        XCTAssertEqual(report.sideRaw, "left")
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).count, 1)
        let active = try context.fetch(FetchDescriptor<Workout>()).filter { !$0.isTombstoned && !$0.isSuppressed }
        XCTAssertEqual(active.map(\.id), ["synthetic-hk"])
        XCTAssertFalse(try latest(context, sessionID: "synthetic-hk").value?.regions.isEmpty ?? true)
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

    func testRemovingCanonicalTagAfterManualLinkDoesNotResurrectAliasTag() throws {
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
        try store.refreshEstimates()
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: latest(context, sessionID: external.id).inputData)
        XCTAssertTrue(external.userTags.isEmpty)
        XCTAssertTrue(snapshot.tags.isEmpty)
    }

    func testSourceWithMoreValidTimeCoverageWinsOverMoreDuplicateSamples() throws {
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
        try store.refreshEstimates()
        let estimate = try latest(context, sessionID: dense.id)
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: estimate.inputData)
        XCTAssertEqual(snapshot.features.heartRate, full.features.heartRate)
        XCTAssertEqual(try XCTUnwrap(estimate.value?.cardio?.coverage), 1, accuracy: 0.000001)
    }

    func testOverlappingRunIsExcludedFromPriorPersonalExposure() throws {
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
        try store.refreshEstimates()
        let snapshot = try JSONDecoder().decode(V2SnapshotProbe.self, from: latest(context, sessionID: current.id).inputData)
        XCTAssertEqual(snapshot.recentRunningMinutes, 10,
                       "Only the completed ten-minute run belongs to the input available before this session")
    }

    func testDiskReopenRetainsUserTombstoneAfterResync() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-tombstone.store")
        try autoreleasepool {
            let context = ModelContext(try container(url: url))
            let dataStore = DataStore(modelContext: context)
            try dataStore.saveWorkouts([imported()])
            let session = try XCTUnwrap(dataStore.fetchWorkout(byId: "synthetic-hk"))
            try V2Store(context: context, clock: { self.start.addingTimeInterval(600) }).deleteSession(session)
            XCTAssertTrue(session.isTombstoned)
            XCTAssertFalse(session.isDeleted, "A retained tombstone is not a SwiftData object deletion")
        }
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
