import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutLongPayloadPerformanceTests: XCTestCase {
    func testLongSensorPayloadRetainsDataAndRecordsMainActorGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("workouts.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let store = DataStore(modelContext: context)
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        // Each persisted source has a realistic sensor payload. The previous
        // one-record test has only 30 samples and does not exercise repeated
        // historical source comparisons over multiple import batches.
        var expectedPayloads: [String: Data] = [:]
        let encoder = JSONEncoder()
        func pair(_ index: Int) throws -> (Workout, Workout) {
            let start = now.addingTimeInterval(-Double(index + 1) * 3_600)
            var features = WorkoutFeatures()
            features.end = start.addingTimeInterval(600)
            features.heartRate = (0..<1500).map { sample in
                let sampleStart = start.addingTimeInterval(Double(sample) * 2)
                return TimedValue(start: sampleStart, end: sampleStart.addingTimeInterval(2), value: 140)
            }
            let payload = try encoder.encode(features)
            let suffix = String(format: "%05d", index)
            let health = Workout(id: "health-\(suffix)", date: start.startOfDay, startTime: start,
                                 duration: 600, workoutType: "Running", tss: 20,
                                 calculationMethod: "duration", source: .healthKit)
            health.sourceBundleIdentifier = "com.garmin.connect.mobile"
            health.featuresData = payload
            let strava = Workout(id: "strava-\(suffix)", date: start.startOfDay, startTime: start,
                                 duration: 600, workoutType: "Run", tss: 20,
                                 calculationMethod: "duration", source: .strava)
            strava.featuresData = payload
            expectedPayloads[health.id] = payload
            expectedPayloads[strava.id] = payload
            return (health, strava)
        }

        let historicalCount = 100
        for index in 0..<historicalCount {
            let (health, strava) = try pair(index)
            health.sessionGroupID = health.id
            strava.sessionGroupID = health.id
            strava.isSuppressed = true
            strava.linkedSessionID = health.id
            context.insert(health)
            context.insert(strava)
        }
        try context.save()

        var imported: [Workout] = []
        for index in historicalCount..<(historicalCount + 20) {
            let (health, strava) = try pair(index)
            imported.append(contentsOf: [strava, health])
        }
        let heartbeat = LongPayloadHeartbeat()
        let monitor = Task { @MainActor in
            var previous = Date()
            while !heartbeat.finished {
                try await Task.sleep(for: .milliseconds(10))
                let current = Date()
                heartbeat.maxGap = max(heartbeat.maxGap, current.timeIntervalSince(previous))
                heartbeat.ticks += 1
                previous = current
            }
        }
        defer { heartbeat.finished = true; monitor.cancel() }
        // Start the heartbeat before the synchronous first reconciliation.
        try await Task.sleep(for: .milliseconds(20))
        let started = Date()
        try await store.applyImportedWorkouts(imported, deletedIDs: [])
        let importSeconds = Date().timeIntervalSince(started)
        let repeatedStarted = Date()
        try await store.applyImportedWorkouts(imported, deletedIDs: [])
        let repeatedSeconds = Date().timeIntervalSince(repeatedStarted)
        heartbeat.finished = true
        try await monitor.value

        let rows = try store.allWorkouts()
        let active = rows.filter { !$0.isTombstoned && !$0.isSuppressed }
        XCTAssertEqual(rows.count, (historicalCount + 20) * 2)
        XCTAssertEqual(active.count, historicalCount + 20)
        XCTAssertTrue(active.allSatisfy { $0.source == WorkoutSource.healthKit.rawValue })
        XCTAssertTrue(rows.allSatisfy { $0.featuresData == expectedPayloads[$0.id] })
        for row in rows where row.source == WorkoutSource.strava.rawValue {
            XCTAssertTrue(row.isSuppressed)
            XCTAssertNotNil(row.linkedSessionID)
        }
        print("RECONCILE_LONG historical_pairs=\(historicalCount) imported_rows=\(imported.count) samples=1500 import_seconds=\(importSeconds) repeat_seconds=\(repeatedSeconds) max_main_gap=\(heartbeat.maxGap) ticks=\(heartbeat.ticks)")
        XCTAssertGreaterThan(heartbeat.ticks, 1)
    }
}

@MainActor private final class LongPayloadHeartbeat {
    var finished = false
    var ticks = 0
    var maxGap: TimeInterval = 0
    nonisolated deinit {}
}
