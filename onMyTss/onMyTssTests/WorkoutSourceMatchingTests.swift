import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutSourceMatchingTests: XCTestCase {
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
