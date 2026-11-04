import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class V2ScopedEstimateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func workout(_ id: String, daysAgo: Double = 0, type: String = "Ride", source: WorkoutSource = .manual) -> Workout {
        let start = now.addingTimeInterval(-daysAgo * 86400)
        return Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                       workoutType: type, tss: 20, calculationMethod: "duration", source: source)
    }

    private func assertMatchesFullHistory(_ context: ModelContext, id: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let full = try V2EstimateBatch(context: context).calculate(now: now, sessionID: id)
        let scoped = try V2EstimateBatch(context: context, sessionID: id).calculate(now: now, sessionID: id)
        XCTAssertEqual(scoped.map(\.inputData), full.map(\.inputData), file: file, line: line)
        XCTAssertEqual(scoped.map(\.payloadData), full.map(\.payloadData), file: file, line: line)
    }

    func testSingleSessionRetainsGarminSourceChainAndRunningWindowAcrossCorrections() throws {
        let container = try container()
        let context = container.mainContext
        let root = workout("root", source: .healthKit)
        root.sourceBundleIdentifier = "com.garmin.connect.mobile"
        var features = WorkoutFeatures()
        features.heartRate = [TimedValue(start: now, end: now.addingTimeInterval(300), value: 150)]
        root.features = features
        let alias = workout("alias", daysAgo: 60, source: .strava)
        alias.isSuppressed = true
        alias.linkedSessionID = root.id
        features.heartRate = [TimedValue(start: now, end: now.addingTimeInterval(600), value: 160)]
        alias.features = features
        let deletedSource = workout("deleted-source", daysAgo: 90)
        deletedSource.linkedSessionID = alias.id
        deletedSource.isSuppressed = true
        deletedSource.isTombstoned = true
        deletedSource.deletionOrigin = "source"
        deletedSource.userTags = ["standing"]
        let cutBranch = workout("user-deleted")
        cutBranch.linkedSessionID = root.id
        cutBranch.isSuppressed = true
        cutBranch.isTombstoned = true
        cutBranch.deletionOrigin = "user"
        let cutChild = workout("cut-child")
        cutChild.linkedSessionID = cutBranch.id
        cutChild.isSuppressed = true
        let included = workout("run-at-boundary", daysAgo: 28, type: "RUNNING")
        let older = workout("run-too-old", daysAgo: 28.001, type: "Running")
        let overlapping = workout("overlapping-run", daysAgo: 0.001, type: "Run")
        let suppressed = workout("suppressed-run", daysAgo: 2, type: "Run")
        suppressed.isSuppressed = true
        let future = workout("future-run", daysAgo: -1, type: "Run")
        let unrelated = workout("other-ride", daysAgo: 1)
        for row in [root, alias, deletedSource, cutBranch, cutChild, included, older, overlapping, suppressed, future, unrelated] {
            context.insert(row)
        }
        for id in [root.id, alias.id, deletedSource.id, cutChild.id, unrelated.id] {
            context.insert(StrengthSetRecord(sessionID: id, exerciseID: "squat", reps: 8))
        }
        try context.save()

        let scoped = try V2EstimateBatch(context: context, sessionID: root.id)
        XCTAssertEqual(Set(scoped.sessions.map(\.id)), [root.id, alias.id, deletedSource.id, included.id, overlapping.id])
        XCTAssertEqual(Set(scoped.sets.map(\.sessionID)), [root.id, alias.id, deletedSource.id])
        try assertMatchesFullHistory(context, id: root.id)

        // Pending source corrections must immediately detach old personal data.
        alias.linkedSessionID = nil
        alias.isSuppressed = false
        try assertMatchesFullHistory(context, id: root.id)
        XCTAssertEqual(Set(try V2EstimateBatch(context: context, sessionID: root.id).sets.map(\.sessionID)), [root.id])
        XCTAssertEqual(deletedSource.userTags, ["standing"])

        // Cycles must terminate and still agree with the existing graph rules.
        root.linkedSessionID = deletedSource.id
        alias.linkedSessionID = root.id
        alias.isSuppressed = true
        try assertMatchesFullHistory(context, id: root.id)
        root.isTombstoned = true
        XCTAssertTrue(try V2EstimateBatch(context: context, sessionID: root.id).calculate(now: now, sessionID: root.id).isEmpty)
    }

    func testLatestMetadataSelectionRetainsInvalidNewestInputAndPendingRevision() throws {
        let container = try container()
        let context = container.mainContext
        func insert(_ id: String, _ time: Double, _ input: Data) {
            context.insert(LoadEstimateRecord(sessionID: id, version: String(time), inputCutoff: now,
                computedAt: now.addingTimeInterval(time), payloadData: Data(), inputData: input))
        }
        insert("a", 5, Data("invalid-newest".utf8))
        insert("b", 4, Data([4]))
        insert("a", 1, Data([1]))
        insert("unrelated", 10, Data([10]))
        try context.save()
        let latest = try V2EstimateBatch.latestEstimates(context: context, sessionIDs: ["a", "b", "missing"])
        XCTAssertEqual(Set(latest.keys), ["a", "b"])
        XCTAssertEqual(latest["a"]?.inputData, Data("invalid-newest".utf8))
        XCTAssertEqual(latest["b"]?.version, "4.0")
        insert("a", 6, Data([6]))
        XCTAssertEqual(try V2EstimateBatch.latestEstimates(context: context, sessionIDs: ["a"])["a"]?.inputData, Data([6]))
        XCTAssertTrue(try V2EstimateBatch.latestEstimates(context: context, sessionIDs: []).isEmpty)
    }

    func testDetailQueriesRetainLinkedRecordsAndExcludeUnrelatedHistory() throws {
        let container = try container()
        let context = container.mainContext
        let root = workout("root")
        let alias = workout("alias")
        alias.linkedSessionID = root.id
        alias.isSuppressed = true
        alias.isTombstoned = true
        alias.deletionOrigin = "source"
        alias.userTags = ["standing"]
        let other = workout("other")
        for row in [root, alias, other] {
            context.insert(row)
            context.insert(StrengthSetRecord(sessionID: row.id, exerciseID: "squat", reps: 8))
            context.insert(LocalObservation(regionRaw: "quads", sessionID: row.id))
            context.insert(LoadEstimateRecord(sessionID: row.id, version: "old", inputCutoff: now,
                computedAt: now, payloadData: Data("invalid".utf8), inputData: Data([1, 2, 3])))
        }
        context.insert(LocalObservation(regionRaw: "quads"))
        try context.save()
        let candidates = try context.fetch(V2ActivityDetailProjection.linkMetadata())
        let linked = V2ActivityDetailProjection.linkedSources(for: root, in: candidates)
        XCTAssertEqual(linked.map(\.id), [alias.id])
        XCTAssertEqual(linked.first?.userTags, ["standing"])
        let ids = [root.id] + linked.map(\.id)
        XCTAssertEqual(Set(try context.fetch(V2ActivityDetailProjection.sets(sessionIDs: ids)).map(\.sessionID)), Set(ids))
        XCTAssertEqual(Set(try context.fetch(V2ActivityDetailProjection.reports(sessionIDs: ids)).compactMap(\.sessionID)), Set(ids))
        let revisions = try context.fetch(V2ActivityDetailProjection.revisions(sessionID: root.id))
        XCTAssertEqual(revisions.map(\.sessionID), [root.id])
        XCTAssertEqual(revisions.first?.payloadData, Data("invalid".utf8))
        XCTAssertNil(revisions.first?.value)
        // Fields omitted from display fetches remain available for recalculation.
        XCTAssertEqual(revisions.first?.inputData, Data([1, 2, 3]))
        alias.linkedSessionID = nil
        let corrected = try context.fetch(V2ActivityDetailProjection.linkMetadata())
        XCTAssertTrue(V2ActivityDetailProjection.linkedSources(for: root, in: corrected).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalObservation>()), 4)
    }

    func testThousandSensorHistoriesDoNotEnterSingleActivitySnapshotAndRemainUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.store")
        let encoder = JSONEncoder()
        var features = WorkoutFeatures()
        features.heartRate = (0..<600).map {
            let time = now.addingTimeInterval(Double($0))
            return TimedValue(start: time, end: time.addingTimeInterval(1), value: 150)
        }
        let payload = try encoder.encode(features)
        do {
            let container = try container(url: url)
            let context = container.mainContext
            for index in 0..<1000 {
                let row = workout("history-\(index)", daysAgo: Double(index + 40))
                row.featuresData = payload
                row.userTags = ["retained"]
                context.insert(row)
                context.insert(StrengthSetRecord(sessionID: row.id, exerciseID: "squat", reps: 8))
                for revision in 0..<3 {
                    context.insert(LoadEstimateRecord(sessionID: row.id, version: "old", inputCutoff: row.startTime,
                        computedAt: now.addingTimeInterval(Double(revision)), payloadData: Data(), inputData: payload))
                }
            }
            context.insert(workout("selected", type: "Strength"))
            try context.save()
        }
        // Reopen so warm model instances cannot hide full-history reads.
        let container = try container(url: url)
        let context = container.mainContext
        let start = Date()
        let scoped = try V2EstimateBatch(context: context, sessionID: "selected")
        let snapshotSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(scoped.sessions.map(\.id), ["selected"])
        XCTAssertTrue(scoped.sets.isEmpty)
        XCTAssertTrue(scoped.previous.isEmpty)
        let row = try XCTUnwrap(DataStore(modelContext: context).fetchWorkout(byId: "selected"))
        let store = V2Store(context: context, clock: { self.now })
        let saveStart = Date()
        try store.saveSet(StrengthSetRecord(sessionID: row.id, exerciseID: "squat", reps: 10))
        let saveSeconds = Date().timeIntervalSince(saveStart)
        try store.recalculate(row)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 3001)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 1001)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StrengthSetRecord>()), 1001)
        let retained = try XCTUnwrap(DataStore(modelContext: context).fetchWorkout(byId: "history-999"))
        XCTAssertEqual(retained.featuresData, payload)
        XCTAssertEqual(retained.userTags, ["retained"])
        try assertMatchesFullHistory(context, id: row.id)
        print("SCOPED_ESTIMATE_DISK workouts=1001 previous=3000 payload_bytes=\(payload.count) snapshot_seconds=\(snapshotSeconds) save_seconds=\(saveSeconds)")
    }
}
