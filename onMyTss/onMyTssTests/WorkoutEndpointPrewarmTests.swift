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
