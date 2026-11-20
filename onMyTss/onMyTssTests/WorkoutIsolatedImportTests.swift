import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutIsolatedImportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func workout(_ id: String, offset: Double = 0, source: WorkoutSource = .healthKit) -> Workout {
        let date = start.addingTimeInterval(offset)
        let row = Workout(id: id, date: date.startOfDay, startTime: date, duration: 600,
                          workoutType: "Ride", tss: 10, calculationMethod: "duration", source: source)
        if source == .healthKit { row.sourceBundleIdentifier = "com.garmin.connect.mobile" }
        var features = WorkoutFeatures()
        features.end = date.addingTimeInterval(600)
        row.features = features
        return row
    }

    private struct State: Equatable {
        let id: String
        let group: String?
        let link: String?
        let suppressed: Bool
        let tombstoned: Bool
        let deletion: String?
        let tags: [String]
        let payload: Data?
        init(_ row: Workout) {
            id = row.id; group = row.sessionGroupID; link = row.linkedSessionID
            suppressed = row.isSuppressed; tombstoned = row.isTombstoned
            deletion = row.deletionOrigin; tags = row.userTags; payload = row.featuresData
        }
    }

    private func states(_ store: onMyTss.DataStore) throws -> [State] {
        try store.allWorkouts().sorted { $0.id < $1.id }.map(State.init)
    }

    func testIndependentPairsAndSinglesMatchFullReconciliationBeforeFinalization() async throws {
        let expected = DataStore(modelContainer: try container())
        let actual = DataStore(modelContainer: try container())
        func batch() -> [Workout] {
            [workout("new-health"), workout("new-strava", source: .strava)] +
                (1...38).map { workout("new-\($0)", offset: Double($0) * 3600) }
        }
        for store in [expected, actual] {
            try store.saveWorkouts([workout("old", offset: -86_400)])
        }
        let control = batch()
        for offset in stride(from: 0, to: control.count, by: 20) {
            try expected.saveWorkouts(Array(control[offset..<min(offset + 20, control.count)]),
                                      reconcileSideEffects: false)
        }
        _ = try await actual.applyImportedWorkouts(batch(), deletedIDs: [], finalize: false)
        XCTAssertEqual(try states(actual), try states(expected))
        XCTAssertEqual(try actual.allWorkouts().filter { !$0.isSuppressed }.count, 40)
        XCTAssertTrue(try XCTUnwrap(actual.fetchWorkout(byId: "new-strava")).isSuppressed)
    }

    func testAliasInLaterBatchIsSuppressedBeforeFinalization() async throws {
        let store = DataStore(modelContainer: try container())
        let rows = [workout("health")] + (1...19).map { workout("spacer-\($0)", offset: Double($0) * 3600) }
        _ = try await store.applyImportedWorkouts(rows + [workout("strava", source: .strava)],
                                                 deletedIDs: [], finalize: false)
        let alias = try XCTUnwrap(store.fetchWorkout(byId: "strava"))
        XCTAssertTrue(alias.isSuppressed)
        XCTAssertEqual(alias.linkedSessionID, "health")
        XCTAssertEqual(try store.allWorkouts().filter { !$0.isSuppressed && !$0.isTombstoned }.count, 20)
    }

    func testUnsavedSourceCorrectionIsIncludedInNeighborCheck() async throws {
        let context = ModelContext(try container())
        let store = DataStore(modelContext: context)
        let saved = workout("health", offset: -86_400)
        try store.saveWorkout(saved)
        saved.startTime = start
        saved.date = start.startOfDay
        saved.features = workout("unused").features
        // The changed source is deliberately not saved before the import.
        _ = try await store.applyImportedWorkouts([workout("strava", source: .strava)],
                                                 deletedIDs: [], finalize: false)
        let alias = try XCTUnwrap(store.fetchWorkout(byId: "strava"))
        XCTAssertTrue(alias.isSuppressed)
        XCTAssertEqual(alias.linkedSessionID, "health")
    }

    func testDurableGroupAndLinkCollisionsStillReconcileSavedRows() async throws {
        for groupCollision in [true, false] {
            let context = ModelContext(try container())
            let store = DataStore(modelContext: context)
            let saved = workout("old", offset: -86_400)
            saved.sessionGroupID = groupCollision ? "new" : "old"
            saved.linkedSessionID = groupCollision ? nil : "new"
            saved.isSuppressed = true
            context.insert(saved)
            try context.save()
            _ = try await store.applyImportedWorkouts([workout("new")], deletedIDs: [], finalize: false)
            XCTAssertEqual(saved.sessionGroupID, "old")
            XCTAssertNil(saved.linkedSessionID)
            XCTAssertFalse(saved.isSuppressed)
        }
    }

    func testExistingSourceCorrectionSplitsPriorGroup() async throws {
        let store = DataStore(modelContainer: try container())
        try store.saveWorkouts([workout("health"), workout("strava", source: .strava)])
        _ = try await store.applyImportedWorkouts([workout("health", offset: 7200)],
                                                 deletedIDs: [], finalize: false)
        let rows = try store.allWorkouts()
        XCTAssertEqual(rows.filter { !$0.isSuppressed && !$0.isTombstoned }.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.linkedSessionID == nil && $0.sessionGroupID == $0.id })
    }

    func testCancellationRestartAndRepeatedImportRetainThousandDiskRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.store")
        let originalEstimateID = try await importWithCancellation(url: url)
        let reopened = try container(url: url)
        let context = reopened.mainContext
        let rows = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(rows.count, 1040)
        XCTAssertTrue(rows.allSatisfy { !$0.isSuppressed && !$0.isTombstoned })
        let old = try XCTUnwrap(rows.first { $0.id == "saved-0" })
        XCTAssertEqual(old.userTags, ["retained"])
        XCTAssertEqual(old.featuresData, workout("saved-0", offset: -86_400).featuresData)
        let estimates = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(estimates.map(\.id), [originalEstimateID])
        XCTAssertEqual(estimates.first?.inputData, Data("saved input".utf8))
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).map(\.sessionID), ["saved-0"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalObservation>()).map(\.sessionID), ["saved-0"])
    }

    private func importWithCancellation(url: URL) async throws -> UUID {
        let context = ModelContext(try container(url: url))
        let store = DataStore(modelContext: context)
        for index in 0..<1000 {
            let row = workout("saved-\(index)", offset: -86_400 - Double(index) * 3600)
            row.sessionGroupID = row.id
            if index == 0 { row.userTags = ["retained"] }
            context.insert(row)
        }
        let estimate = LoadEstimateRecord(sessionID: "saved-0", version: "retained", inputCutoff: start,
                                          computedAt: start, payloadData: Data("saved estimate".utf8),
                                          inputData: Data("saved input".utf8))
        context.insert(estimate)
        context.insert(StrengthSetRecord(sessionID: "saved-0", exerciseID: "squat", reps: 8, weightKG: 40))
        context.insert(LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2,
                                        observedAt: start, sessionID: "saved-0"))
        try context.save()
        func incoming() -> [Workout] {
            (0..<40).map { workout("new-\($0)", offset: Double($0) * 3600) }
        }
        var batches = 0
        do {
            _ = try await store.applyImportedWorkouts(incoming(), deletedIDs: [], validateSources: {
                batches += 1
                if batches == 2 { throw CancellationError() }
            }, prewarmed: WorkoutPrewarmedEndpoints())
            XCTFail("Cancellation must propagate after the first committed batch")
        } catch is CancellationError {}
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 1020)
        let retainedIDs = Set(try store.allWorkouts().map(\.id))
        _ = try await store.applyImportedWorkouts(incoming(), deletedIDs: [])
        XCTAssertTrue(retainedIDs.isSubset(of: Set(try store.allWorkouts().map(\.id))))
        let before = try states(store)
        let repeated = try await store.applyImportedWorkouts(incoming(), deletedIDs: [])
        XCTAssertTrue(repeated.isEmpty)
        XCTAssertEqual(try states(store), before)
        return estimate.id
    }
}
