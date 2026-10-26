import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class V2EstimateResponsivenessTests: XCTestCase {
    func testHeartRateChangeOnThousandDiskRecordsKeepsMainActorResponsiveAndRetainsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: directory.appendingPathComponent("test.store"))])
        let context = container.mainContext
        let dataStore = DataStore(modelContext: context)
        let thresholds = try dataStore.fetchUserThresholds()
        thresholds.cardioMaxHeartRate = 190
        let now = Date()
        var originalIDs: Set<UUID> = []
        for index in 0..<1000 {
            let start = now.addingTimeInterval(-Double(index + 1) * 3600)
            let workout = Workout(id: "synthetic-hr-\(index)", date: start.startOfDay, startTime: start,
                                  duration: 300, workoutType: "Ride", tss: 25, calculationMethod: "hr", source: .manual)
            var features = WorkoutFeatures()
            features.end = start.addingTimeInterval(300)
            features.heartRate = (0..<30).map {
                TimedValue(start: start.addingTimeInterval(Double($0) * 10), end: start.addingTimeInterval(Double($0 + 1) * 10), value: 150)
            }
            workout.features = features
            context.insert(workout)
            let value = LoadModel.estimate(type: "Ride", start: start, duration: 300, distance: nil,
                                           features: features, sets: [], tags: [], maxHeartRate: 190, now: now)
            let old = LoadEstimateRecord(sessionID: workout.id, version: value.version, inputCutoff: value.inputCutoff,
                                         computedAt: now.addingTimeInterval(-1), payloadData: try JSONEncoder().encode(value), inputData: Data())
            context.insert(old)
            originalIDs.insert(old.id)
        }
        try context.save()
        thresholds.cardioMaxHeartRate = 170
        try dataStore.saveUserThresholds(thresholds)
        let heartbeat = MainActorHeartbeat()
        let monitor = Task { @MainActor in
            var previous = Date()
            while !heartbeat.finished {
                try await Task.sleep(for: .milliseconds(10))
                let current = Date()
                heartbeat.longestGap = max(heartbeat.longestGap, current.timeIntervalSince(previous))
                previous = current
                heartbeat.ticks += 1
            }
        }
        defer { heartbeat.finished = true; monitor.cancel() }
        let begin = Date()
        let refresh = Task { try await V2Store(context: context).refreshEstimates() }
        try await Task.sleep(for: .milliseconds(20))
        // A newer user value must win even if the old calculation is in flight.
        thresholds.cardioMaxHeartRate = 180
        try dataStore.saveUserThresholds(thresholds)
        try await refresh.value
        heartbeat.finished = true
        try await monitor.value
        print("HEART_RATE_DISK_REFRESH seconds=\(Date().timeIntervalSince(begin)) max_main_gap=\(heartbeat.longestGap) ticks=\(heartbeat.ticks)")
        XCTAssertGreaterThan(heartbeat.ticks, 1, "UI work must run during the history refresh")
        XCTAssertLessThan(heartbeat.longestGap, 1, "A history refresh must not monopolize the main actor")
        let rows = try context.fetch(FetchDescriptor<LoadEstimateRecord>(sortBy: [SortDescriptor(\.computedAt, order: .reverse)]))
        XCTAssertTrue(originalIDs.isSubset(of: Set(rows.map(\.id))))
        var latest: [String: LoadEstimateRecord] = [:]
        for row in rows where latest[row.sessionID] == nil { latest[row.sessionID] = row }
        XCTAssertEqual(latest.count, 1000)
        for row in latest.values {
            let input = try JSONDecoder().decode(HeartRateInputProbe.self, from: row.inputData)
            XCTAssertEqual(input.maxHeartRate, 180)
            XCTAssertEqual(try XCTUnwrap(row.value?.cardio?.points), 20, accuracy: 0.00001)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workout>()), 1000)
        let count = rows.count
        try await V2Store(context: context).refreshEstimates()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), count)
    }

    func testConcurrentRefreshesDoNotDuplicateSnapshots() async throws {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let now = Date()
        for index in 0..<1000 {
            let start = now.addingTimeInterval(-Double(index + 1) * 3600)
            context.insert(Workout(id: "concurrent-\(index)", date: start.startOfDay, startTime: start,
                                   duration: 300, workoutType: "Ride", tss: 25, calculationMethod: "hr", source: .manual))
        }
        try context.save()
        let first = Task { try await V2Store(context: context).refreshEstimates() }
        let second = Task { try await V2Store(context: context).refreshEstimates() }
        try await first.value
        try await second.value
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 1000)
    }
}

private struct HeartRateInputProbe: Decodable {
    var maxHeartRate: Int?
}

@MainActor private final class MainActorHeartbeat {
    var finished = false
    var ticks = 0
    var longestGap: TimeInterval = 0
    nonisolated deinit {}
}
