import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutEndpointPrewarmTests: XCTestCase {
    func testCandidateSelectionAndWholePayloadDecode() async throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        func item(_ id: String, _ source: String, _ type: String, _ offset: Double) -> WorkoutEndpointCandidate {
            WorkoutEndpointCandidate(id: id, start: start.addingTimeInterval(offset), duration: 600, type: type, source: source)
        }
        let ids = try await WorkoutEndpointPrewarmer.candidateIDs([
            item("health", "healthKit", "Other", 0), item("strava", "strava", "Run", 0),
            item("far", "strava", "Run", 3600), item("manual", "manual", "Run", 0),
            item("cycle", "strava", "Ride", 7200), item("run", "healthKit", "Running", 7200)
        ])
        XCTAssertEqual(Set(ids), ["health", "strava"])
        let malformed = try JSONSerialization.data(withJSONObject: [
            "end": start.addingTimeInterval(900).timeIntervalSinceReferenceDate,
            "heartRate": "invalid legacy data"
        ])
        let decoded = try await WorkoutEndpointPrewarmer.decode([
            WorkoutEndpointPayload(id: "bad", data: malformed), WorkoutEndpointPayload(id: "nil", data: nil)
        ])
        XCTAssertNil(decoded[0].end)
        XCTAssertNil(decoded[1].end)
    }

    func testCorrectionDuringPrewarmIsNeverReadFromStaleCache() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", .healthKit, start)
        let strava = workout("strava", .strava, start)
        var features = WorkoutFeatures()
        features.end = start.addingTimeInterval(600)
        health.features = features
        strava.features = features
        f.context.insert(health)
        f.context.insert(strava)
        try f.context.save()
        let gate = EndpointGate()
        let task = Task {
            try await f.store.prepareWorkoutEndpoints(incoming: [], decode: { payloads in
                let result = try await WorkoutEndpointPrewarmer.decode(payloads)
                await gate.pause()
                return result
            })
        }
        await gate.waitUntilPaused()
        features.end = start.addingTimeInterval(900)
        strava.features = features
        let corrected = strava.featuresData
        await gate.release()
        let cache = try await task.value
        _ = try f.store.reconcileWorkoutSources(applySideEffects: false, prewarmed: cache)
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
        XCTAssertEqual(strava.featuresData, corrected)
    }

    func testZeroBudgetFallsBackAndRetainsFullPayload() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", .healthKit, start)
        let strava = workout("strava", .strava, start)
        var features = WorkoutFeatures()
        features.end = start.addingTimeInterval(600)
        health.features = features
        strava.features = features
        let original = health.featuresData
        f.context.insert(health)
        f.context.insert(strava)
        try f.context.save()
        let cache = try await f.store.prepareWorkoutEndpoints(incoming: [], byteLimit: 0)
        _ = try f.store.reconcileWorkoutSources(applySideEffects: false, prewarmed: cache)
        XCTAssertEqual([health, strava].filter { !$0.isSuppressed }.count, 1)
        XCTAssertEqual(health.featuresData, original)
        XCTAssertEqual(strava.featuresData, original)
    }

    func testBatchedLookupUsesCurrentRowsAndBothVersionsOfAnIncomingID() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        func payload(_ offset: Double) throws -> Data {
            var features = WorkoutFeatures()
            features.end = start.addingTimeInterval(offset)
            return try JSONEncoder().encode(features)
        }
        let oldData = try payload(600)
        let correctedData = try payload(900)
        let incomingData = try payload(1200)
        let identifiers = (0..<43).map { String(format: "row-%02d", $0) }
        for id in identifiers {
            let row = workout(id, .healthKit, start)
            row.featuresData = oldData
            f.context.insert(row)
        }
        try f.context.save()
        let incoming = workout("new-source", .strava, start)
        incoming.featuresData = incomingData
        let gate = EndpointGate()
        let requested = identifiers + ["missing", "new-source"]
        let task = Task {
            try await f.store.prepareWorkoutEndpoints(incoming: [incoming], candidateIDs: { _ in
                await gate.pause()
                return requested
            })
        }
        await gate.waitUntilPaused()
        let deleted = try XCTUnwrap(f.store.fetchWorkout(byId: "row-02"))
        f.context.delete(deleted)
        let corrected = try XCTUnwrap(f.store.fetchWorkout(byId: "row-21"))
        corrected.featuresData = correctedData
        let inserted = workout("new-source", .strava, start)
        inserted.featuresData = correctedData
        f.context.insert(inserted)
        try f.context.save()
        await gate.release()
        let cache = try await task.value

        XCTAssertNil(cache.matching(id: "row-02", data: oldData))
        XCTAssertNil(cache.matching(id: "missing", data: nil))
        XCTAssertEqual(cache.matching(id: "row-21", data: correctedData)?.end, start.addingTimeInterval(900))
        XCTAssertNil(cache.matching(id: "row-21", data: oldData))
        XCTAssertEqual(cache.matching(id: "row-42", data: oldData)?.end, start.addingTimeInterval(600))
        XCTAssertEqual(cache.matching(id: "new-source", data: correctedData)?.end, start.addingTimeInterval(900))
        XCTAssertEqual(cache.matching(id: "new-source", data: incomingData)?.end, start.addingTimeInterval(1200))
    }

    func testBatchedLookupKeepsStoredBeforeIncomingWithinBudget() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var firstFeatures = WorkoutFeatures()
        firstFeatures.end = start.addingTimeInterval(600)
        let firstData = try JSONEncoder().encode(firstFeatures)
        firstFeatures.end = start.addingTimeInterval(900)
        let incomingData = try JSONEncoder().encode(firstFeatures)
        let ids = (0..<23).map { String(format: "row-%02d", $0) }
        for id in ids {
            let row = workout(id, .healthKit, start)
            if id != "row-22" { row.featuresData = firstData }
            f.context.insert(row)
        }
        try f.context.save()
        let incoming = workout("row-00", .healthKit, start)
        incoming.featuresData = incomingData
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [incoming], byteLimit: firstData.count + incomingData.count,
            candidateIDs: { _ in ids }
        )
        XCTAssertEqual(cache.matching(id: "row-00", data: firstData)?.end, start.addingTimeInterval(600))
        XCTAssertEqual(cache.matching(id: "row-00", data: incomingData)?.end, start.addingTimeInterval(900))
        XCTAssertNil(cache.matching(id: "row-01", data: firstData))
        let empty = try XCTUnwrap(cache.matching(id: "row-22", data: nil))
        XCTAssertNil(empty.end)
    }

    func testCancellationAndChangedSourceBeforeWritingImport() async throws {
        for cancel in [true, false] {
            let f = try fixture()
            defer { withExtendedLifetime(f.container) {} }
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            f.context.insert(workout("health", .healthKit, start))
            try f.context.save()
            let incoming = workout("strava", .strava, start)
            let gate = EndpointGate()
            var sourceValid = true
            let task = Task {
                try await f.store.prepareWorkoutEndpoints(incoming: [incoming], validateSources: {
                    if !sourceValid { throw TestSourceError.changed }
                }, candidateIDs: { inputs in
                    await gate.pause()
                    return try await WorkoutEndpointPrewarmer.candidateIDs(inputs)
                })
            }
            await gate.waitUntilPaused()
            if cancel { task.cancel() } else { sourceValid = false }
            await gate.release()
            do {
                _ = try await task.value
                XCTFail("Preparation should stop before writing an imported workout")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch TestSourceError.changed {
                XCTAssertFalse(cancel)
            }
            XCTAssertEqual(try f.store.allWorkouts().map(\.id), ["health"])
        }
    }

    private func workout(_ id: String, _ source: WorkoutSource, _ start: Date) -> Workout {
        Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                workoutType: "Running", tss: 10, calculationMethod: "duration", source: source)
    }
    private func fixture() throws -> (container: ModelContainer, context: ModelContext, store: onMyTss.DataStore) {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return (container, container.mainContext, DataStore(modelContext: container.mainContext))
    }
}

private enum TestSourceError: Error { case changed }
private actor EndpointGate {
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        pauseWaiter?.resume()
        pauseWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
