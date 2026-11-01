import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutOfflineRepairPerformanceTests: XCTestCase {
    func testDenseUnreconciledHistoryRepairsWithoutBlockingMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("repair.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let store = DataStore(modelContext: context)
        let state = try store.fetchAppState()
        let oldAnchor = Data([1, 2, 3, 4])
        state.healthKitAnchor = oldAnchor
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let encoder = JSONEncoder()
        var originals: [String: Data] = [:]
        for index in 0..<500 {
            let start = now.addingTimeInterval(-Double(index + 1) * 3_600)
            var features = WorkoutFeatures()
            features.end = start.addingTimeInterval(600)
            features.heartRate = (0..<300).map { sample in
                let time = start.addingTimeInterval(Double(sample) * 2)
                return TimedValue(start: time, end: time.addingTimeInterval(2), value: 140)
            }
            let payload = try encoder.encode(features)
            let health = Workout(id: "health-\(index)", date: start.startOfDay, startTime: start,
                                 duration: 600, workoutType: "Running", tss: 20,
                                 calculationMethod: "duration", source: .healthKit)
            health.sourceBundleIdentifier = "com.garmin.connect.mobile"
            health.featuresData = payload
            health.userTags = ["health-tag-\(index)"]
            let strava = Workout(id: "strava-\(index)", date: start.startOfDay, startTime: start,
                                 duration: 600, workoutType: "Run", tss: 20,
                                 calculationMethod: "duration", source: .strava)
            strava.featuresData = payload
            strava.userTags = ["strava-tag-\(index)"]
            originals[health.id] = payload
            originals[strava.id] = payload
            context.insert(health)
            context.insert(strava)
        }
        try context.save()
        let heartbeat = OfflineRepairHeartbeat()
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
        try await Task.sleep(for: .milliseconds(20))
        let started = Date()
        let changes = try await store.repairWorkoutSourcesLocally()
        let elapsed = Date().timeIntervalSince(started)
        heartbeat.finished = true
        try await monitor.value
        let rows = try store.allWorkouts()
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(rows.count, 1_000)
        XCTAssertEqual(rows.filter { !$0.isTombstoned && !$0.isSuppressed }.count, 500)
        XCTAssertTrue(rows.filter { !$0.isSuppressed }.allSatisfy { $0.source == WorkoutSource.healthKit.rawValue })
        XCTAssertTrue(rows.allSatisfy { $0.featuresData == originals[$0.id] && $0.userTags.count == 1 })
        XCTAssertEqual(state.healthKitAnchor, oldAnchor)
        print("OFFLINE_REPAIR_DENSE pairs=500 samples=300 seconds=\(elapsed) max_main_gap=\(heartbeat.maxGap) ticks=\(heartbeat.ticks)")
        XCTAssertGreaterThan(heartbeat.ticks, 1)
        XCTAssertLessThan(heartbeat.maxGap, 1, "Offline repair must not block the main actor for a second")
    }
}

@MainActor private final class OfflineRepairHeartbeat {
    var finished = false
    var ticks = 0
    var maxGap: TimeInterval = 0
    nonisolated deinit {}
}
