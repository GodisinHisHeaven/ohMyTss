import XCTest
import SwiftData
import HealthKit
@testable import onMyTss

@MainActor
final class StravaSourceAvailabilityTests: XCTestCase {
    func testStravaImportUsesOnlyReportedValidElapsedForEnd() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        try store.saveStravaAuth(StravaAuth(isConnected: true))
        let client = SyntheticStravaClient()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inputs: [(Int, Any?)] = [(201, nil), (202, NSNull()), (203, 720), (204, 500), (205, 0)]
        client.listed = try inputs.enumerated().map { index, item in
            var object: [String: Any] = ["id": item.0, "start_date": ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(index) * 7200)),
                                         "moving_time": 600, "sport_type": "Run"]
            if let elapsed = item.1 { object["elapsed_time"] = elapsed }
            return try decoder.decode(StravaActivity.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let aggregator = WorkoutAggregator(healthKitManager: EmptyHealthSource(), stravaAuthManager: SyntheticStravaToken(), dataStore: store, stravaClient: client)
        _ = try await aggregator.fetchWorkouts(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(40000))
        let rows = Dictionary(uniqueKeysWithValues: aggregator.latestImportedWorkouts.map { ($0.id, $0) })
        for id in ["201", "202", "204", "205"] {
            let row = try XCTUnwrap(rows[id])
            XCTAssertNil(row.features.end, "Missing, null, or invalid elapsed time cannot establish an end")
            XCTAssertTrue(row.features.unavailableChannels.contains("elapsed"))
        }
        let paused = try XCTUnwrap(rows["203"])
        XCTAssertEqual(paused.features.end, paused.startTime.addingTimeInterval(720))
        XCTAssertFalse(paused.features.unavailableChannels.contains("elapsed"))
    }

    func testMissingElapsedPreservesSavedEndAndLaterCorrectionReplacesIt() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        try store.saveStravaAuth(StravaAuth(isConnected: true))
        let existing = source(id: 301, at: start)
        var prior = WorkoutFeatures()
        prior.end = start.addingTimeInterval(720)
        prior.heartRate = [TimedValue(start: start, end: start.addingTimeInterval(10), value: 140)]
        existing.features = prior
        try store.saveWorkout(existing)
        let client = SyntheticStravaClient()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func activity(elapsed: Int?) throws -> StravaActivity {
            var object: [String: Any] = ["id": 301, "start_date": ISO8601DateFormatter().string(from: start),
                                         "moving_time": 60, "sport_type": "Run"]
            if let elapsed { object["elapsed_time"] = elapsed }
            return try decoder.decode(StravaActivity.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let aggregator = WorkoutAggregator(healthKitManager: EmptyHealthSource(), stravaAuthManager: SyntheticStravaToken(), dataStore: store, stravaClient: client)
        client.listed = [try activity(elapsed: nil)]
        _ = try await aggregator.fetchWorkouts(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(3600))
        let incoming = try XCTUnwrap(aggregator.latestImportedWorkouts.first)
        // Other independently unavailable channels retain their existing data too.
        var incomplete = incoming.features
        incomplete.unavailableChannels.append("heartRate")
        incoming.features = incomplete
        try store.saveWorkouts([incoming])
        let saved = try XCTUnwrap(store.fetchWorkout(byId: "301"))
        XCTAssertEqual(saved.features.end, prior.end)
        XCTAssertEqual(saved.features.heartRate, prior.heartRate)
        XCTAssertTrue(saved.features.unavailableChannels.contains("elapsed"))

        client.listed = [try activity(elapsed: 780)]
        _ = try await aggregator.fetchWorkouts(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(3600))
        let corrected = try XCTUnwrap(aggregator.latestImportedWorkouts.first)
        var correction = corrected.features
        correction.unavailableChannels.append("heartRate")
        corrected.features = correction
        try store.saveWorkouts([corrected])
        XCTAssertEqual(saved.features.end, start.addingTimeInterval(780))
        XCTAssertFalse(saved.features.unavailableChannels.contains("elapsed"))
        XCTAssertEqual(saved.features.heartRate, prior.heartRate)
    }

    func testDetailReturnsMissingOnlyForHTTP404() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyntheticStravaHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let missing = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: 404, session: session)
        XCTAssertNil(missing)
        let present = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: 200, session: session)
        XCTAssertEqual(present?.id, 200)
        for status in [401, 403, 429, 500] {
            do {
                _ = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: status, session: session)
                XCTFail("HTTP \(status) must remain an error, never a missing source")
            } catch { /* Expected: retain local source. */ }
        }
    }

    func testFullListingVerifiesOnlyMissingKnownActivitiesInsideWindow() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: config)
        let store = DataStore(modelContainer: container)
        try store.saveStravaAuth(StravaAuth(isConnected: true))
        let sources = [
            source(id: 101, at: start.addingTimeInterval(100)),
            source(id: 102, at: start.addingTimeInterval(300)),
            source(id: 103, at: start.addingTimeInterval(600)),
            source(id: 104, at: start), // exact boundary: do not infer disappearance
            source(id: 105, at: start.addingTimeInterval(-100))
        ]
        try store.saveWorkouts(sources)
        let client = SyntheticStravaClient()
        client.listed = [try activity(id: 102, at: start.addingTimeInterval(300))]
        client.corrected[103] = try activity(id: 103, at: start.addingTimeInterval(4000))
        let aggregator = WorkoutAggregator(healthKitManager: EmptyHealthSource(), stravaAuthManager: SyntheticStravaToken(), dataStore: store, stravaClient: client)
        _ = try await aggregator.fetchWorkouts(from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(Set(client.detailRequests), [101, 103])
        XCTAssertEqual(aggregator.latestDeletedStravaIDs, ["101"])
        XCTAssertFalse(aggregator.warnings.isEmpty)
        XCTAssertFalse(aggregator.hasRetryableFailures)
        XCTAssertEqual(aggregator.latestImportedWorkouts.first(where: { $0.id == "103" })?.startTime, start.addingTimeInterval(4000))
    }

    func testFailedListingOrDetailNeverCreatesTombstones() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        try store.saveStravaAuth(StravaAuth(isConnected: true))
        try store.saveWorkout(source(id: 101, at: start.addingTimeInterval(100)))
        let client = SyntheticStravaClient()
        let aggregator = WorkoutAggregator(healthKitManager: EmptyHealthSource(), stravaAuthManager: SyntheticStravaToken(), dataStore: store, stravaClient: client)
        client.listFails = true
        _ = try await aggregator.fetchWorkouts(from: start, to: start.addingTimeInterval(3600))
        XCTAssertTrue(client.detailRequests.isEmpty)
        XCTAssertTrue(aggregator.latestDeletedStravaIDs.isEmpty)
        XCTAssertTrue(aggregator.hasRetryableFailures)
        client.listFails = false
        client.detailFails = true
        _ = try await aggregator.fetchWorkouts(from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(client.detailRequests, [101])
        XCTAssertTrue(aggregator.latestDeletedStravaIDs.isEmpty)
        XCTAssertTrue(aggregator.hasRetryableFailures)
        XCTAssertFalse(try XCTUnwrap(store.fetchWorkout(byId: "101")).isTombstoned)
        client.detailFails = false
        _ = try await aggregator.fetchWorkouts(from: start, to: start.addingTimeInterval(3600))
        XCTAssertFalse(aggregator.hasRetryableFailures)
    }

    private func source(id: Int, at date: Date) -> Workout {
        Workout(id: String(id), date: date.startOfDay, startTime: date, duration: 60, workoutType: "Run", tss: 1, calculationMethod: "duration", source: .strava, stravaId: id)
    }

    private func activity(id: Int, at date: Date) throws -> StravaActivity {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "start_date": ISO8601DateFormatter().string(from: date), "moving_time": 60, "sport_type": "Run"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StravaActivity.self, from: data)
    }
}

