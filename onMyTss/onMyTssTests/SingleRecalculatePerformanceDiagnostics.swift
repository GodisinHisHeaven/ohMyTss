import Foundation
import CryptoKit
import SwiftData
import XCTest
@testable import onMyTss

// Synthetic disk fixture only; never insert real HealthKit data in this test.
@MainActor
final class SingleRecalculatePerformanceDiagnostics: XCTestCase {
    func testRecalculateThousandDiskRunsPreservesPersonalData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("single-recalculate.store")
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        let now = base.addingTimeInterval(3600)
        let targetID = "synthetic-target"
        let schema = Schema(AppSchema.models)
        func makeContainer() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        }
        try autoreleasepool {
            let container = try makeContainer()
            let context = ModelContext(container)
            let thresholds = try DataStore(modelContext: context).fetchUserThresholds()
            thresholds.lastModified = base
            for index in 0...1000 {
                let start = base.addingTimeInterval(-Double(index) * 86_400)
                let id = index == 0 ? targetID : String(format: "synthetic-history-%04d", index)
                let row = Workout(id: id, date: start.startOfDay, startTime: start, duration: 1800,
                                  workoutType: "Running", tss: 30, calculationMethod: "duration", source: .healthKit)
                var features = WorkoutFeatures()
                features.end = start.addingTimeInterval(1800)
                features.heartRate = (0..<600).map { sample in
                    let from = start.addingTimeInterval(Double(sample))
                    return TimedValue(start: from, end: from.addingTimeInterval(1), value: 140)
                }
                row.features = features
                context.insert(row)
            }
            let fixedSet = StrengthSetRecord(sessionID: targetID, exerciseID: "squat", reps: 7, weightKG: 35, rir: 2)
            fixedSet.id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            fixedSet.recordedAt = base
            fixedSet.updatedAt = base
            context.insert(fixedSet)
            context.insert(LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2,
                                            observedAt: base, sessionID: targetID))
            context.insert(LoadEstimateRecord(sessionID: targetID, version: "synthetic-older", inputCutoff: base,
                                              computedAt: base, payloadData: Data([1, 2]), inputData: Data([3, 4])))
            try context.save()
        }
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = DataStore(modelContext: context)
        let target = try XCTUnwrap(store.fetchWorkout(byId: targetID))
        let before = try context.fetch(FetchDescriptor<Workout>())
        let originalBytes = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.featuresData) })
        let payloadBytes = before.reduce(0) { $0 + ($1.featuresData?.count ?? 0) }
        XCTAssertEqual(before.count, 1001)
        let heartbeat = RecalculationHeartbeat()
        let monitor = Task { @MainActor in
            let heartbeatClock = ContinuousClock()
            var previous = heartbeatClock.now
            while !heartbeat.finished {
                try await Task.sleep(for: .milliseconds(10))
                let now = heartbeatClock.now
                let gap = previous.duration(to: now).components
                let gapSeconds = Double(gap.seconds) + Double(gap.attoseconds) / 1e18
                heartbeat.maxGap = max(heartbeat.maxGap, gapSeconds)
                heartbeat.ticks += 1
                previous = now
            }
        }
        defer { heartbeat.finished = true; monitor.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let begin = clock.now
        try V2Store(context: context, clock: { now }).recalculate(target)
        let duration = begin.duration(to: clock.now)
        try await Task.sleep(for: .milliseconds(20))
        heartbeat.finished = true
        try await monitor.value
        let after = try context.fetch(FetchDescriptor<Workout>())
        XCTAssertEqual(after.count, before.count)
        for row in after {
            XCTAssertEqual(row.featuresData, originalBytes[row.id] ?? nil)
        }
        let allEstimates = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(allEstimates.count, 2)
        XCTAssertTrue(allEstimates.contains { $0.version == "synthetic-older" && $0.inputData == Data([3, 4]) })
        let current = try XCTUnwrap(allEstimates.first { $0.version == LoadModel.version })
        let probe = try JSONDecoder().decode(RecalculateInputProbe.self, from: current.inputData)
        XCTAssertEqual(probe.recentRunningMinutes, 840)
        let sets = try context.fetch(FetchDescriptor<StrengthSetRecord>())
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.reps, 7)
        XCTAssertEqual(sets.first?.weightKG, 35)
        let observations = try context.fetch(FetchDescriptor<LocalObservation>())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.severity, 2)
        XCTAssertGreaterThan(heartbeat.ticks, 1)
        let elapsedParts = duration.components
        let elapsedSeconds = Double(elapsedParts.seconds) + Double(elapsedParts.attoseconds) / 1e18
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        print("SINGLE_RECALCULATE synthetic_workouts=1001 history_samples=600 payload_bytes=\(payloadBytes) elapsed_seconds=\(elapsedSeconds) max_main_gap_seconds=\(heartbeat.maxGap) ticks=\(heartbeat.ticks) input_sha256=\(digest(current.inputData)) output_sha256=\(digest(current.payloadData))")
    }
}

@MainActor private final class RecalculationHeartbeat {
    var finished = false
    var ticks = 0
    var maxGap: TimeInterval = 0
    nonisolated deinit {}
}

private struct RecalculateInputProbe: Decodable {
    let recentRunningMinutes: Double?
}
