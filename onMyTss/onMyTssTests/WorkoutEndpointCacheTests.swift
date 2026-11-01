import XCTest
@testable import onMyTss

@MainActor
final class WorkoutEndpointCacheTests: XCTestCase {
    func testCorrectedEndpointIsReevaluatedOnNextGroupingPass() {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", source: .healthKit, start: start)
        let strava = workout("strava", source: .strava, start: start)
        var healthFeatures = WorkoutFeatures()
        healthFeatures.end = start.addingTimeInterval(600)
        health.features = healthFeatures
        var stravaFeatures = WorkoutFeatures()
        stravaFeatures.end = start.addingTimeInterval(600)
        strava.features = stravaFeatures

        XCTAssertEqual(DataStore.matchingWorkoutGroups([health, strava]).map(\.count), [2])
        stravaFeatures.end = start.addingTimeInterval(900)
        strava.features = stravaFeatures
        XCTAssertEqual(DataStore.matchingWorkoutGroups([health, strava]).map(\.count), [1, 1])
        stravaFeatures.end = start.addingTimeInterval(600)
        strava.features = stravaFeatures
        XCTAssertEqual(DataStore.matchingWorkoutGroups([health, strava]).map(\.count), [2])
    }

    func testUnreadableFeaturesKeepExistingDurationFallback() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let health = workout("health", source: .healthKit, start: start)
        let strava = workout("strava", source: .strava, start: start)
        // A readable end with a corrupt unrelated sensor channel must still
        // follow the existing whole-payload decode failure semantics.
        health.featuresData = try JSONSerialization.data(withJSONObject: [
            "end": start.addingTimeInterval(900).timeIntervalSinceReferenceDate,
            "heartRate": "invalid legacy data"
        ])
        var valid = WorkoutFeatures()
        valid.end = start.addingTimeInterval(600)
        strava.features = valid
        XCTAssertNil(health.features.end)
        XCTAssertTrue(WorkoutAggregator.hasMatchingTiming(health, strava))
        XCTAssertEqual(DataStore.matchingWorkoutGroups([health, strava]).map(\.count), [2])
        XCTAssertEqual(DataStore.matchingWorkoutGroups([strava, health]).map(\.count), [2])
    }

    private func workout(_ id: String, source: WorkoutSource, start: Date) -> Workout {
        Workout(id: id, date: start.startOfDay, startTime: start, duration: 600,
                workoutType: "Running", tss: 10, calculationMethod: "duration", source: source)
    }
}
