import XCTest
@testable import onMyTss

@MainActor
final class V2TodaySummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testInvalidIntensityThresholdsDoNotReadSourcePayloads() {
        let rows = (0..<100).map { workout("source-\($0)") }
        let window = TimeRange(start: now.addingTimeInterval(-86400), end: now)
        var payloadReads = 0
        for (lt1, lt2) in [(0, 0), (29, 170), (140, 140), (140, 241)] {
            let request = IntensityCalculationRequest.snapshot(workouts: rows, sources: rows,
                lt1: lt1, lt2: lt2, window: window) { workout in
                    payloadReads += 1
                    return workout.featuresData
                }
            XCTAssertFalse(request.hasValidThresholds)
            XCTAssertTrue(request.sources.isEmpty)
            XCTAssertEqual(request.window, window)
        }
        XCTAssertEqual(payloadReads, 0)
    }

    func testIntensitySnapshotUsesCurrentSourcesAfterThresholdChanges() throws {
        let start = now.addingTimeInterval(-100)
        let window = TimeRange(start: start, end: now)
        let canonical = workout("canonical")
        canonical.startTime = start
        canonical.duration = 100
        canonical.sourceBundleIdentifier = "com.garmin.connect.mobile"
        let linked = workout("alias")
        linked.startTime = start
        linked.duration = 100
        linked.isSuppressed = true
        linked.linkedSessionID = canonical.id
        let unrelated = workout("unrelated")

        func features(_ heartRate: Double) throws -> Data {
            var value = WorkoutFeatures()
            value.end = now
            value.heartRate = [TimedValue(start: start, end: now, value: heartRate)]
            return try JSONEncoder().encode(value)
        }
        canonical.featuresData = try features(150)
        linked.featuresData = try features(80)
        var reads: [String] = []
        func snapshot(_ lt1: Int, _ lt2: Int, _ window: TimeRange) -> IntensityCalculationRequest {
            IntensityCalculationRequest.snapshot(workouts: [canonical], sources: [canonical, unrelated, linked],
                lt1: lt1, lt2: lt2, window: window) { workout in
                    reads.append(workout.id)
                    return workout.featuresData
                }
        }

        let invalid = snapshot(0, 170, window)
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(invalid.sources.isEmpty)
        let valid = snapshot(140, 170, window)
        XCTAssertEqual(reads, ["alias", "canonical"])
        XCTAssertTrue(valid.hasValidThresholds)
        XCTAssertEqual(valid.sources.map(\.id), ["alias", "canonical"])
        XCTAssertTrue(valid.sources[1].isGarmin)
        XCTAssertEqual(try valid.calculate()?.moderateSeconds, 100)
        let completed = IntensityCalculationCompleted(request: valid, distribution: try valid.calculate())

        let invalidAgain = snapshot(140, 140, window)
        XCTAssertFalse(completed.matches(invalidAgain))
        XCTAssertEqual(reads.count, 2)
        canonical.featuresData = try features(180)
        let latest = snapshot(140, 170, window)
        XCTAssertFalse(completed.matches(latest))
        XCTAssertEqual(try latest.calculate()?.highSeconds, 100)
        let clippedWindow = TimeRange(start: now.addingTimeInterval(-50), end: now)
        let clipped = snapshot(140, 170, clippedWindow)
        XCTAssertFalse(completed.matches(clipped))
        XCTAssertEqual(try clipped.calculate()?.highSeconds, 50)
    }

    func testIntensityBackgroundRequestTracksSamplesThresholdsAndWindow() async throws {
        var features = WorkoutFeatures()
        features.heartRate = [TimedValue(start: now.addingTimeInterval(-100), end: now, value: 150)]
        let snapshot = IntensityInputSnapshot(id: "run", linkedID: nil, isGarmin: false,
            isSuppressed: false, isDeleted: false, start: now.addingTimeInterval(-100), duration: 100,
            featuresData: try JSONEncoder().encode(features))
        let window = TimeRange(start: now.addingTimeInterval(-100), end: now)
        let request = IntensityCalculationRequest(sources: [snapshot], lt1: 140, lt2: 170, window: window)
        let result = try await Task.detached { try request.calculate() }.value
        XCTAssertEqual(result?.moderateSeconds, 100)
        let completed = IntensityCalculationCompleted(request: request, distribution: result)
        XCTAssertTrue(completed.matches(request))

        let changedThreshold = IntensityCalculationRequest(sources: [snapshot], lt1: 120, lt2: 140, window: window)
        XCTAssertFalse(completed.matches(changedThreshold))
        let changedWindow = IntensityCalculationRequest(sources: [snapshot], lt1: 140, lt2: 170,
            window: TimeRange(start: now.addingTimeInterval(-50), end: now))
        XCTAssertFalse(completed.matches(changedWindow))
        let updated = IntensityInputSnapshot(id: snapshot.id, linkedID: nil, isGarmin: false,
            isSuppressed: false, isDeleted: false, start: snapshot.start, duration: snapshot.duration, featuresData: nil)
        XCTAssertFalse(completed.matches(IntensityCalculationRequest(sources: [updated], lt1: 140, lt2: 170, window: window)))
        let revised = try await Task.detached { try changedThreshold.calculate() }.value
        XCTAssertEqual(revised?.highSeconds, 100)
        let clipped = try await Task.detached { try changedWindow.calculate() }.value
        XCTAssertEqual(clipped?.moderateSeconds, 50)
    }

    func testIntensityBackgroundRequestHonorsCancellation() async throws {
        let request = IntensityCalculationRequest(sources: [], lt1: 140, lt2: 170,
            window: TimeRange(start: now.addingTimeInterval(-100), end: now))
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try request.calculate()
        }
        do {
            _ = try await worker.value
            XCTFail("A canceled calculation must not publish a result")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func workout(_ id: String, daysAgo: Double = 0) -> Workout {
        let start = now.addingTimeInterval(-daysAgo * 86400)
        return Workout(id: id, date: start, startTime: start, duration: 3600,
                       workoutType: "Run", tss: 50, calculationMethod: "duration", source: .healthKit)
    }

    private func estimate(_ id: String, points: Double, level: String, age: TimeInterval = 0,
                          method: String = "Running", region: Region = .quads) throws -> LoadEstimateRecord {
        let value = LoadEstimateValue(version: LoadModel.version, method: "Synthetic",
            inputCutoff: now, computedAt: now.addingTimeInterval(-age),
            cardio: CardioEstimate(points: points, level: level, coverage: 1, method: "HR", reasons: []),
            regions: [RegionalEstimate(region: region, level: level, exposure: points, unit: "minutes",
                                       method: method, coverage: 1, reasons: [])], coverage: 1, reasons: [])
        return LoadEstimateRecord(sessionID: id, version: value.version, inputCutoff: now,
                                  computedAt: value.computedAt, payloadData: try JSONEncoder().encode(value),
                                  inputData: Data())
    }

    func testLatestEstimatesExcludeOldAndArchivedActivitiesAndKeepMethodsSeparate() throws {
        let today = workout("today")
        let recent = workout("recent", daysAgo: 2)
        let otherMethod = workout("other-method", daysAgo: 3)
        let old = workout("old", daysAgo: 8)
        let suppressed = workout("suppressed")
        suppressed.isSuppressed = true
        let deleted = workout("deleted")
        deleted.isTombstoned = true
        let summary = V2TodaySummary(workouts: [today, recent, otherMethod, old, suppressed, deleted],
            estimates: [try estimate("today", points: 999, level: "High", age: 60),
                        try estimate("today", points: 7, level: "Low"),
                        try estimate("recent", points: 20, level: "Moderate"),
                        try estimate("other-method", points: 3, level: "Low", method: "Strength"),
                        try estimate("old", points: 999, level: "High"),
                        try estimate("suppressed", points: 999, level: "High"),
                        try estimate("deleted", points: 999, level: "High")], observations: [], now: now)
        XCTAssertEqual(summary.activeWorkouts.map(\.id), ["today", "recent", "other-method", "old"])
        XCTAssertEqual(summary.todayCount, 1)
        XCTAssertEqual(summary.cardio.map(\.points), [7])
        XCTAssertEqual(summary.regionalSummaries[.quads]?.map(\.method), ["Running", "Strength"])
        XCTAssertEqual(summary.regionalSummaries[.quads]?.map(\.level), ["Moderate", "Low"])
        XCTAssertEqual(summary.prioritizedRegions.first, .quads)
    }

    func testIndependentLatestSideReportsTakePriorityOverModelLoad() throws {
        let left = LocalObservation(regionRaw: "chest", sideRaw: "left", severity: 3, observedAt: now)
        let right = LocalObservation(regionRaw: "chest", sideRaw: "right", discomfortRaw: "none",
                                     severity: 0, observedAt: now)
        let olderLeft = LocalObservation(regionRaw: "chest", sideRaw: "left", discomfortRaw: "none",
                                         severity: 0, observedAt: now.addingTimeInterval(-60))
        let summary = V2TodaySummary(workouts: [workout("run")],
            estimates: [try estimate("run", points: 100, level: "High")],
            observations: [left, right, olderLeft], now: now)
        XCTAssertEqual(summary.reports[.chest]?.map(\.id), [left.id, right.id])
        XCTAssertEqual(summary.prioritizedRegions.first, .chest)
        XCTAssertEqual(summary.prioritizedRegions.dropFirst().first, .quads)
    }
}
