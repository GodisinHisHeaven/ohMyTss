import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutEndpointDigestTests: XCTestCase {
    func testOverflowMatchesOnlyCurrentBytesAndKeepsSameIDVersions() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let old = try payload(start: start, end: 600)
        let incomingData = try payload(start: start, end: 900)
        let corrected = try payload(start: start, end: 1200)
        let stored = workout("source", .strava, start)
        stored.featuresData = old
        f.context.insert(stored)
        try f.context.save()
        let incoming = workout("source", .strava, start)
        incoming.featuresData = incomingData
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [incoming], byteLimit: 0, candidateIDs: { _ in ["source"] }
        )
        XCTAssertNil(cache.matching(id: "source", data: old))
        XCTAssertEqual(cache.matching(id: "source", data: old, allowDigest: true)?.end, start.addingTimeInterval(600))
        XCTAssertEqual(cache.matching(id: "source", data: incomingData, allowDigest: true)?.end, start.addingTimeInterval(900))
        XCTAssertNil(cache.matching(id: "source", data: corrected, allowDigest: true))
        XCTAssertNil(cache.matching(id: "other", data: old, allowDigest: true))
        XCTAssertNil(cache.matching(id: "source", data: nil, allowDigest: true))
    }

    func testOverflowPreservesNilEmptyAndCorruptFullDecodeSemantics() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let bad = try JSONSerialization.data(withJSONObject: [
            "end": start.addingTimeInterval(600).timeIntervalSinceReferenceDate,
            "heartRate": "corrupt channel"
        ])
        let nilRow = workout("nil", .strava, start)
        let empty = workout("empty", .strava, start)
        empty.featuresData = Data()
        let corrupt = workout("corrupt", .strava, start)
        corrupt.featuresData = bad
        for row in [nilRow, empty, corrupt] { f.context.insert(row) }
        try f.context.save()
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [], byteLimit: 0, candidateIDs: { _ in ["nil", "empty", "corrupt"] }
        )
        XCTAssertNil(try XCTUnwrap(cache.matching(id: "nil", data: nil)).end)
        XCTAssertNil(try XCTUnwrap(cache.matching(id: "empty", data: Data())).end)
        XCTAssertNil(try XCTUnwrap(cache.matching(id: "corrupt", data: bad, allowDigest: true)).end)
        XCTAssertNil(cache.matching(id: "corrupt", data: Data(), allowDigest: true))
    }

    func testDigestAndStagingLimitsFailBackWithoutGrowingRawBudget() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let data = try payload(start: start, end: 600)
        let ids = (0..<22).map { String(format: "row-%02d", $0) }
        for id in ids {
            let row = workout(id, .strava, start)
            row.featuresData = data
            f.context.insert(row)
        }
        try f.context.save()
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [], byteLimit: 0, digestEntryLimit: 2,
            digestStagingByteLimit: data.count, candidateIDs: { _ in ids }
        )
        XCTAssertNil(cache.matching(id: "row-00", data: data))
        XCTAssertNotNil(cache.matching(id: "row-00", data: data, allowDigest: true))
        XCTAssertNil(cache.matching(id: "row-01", data: data, allowDigest: true))
        XCTAssertNotNil(cache.matching(id: "row-20", data: data, allowDigest: true))
        XCTAssertNil(cache.matching(id: "row-21", data: data, allowDigest: true))
        let noRoom = try await f.store.prepareWorkoutEndpoints(
            incoming: [], byteLimit: 0, digestStagingByteLimit: data.count - 1,
            candidateIDs: { _ in ["row-00"] }
        )
        XCTAssertNil(noRoom.matching(id: "row-00", data: data, allowDigest: true))
        let longID = try await f.store.prepareWorkoutEndpoints(
            incoming: [], byteLimit: 0, digestIDByteLimit: 2,
            candidateIDs: { _ in ["row-00"] }
        )
        XCTAssertNil(longID.matching(id: "row-00", data: data, allowDigest: true))
    }

    func testTemporalDeletionProtectionIncludesSourceDeletedBridges() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let deleted = workout("deleted", .healthKit, start)
        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        let alias = workout("alias", .strava, start.addingTimeInterval(59))
        alias.isTombstoned = true
        alias.deletionOrigin = "source"
        let bridge = workout("bridge", .healthKit, start.addingTimeInterval(118))
        let separate = workout("separate", .strava, start.addingTimeInterval(178))
        XCTAssertEqual(DataStore.deletionSensitiveIDs([separate, bridge, alias, deleted]), ["deleted", "alias", "bridge"])
        alias.startTime = start.addingTimeInterval(3600)
        XCTAssertEqual(DataStore.deletionSensitiveIDs([separate, bridge, alias, deleted]), ["deleted"])
    }

    func testReconcileRecomputesSensitiveComponentsAfterPrewarm() throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let data = try payload(start: start, end: 600)
        let deleted = workout("deleted", .healthKit, start)
        let incoming = workout("active-strava", .strava, start)
        let bridge = workout("bridge-health", .healthKit, start.addingTimeInterval(3600))
        for row in [deleted, incoming, bridge] { row.featuresData = data; f.context.insert(row) }
        try f.context.save()

        // A forced hash collision would hide the bridge from the ambiguity
        // graph if its forged endpoint were used after these source changes.
        let fakeHash = Data(repeating: 0, count: 32)
        let cache = WorkoutPrewarmedEndpoints(digest: { _ in fakeHash })
        cache.append([
            PrewarmedWorkoutEndpoint(id: deleted.id, proof: .exact(data), end: start.addingTimeInterval(600)),
            PrewarmedWorkoutEndpoint(id: incoming.id, proof: .exact(data), end: start.addingTimeInterval(600)),
            PrewarmedWorkoutEndpoint(id: bridge.id, proof: .digest(byteCount: data.count, sha256: fakeHash), end: start.addingTimeInterval(900))
        ])
        XCTAssertEqual(cache.matching(id: bridge.id, data: data, allowDigest: true)?.end, start.addingTimeInterval(900))
        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        bridge.startTime = start.addingTimeInterval(59)
        _ = try f.store.reconcileWorkoutSources(applySideEffects: true, prewarmed: cache)
        XCTAssertTrue(deleted.isTombstoned)
        XCTAssertFalse(incoming.isTombstoned, "The possible same-source bridge must prevent deletion propagation")
        XCTAssertFalse(incoming.isSuppressed)
        XCTAssertFalse(bridge.isTombstoned)
        XCTAssertFalse(bridge.isSuppressed)
    }

    func testReusedOverflowDecodeDoesNotPropagateDeletionThroughCorrectedBridge() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let data = try payload(start: start, end: 600)
        let deleted = workout("deleted", .healthKit, start)
        let active = workout("active-strava", .strava, start)
        let bridge = workout("bridge-health", .healthKit, start.addingTimeInterval(3600))
        for row in [deleted, active, bridge] { row.featuresData = data; f.context.insert(row) }
        try f.context.save()
        let incomingBridge = workout(bridge.id, .healthKit, bridge.startTime)
        incomingBridge.featuresData = Data(Array(data))
        let observation = DigestBatchObservation()
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [incomingBridge], byteLimit: 0,
            candidateIDs: { _ in ["active-strava", "bridge-health", "deleted"] },
            decode: { values in
                await observation.record(values)
                return try await WorkoutEndpointPrewarmer.decode(values)
            }
        )
        let observed = await observation.sawDuplicate
        XCTAssertTrue(observed, "The real overflow batch must contain both versions")
        XCTAssertNil(cache.matching(id: bridge.id, data: data))
        XCTAssertEqual(cache.matching(id: bridge.id, data: data, allowDigest: true)?.end,
                       start.addingTimeInterval(600))

        deleted.isTombstoned = true
        deleted.deletionOrigin = "user"
        bridge.startTime = start.addingTimeInterval(59)
        _ = try f.store.reconcileWorkoutSources(applySideEffects: true, prewarmed: cache)
        XCTAssertTrue(deleted.isTombstoned)
        XCTAssertFalse(active.isTombstoned)
        XCTAssertFalse(active.isSuppressed)
        XCTAssertFalse(bridge.isTombstoned)
        XCTAssertFalse(bridge.isSuppressed)
    }

    func testCorrectedPayloadWhileDigestDecodesDoesNotReuseOldEndpoint() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", .healthKit, start)
        let strava = workout("strava", .strava, start)
        let old = try payload(start: start, end: 600)
        health.featuresData = old
        strava.featuresData = old
        f.context.insert(health)
        f.context.insert(strava)
        try f.context.save()
        let duplicate = workout("strava", .strava, start)
        duplicate.featuresData = Data(Array(old))
        let gate = DigestGate()
        let task = Task {
            try await f.store.prepareWorkoutEndpoints(incoming: [duplicate], byteLimit: 0, decode: { values in
                let decoded = try await WorkoutEndpointPrewarmer.decode(values)
                await gate.pause()
                return decoded
            })
        }
        await gate.waitUntilPaused()
        strava.featuresData = try payload(start: start, end: 900)
        await gate.release()
        let cache = try await task.value
        _ = try f.store.reconcileWorkoutSources(applySideEffects: false, prewarmed: cache)
        XCTAssertFalse(health.isSuppressed)
        XCTAssertFalse(strava.isSuppressed)
        XCTAssertEqual(strava.features.end, start.addingTimeInterval(900))
    }

    func testMergedNewPayloadFallsBackInsteadOfUsingEitherPriorDigest() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", .healthKit, start)
        health.sourceBundleIdentifier = "com.garmin.connect.mobile"
        var healthFeatures = WorkoutFeatures()
        healthFeatures.end = start.addingTimeInterval(600)
        health.features = healthFeatures
        let old = workout("strava", .strava, start)
        var oldFeatures = healthFeatures
        oldFeatures.heartRate = [TimedValue(start: start, end: start.addingTimeInterval(10), value: 140)]
        old.features = oldFeatures
        f.context.insert(health)
        f.context.insert(old)
        try f.context.save()
        let correction = workout("strava", .strava, start)
        var partial = healthFeatures
        partial.unavailableChannels = ["heartRate"]
        correction.features = partial
        let cache = try await f.store.prepareWorkoutEndpoints(
            incoming: [correction], byteLimit: 0, candidateIDs: { _ in ["health", "strava"] }
        )
        _ = try f.store.saveWorkouts([correction], prewarmed: cache)
        let saved = try XCTUnwrap(f.store.fetchWorkout(byId: "strava"))
        XCTAssertNil(cache.matching(id: saved.id, data: saved.featuresData, allowDigest: true))
        XCTAssertEqual(saved.features.heartRate, oldFeatures.heartRate)
        XCTAssertEqual(saved.features.end, start.addingTimeInterval(600))
        XCTAssertTrue(saved.isSuppressed)
        XCTAssertEqual(saved.linkedSessionID, health.id)
    }

    func testCancellationWhileOverflowDecodesDoesNotWriteSources() async throws {
        let f = try fixture()
        defer { withExtendedLifetime(f.container) {} }
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let row = workout("health", .healthKit, start)
        row.featuresData = try payload(start: start, end: 600)
        f.context.insert(row)
        try f.context.save()
        let incoming = workout("strava", .strava, start)
        incoming.featuresData = row.featuresData
        let gate = DigestGate()
        let task = Task {
            try await f.store.prepareWorkoutEndpoints(incoming: [incoming], byteLimit: 0, decode: { values in
                await gate.pause()
                return try await WorkoutEndpointPrewarmer.decode(values)
            })
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancellation must stop preparation") }
        catch is CancellationError { }
        XCTAssertEqual(try f.store.allWorkouts().map(\.id), ["health"])
    }

    private func payload(start: Date, end: Double) throws -> Data {
        var features = WorkoutFeatures()
        features.end = start.addingTimeInterval(end)
        return try JSONEncoder().encode(features)
    }
    private func workout(_ id: String, _ source: WorkoutSource, _ start: Date) -> Workout {
        Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                workoutType: "Running", tss: 10, calculationMethod: "duration", source: source)
    }
    private func fixture() throws -> (container: ModelContainer, context: ModelContext, store: onMyTss.DataStore) {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return (container, container.mainContext, DataStore(modelContext: container.mainContext))
    }
}

private actor DigestBatchObservation {
    private(set) var sawDuplicate = false
    func record(_ values: [WorkoutEndpointPayload]) {
        guard values.count > 1 else { return }
        for index in 1..<values.count {
            let before = values[index - 1]
            let current = values[index]
            if before.id == current.id, before.data == current.data {
                sawDuplicate = true
            }
        }
    }
}

private actor DigestGate {
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
