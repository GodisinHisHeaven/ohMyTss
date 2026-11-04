import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutSourceMatchingTests: XCTestCase {
    func testUnorderedOfflineRepairPreservesDistinctSessionsAndGarminPriority() async throws {
        let synchronous = try makeStore()
        let detached = try makeStore()
        defer { withExtendedLifetime(synchronous.container) {}; withExtendedLifetime(detached.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        for fixture in [synchronous, detached] {
            let entries: [(String, WorkoutSource, Double, String)] = [
                ("strava-late", .strava, 7_200, "Run"),
                ("health-early", .healthKit, 0, "Running"),
                ("bike-close", .strava, 10, "Ride"),
                ("health-late", .healthKit, 7_200, "Running"),
                ("strava-early", .strava, 0, "Run"),
                ("single", .healthKit, 3_600, "Swim")
            ]
            for (id, source, offset, type) in entries {
                let row = Workout(id: id, date: start.startOfDay, startTime: start.addingTimeInterval(offset),
                                  duration: 600, workoutType: type, tss: 10,
                                  calculationMethod: "duration", source: source)
                if id.hasPrefix("health-") { row.sourceBundleIdentifier = "com.garmin.connect.mobile" }
                row.userTags = ["tag-\(id)"]
                fixture.context.insert(row)
            }
            try fixture.context.save()
        }
        _ = try synchronous.store.reconcileWorkoutSources(applySideEffects: false)
        _ = try await detached.store.repairWorkoutSourcesLocally()
        XCTAssertEqual(try states(synchronous.context), try states(detached.context))
        for fixture in [synchronous, detached] {
            for suffix in ["early", "late"] {
                let health = try XCTUnwrap(fixture.store.fetchWorkout(byId: "health-\(suffix)"))
                let strava = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava-\(suffix)"))
                XCTAssertFalse(health.isSuppressed)
                XCTAssertTrue(strava.isSuppressed)
                XCTAssertEqual(strava.linkedSessionID, health.id)
                XCTAssertEqual(strava.userTags, ["tag-strava-\(suffix)"])
            }
            let bike = try XCTUnwrap(fixture.store.fetchWorkout(byId: "bike-close"))
            XCTAssertFalse(bike.isSuppressed)
            XCTAssertNil(bike.linkedSessionID)
        }
    }

    func testPausedGarminRideRequiresCorroborationAndKeepsAmbiguity() async throws {
        struct Scenario {
            let name: String
            var bundle: String? = "com.garmin.connect.mobile"
            var startOffset: Double = 0
            var stravaDistance: Double? = 25_020
            var stravaDuration: Double = 3_606
            var stravaEnd: Double? = 4_200
            var deleted: String? = nil
            var competingSource = false
            var competingSourceMissingEnd = false
            var competingOffset: Double = 0
            var competingDuration: Double = 3_600
            var stravaHealthMirror = false
            var mirrorBundle = "com.strava.stravaride"
            var mirrorDistance: Double? = 25_020
            var mirrorDeleted = false
            var grouped = false
        }
        let scenarios = [
            Scenario(name: "matching ride", grouped: true),
            Scenario(name: "unknown producer", bundle: "com.example.watch"),
            Scenario(name: "start outside tolerance", startOffset: 2),
            Scenario(name: "missing distance", stravaDistance: nil),
            Scenario(name: "different distance", stravaDistance: 26_000),
            Scenario(name: "different moving time", stravaDuration: 3_640),
            Scenario(name: "missing elapsed end", stravaEnd: nil),
            Scenario(name: "deleted Garmin", deleted: "health"),
            Scenario(name: "deleted Strava", deleted: "strava"),
            Scenario(name: "competing source without distance", competingSource: true),
            Scenario(name: "competing source without distance or end", competingSource: true, competingSourceMissingEnd: true),
            Scenario(name: "nearby competing source with missing evidence", competingSource: true,
                     competingSourceMissingEnd: true, competingOffset: 20, competingDuration: 3_612),
            Scenario(name: "Strava HealthKit mirror", stravaHealthMirror: true, grouped: true),
            Scenario(name: "mirror without distance", stravaHealthMirror: true, mirrorDistance: nil, grouped: true),
            Scenario(name: "corrected mirror source", stravaHealthMirror: true, mirrorBundle: "com.example.watch"),
            Scenario(name: "deleted mirror", stravaHealthMirror: true, mirrorDeleted: true),
            Scenario(name: "mirror and competing source", competingSource: true, stravaHealthMirror: true)
        ]
        for scenario in scenarios {
            let synchronous = try makeStore()
            let detached = try makeStore()
            for fixture in [synchronous, detached] {
                let start = Date(timeIntervalSince1970: 1_750_000_000)
                let health = Workout(id: "health", date: start.startOfDay, startTime: start, duration: 3_600,
                                     workoutType: "Cycling", distance: 25_000, tss: 25,
                                     calculationMethod: "duration", source: .healthKit)
                health.sourceBundleIdentifier = scenario.bundle
                health.userTags = ["garmin-tag"]
                var healthFeatures = WorkoutFeatures()
                healthFeatures.end = start.addingTimeInterval(3_600)
                health.features = healthFeatures
                let stravaStart = start.addingTimeInterval(scenario.startOffset)
                let strava = Workout(id: "strava", date: start.startOfDay, startTime: stravaStart,
                                     duration: scenario.stravaDuration, workoutType: "Ride", distance: scenario.stravaDistance,
                                     tss: 35, calculationMethod: "duration", source: .strava)
                strava.userTags = ["strava-tag"]
                if let end = scenario.stravaEnd {
                    var features = WorkoutFeatures()
                    features.end = stravaStart.addingTimeInterval(end)
                    strava.features = features
                }
                if let deletedID = scenario.deleted {
                    let deleted = deletedID == "health" ? health : strava
                    deleted.isTombstoned = true
                    deleted.deletionOrigin = "user"
                    deleted.isSuppressed = true
                }
                fixture.context.insert(health)
                fixture.context.insert(strava)
                if scenario.stravaHealthMirror {
                    let mirror = Workout(id: "a-mirror", date: start.startOfDay, startTime: start, duration: 4_200,
                                         workoutType: "Cycling", distance: scenario.mirrorDistance, tss: 30,
                                         calculationMethod: "duration", source: .healthKit)
                    mirror.sourceBundleIdentifier = scenario.mirrorBundle
                    mirror.deviceManufacturer = "Garmin"
                    mirror.userTags = ["mirror-tag"]
                    var mirrorFeatures = WorkoutFeatures()
                    mirrorFeatures.end = start.addingTimeInterval(4_200)
                    mirror.features = mirrorFeatures
                    if scenario.mirrorDeleted {
                        mirror.isTombstoned = true
                        mirror.deletionOrigin = "user"
                        mirror.isSuppressed = true
                    }
                    fixture.context.insert(mirror)
                }
                if scenario.competingSource {
                    let competing = Workout(id: "other", date: start.startOfDay,
                                            startTime: start.addingTimeInterval(scenario.competingOffset),
                                            duration: scenario.competingDuration,
                                            workoutType: "Cycling", tss: 10,
                                            calculationMethod: "duration", source: .healthKit)
                    competing.sourceBundleIdentifier = "com.example.watch"
                    if !scenario.competingSourceMissingEnd { competing.features = healthFeatures }
                    fixture.context.insert(competing)
                }
                try fixture.context.save()
            }
            _ = try synchronous.store.reconcileWorkoutSources(applySideEffects: false)
            _ = try await detached.store.repairWorkoutSourcesLocally()
            XCTAssertEqual(try states(synchronous.context), try states(detached.context), scenario.name)
            let health = try XCTUnwrap(synchronous.store.fetchWorkout(byId: "health"))
            let strava = try XCTUnwrap(synchronous.store.fetchWorkout(byId: "strava"))
            XCTAssertEqual(health.sessionGroupID == strava.sessionGroupID, scenario.grouped, scenario.name)
            XCTAssertEqual(health.userTags, ["garmin-tag"])
            XCTAssertEqual(strava.userTags, ["strava-tag"])
            if scenario.grouped {
                XCTAssertFalse(health.isSuppressed, "Garmin must retain priority")
                XCTAssertTrue(strava.isSuppressed)
                if scenario.stravaHealthMirror {
                    let mirror = try XCTUnwrap(synchronous.store.fetchWorkout(byId: "a-mirror"))
                    XCTAssertTrue(mirror.isSuppressed)
                    XCTAssertEqual(mirror.linkedSessionID, health.id)
                    XCTAssertEqual(mirror.userTags, ["mirror-tag"])
                }
                for fixture in [synchronous, detached] {
                    let corrected = try XCTUnwrap(fixture.store.fetchWorkout(byId: "health"))
                    corrected.sourceBundleIdentifier = "com.example.watch"
                    try fixture.context.save()
                }
                _ = try synchronous.store.reconcileWorkoutSources(applySideEffects: false)
                _ = try await detached.store.repairWorkoutSourcesLocally()
                XCTAssertEqual(try states(synchronous.context), try states(detached.context))
                XCTAssertFalse(health.isSuppressed)
                XCTAssertFalse(strava.isSuppressed)
                XCTAssertNotEqual(health.sessionGroupID, strava.sessionGroupID)
                XCTAssertNil(strava.linkedSessionID)
                XCTAssertEqual(strava.userTags, ["strava-tag"])
            } else if scenario.deleted != nil || scenario.mirrorDeleted {
                if scenario.mirrorDeleted {
                    XCTAssertFalse(health.isTombstoned)
                    XCTAssertFalse(strava.isTombstoned)
                    XCTAssertFalse(health.isSuppressed)
                    XCTAssertFalse(strava.isSuppressed)
                }
                guard let deletedID = scenario.deleted else { continue }
                let survivor = deletedID == "health" ? strava : health
                XCTAssertFalse(survivor.isTombstoned, "An uncertain link must not propagate a deletion")
                XCTAssertFalse(survivor.isSuppressed)
            }
            withExtendedLifetime(synchronous.container) {}
            withExtendedLifetime(detached.container) {}
        }
    }

    func testUserDeletionNeedsBothEndpointsInSynchronousAndDetachedMatching() async throws {
        let cases: [(healthEnd: Bool, stravaEnd: Bool, deleted: String?, grouped: Bool)] = [
            (true, false, "health", false), (false, true, "health", false),
            (false, false, "health", false), (true, false, "strava", false),
            (false, true, "strava", false), (true, true, "health", true),
            (true, true, "strava", true), (true, false, nil, true), (false, false, nil, true)
        ]
        for entry in cases {
            let first = try makeStore()
            let second = try makeStore()
            defer { withExtendedLifetime(first.container) {}; withExtendedLifetime(second.container) {} }
            for fixture in [first, second] {
                let start = Date(timeIntervalSince1970: 1_750_000_000)
                let health = Workout(id: "health", date: start.startOfDay, startTime: start, duration: 600,
                                     workoutType: "Run", tss: 10, calculationMethod: "duration", source: .healthKit)
                health.sourceBundleIdentifier = "com.garmin.connect.mobile"
                let strava = Workout(id: "strava", date: start.startOfDay, startTime: start.addingTimeInterval(20),
                                     duration: 600, workoutType: "Run", tss: 10,
                                     calculationMethod: "duration", source: .strava)
                if entry.healthEnd { var f = WorkoutFeatures(); f.end = start.addingTimeInterval(600); health.features = f }
                if entry.stravaEnd { var f = WorkoutFeatures(); f.end = start.addingTimeInterval(600); strava.features = f }
                if let id = entry.deleted {
                    let deleted = id == health.id ? health : strava
                    deleted.isTombstoned = true
                    deleted.deletionOrigin = "user"
                    deleted.isSuppressed = true
                }
                fixture.context.insert(health)
                fixture.context.insert(strava)
                try fixture.context.save()
            }
            _ = try first.store.reconcileWorkoutSources(applySideEffects: false)
            _ = try await second.store.repairWorkoutSourcesLocally()
            XCTAssertEqual(try states(first.context), try states(second.context), "Detached and synchronous plans diverged: \(entry)")
            _ = try first.store.finalizeWorkoutSources()
            _ = try second.store.finalizeWorkoutSources()
            XCTAssertEqual(try states(first.context), try states(second.context), "Finalization diverged: \(entry)")
            let health = try XCTUnwrap(first.store.fetchWorkout(byId: "health"))
            let strava = try XCTUnwrap(first.store.fetchWorkout(byId: "strava"))
            XCTAssertEqual(health.sessionGroupID == strava.sessionGroupID, entry.grouped, "Case: \(entry)")
            if entry.deleted != nil && entry.grouped {
                XCTAssertEqual(health.deletionOrigin, "user")
                XCTAssertEqual(strava.deletionOrigin, "user")
                XCTAssertTrue(health.isTombstoned && strava.isTombstoned)
            } else if let deletedID = entry.deleted {
                let survivor = deletedID == health.id ? strava : health
                XCTAssertFalse(survivor.isTombstoned, "Case: \(entry)")
                XCTAssertFalse(survivor.isSuppressed, "Case: \(entry)")
                XCTAssertNil(survivor.linkedSessionID)
            } else {
                XCTAssertFalse(health.isSuppressed, "Garmin keeps priority")
                XCTAssertTrue(strava.isSuppressed)
            }
        }
    }

    func testDetachedRepairMatchesConservativeSynchronousReconciliation() async throws {
        let first = try makeStore()
        let second = try makeStore()
        defer {
            withExtendedLifetime(first.container) { }
            withExtendedLifetime(second.container) { }
        }
        for store in [first, second] {
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            func insert(_ id: String, _ source: WorkoutSource, _ offset: Double,
                        _ type: String = "Running", bundle: String? = nil) -> Workout {
                let row = Workout(id: id, date: start.startOfDay, startTime: start.addingTimeInterval(offset),
                                  duration: 600, workoutType: type, tss: 10,
                                  calculationMethod: "duration", source: source)
                row.sourceBundleIdentifier = bundle
                store.context.insert(row)
                return row
            }
            let health = insert("h-a", .healthKit, 0, bundle: "com.garmin.connect.mobile")
            let strava = insert("s-a", .strava, 0)
            health.userTags = ["kept-health"]
            strava.userTags = ["kept-strava"]
            health.sessionGroupID = health.id
            strava.sessionGroupID = health.id
            let old = insert("s-deleted", .strava, 0)
            old.sessionGroupID = health.id
            old.deletionOrigin = "source"
            old.isTombstoned = true
            _ = insert("h-unknown", .healthKit, 3_600, "Other")
            _ = insert("s-ambiguous", .strava, 3_600)
            _ = insert("h-ambiguous", .healthKit, 3_600, bundle: "com.example.watch")
            let deleted = insert("h-user-deleted", .healthKit, 7_200)
            deleted.deletionOrigin = "user"
            deleted.isTombstoned = true
            _ = insert("s-user-deleted", .strava, 7_200)
            // A deleted candidate still blocks an apparently unique match
            // between these other two rows when its endpoint is missing.
            _ = insert("h-user-competing", .healthKit, 7_200, bundle: "com.example.watch")
            let manual = insert("manual", .manual, 10_800)
            manual.linkedSessionID = health.id
            try store.context.save()
        }
        _ = try first.store.reconcileWorkoutSources(applySideEffects: false)
        _ = try await second.store.repairWorkoutSourcesLocally()
        XCTAssertEqual(try states(first.context), try states(second.context))
        for fixture in [first, second] {
            let strava = try XCTUnwrap(fixture.store.fetchWorkout(byId: "s-user-deleted"))
            let competing = try XCTUnwrap(fixture.store.fetchWorkout(byId: "h-user-competing"))
            XCTAssertFalse(strava.isSuppressed)
            XCTAssertFalse(competing.isSuppressed)
            XCTAssertNotEqual(strava.sessionGroupID, competing.sessionGroupID)
        }
    }

    func testConcurrentSourceCorrectionDiscardsDetachedPlan() async throws {
        let fixture = try makeStore()
        defer { withExtendedLifetime(fixture.container) { } }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = Workout(id: "health", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Running", tss: 10, calculationMethod: "duration", source: .healthKit)
        let strava = Workout(id: "strava", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Run", tss: 10, calculationMethod: "duration", source: .strava)
        fixture.context.insert(health)
        fixture.context.insert(strava)
        try fixture.context.save()
        let gate = MatchingPlanGate()
        let task = Task {
            try await fixture.store.repairWorkoutSourcesLocally { input in
                await gate.pauseFirstPlan()
                return try await WorkoutSourceMatching.detachedPlan(input)
            }
        }
        await gate.waitUntilPaused()
        strava.startTime = start.addingTimeInterval(3_600)
        strava.userTags = ["concurrent-edit"]
        try fixture.context.save()
        await gate.release()
        _ = try await task.value
        let planCount = await gate.planCount()
        XCTAssertEqual(planCount, 2)
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
        XCTAssertNil(strava.linkedSessionID)
        XCTAssertEqual(strava.userTags, ["concurrent-edit"])
    }

    func testConcurrentDistanceCorrectionDiscardsPausedMatchPlan() async throws {
        let fixture = try makeStore()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = Workout(id: "health", date: start.startOfDay, startTime: start, duration: 3_600,
                             workoutType: "Cycling", distance: 25_000, tss: 10,
                             calculationMethod: "duration", source: .healthKit)
        health.sourceBundleIdentifier = "com.garmin.connect.mobile"
        var healthFeatures = WorkoutFeatures()
        healthFeatures.end = start.addingTimeInterval(3_600)
        health.features = healthFeatures
        let strava = Workout(id: "strava", date: start.startOfDay, startTime: start, duration: 3_606,
                             workoutType: "Ride", distance: 25_020, tss: 10,
                             calculationMethod: "duration", source: .strava)
        var stravaFeatures = WorkoutFeatures()
        stravaFeatures.end = start.addingTimeInterval(4_200)
        strava.features = stravaFeatures
        fixture.context.insert(health); fixture.context.insert(strava)
        try fixture.context.save()
        let gate = MatchingPlanGate()
        let task = Task {
            try await fixture.store.repairWorkoutSourcesLocally { input in
                await gate.pauseFirstPlan()
                return try await WorkoutSourceMatching.detachedPlan(input)
            }
        }
        await gate.waitUntilPaused()
        strava.distance = 26_000
        try fixture.context.save()
        await gate.release()
        _ = try await task.value
        let planCount = await gate.planCount()
        XCTAssertEqual(planCount, 2)
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
        XCTAssertNotEqual(health.sessionGroupID, strava.sessionGroupID)
        withExtendedLifetime(fixture.container) {}
    }

    func testCancelledDetachedRepairDoesNotApplyPlan() async throws {
        let fixture = try makeStore()
        defer { withExtendedLifetime(fixture.container) { } }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = Workout(id: "health", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Running", tss: 10, calculationMethod: "duration", source: .healthKit)
        let strava = Workout(id: "strava", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Run", tss: 10, calculationMethod: "duration", source: .strava)
        fixture.context.insert(health)
        fixture.context.insert(strava)
        try fixture.context.save()
        let gate = MatchingPlanGate()
        let task = Task {
            try await fixture.store.repairWorkoutSourcesLocally { input in
                await gate.pauseFirstPlan()
                return try await WorkoutSourceMatching.detachedPlan(input)
            }
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled repair must not apply its plan")
        } catch is CancellationError { }
        XCTAssertNil(health.sessionGroupID)
        XCTAssertNil(strava.sessionGroupID)
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
    }

    private func makeStore() throws -> (container: ModelContainer, context: ModelContext, store: onMyTss.DataStore) {
        let schema = Schema(AppSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        return (container, context, DataStore(modelContext: context))
    }

    private func states(_ context: ModelContext) throws -> [MatchingState] {
        try context.fetch(FetchDescriptor<Workout>()).map {
            MatchingState(id: $0.id, group: $0.sessionGroupID, link: $0.linkedSessionID,
                          suppressed: $0.isSuppressed, tombstoned: $0.isTombstoned,
                          origin: $0.deletionOrigin, tags: $0.userTags)
        }.sorted { $0.id < $1.id }
    }
}

private struct MatchingState: Equatable {
    let id: String
    let group: String?
    let link: String?
    let suppressed: Bool
    let tombstoned: Bool
    let origin: String?
    let tags: [String]
}

private actor MatchingPlanGate {
    private var calls = 0
    private var paused = false
    private var waitingForPause: CheckedContinuation<Void, Never>?
    private var waitingForRelease: CheckedContinuation<Void, Never>?

    func pauseFirstPlan() async {
        calls += 1
        guard calls == 1 else { return }
        paused = true
        waitingForPause?.resume()
        waitingForPause = nil
        await withCheckedContinuation { waitingForRelease = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waitingForPause = $0 }
    }

    func release() {
        waitingForRelease?.resume()
        waitingForRelease = nil
    }

    func planCount() -> Int { calls }
}