/// Fixed synthetic responses are keyed by requested activity ID. No real network
/// request, health record, mutable global handler or credential is used.
private final class SyntheticStravaHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.strava.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let status = Int(url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = status == 200 ? #"{"id":200,"start_date":"2023-11-14T22:13:20Z","moving_time":60,"sport_type":"Run"}"# : #"{"message":"synthetic response"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class SyntheticStravaClient: StravaActivityFetching {
    var listed: [StravaActivity] = []
    var corrected: [Int: StravaActivity] = [:]
    var detailRequests: [Int] = []
    var listFails = false
    var detailFails = false
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity] {
        if listFails { throw StravaAPI.StravaAPIError.unauthorized }
        return listed
    }
    func activity(accessToken: String, id: Int) async throws -> StravaActivity? {
        detailRequests.append(id)
        if detailFails { throw StravaAPI.StravaAPIError.httpError(403) }
        return corrected[id]
    }
}

@MainActor
private final class SyntheticStravaToken: StravaAuthManaging {
    func getValidAccessToken() async throws -> String { "synthetic-test-token" }
}

@MainActor
private final class EmptyHealthSource: HealthKitManaging {
    func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] { [] }
    func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        ([], [], HKQueryAnchor(fromValue: 0))
    }
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] { [] }
}
