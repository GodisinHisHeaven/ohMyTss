#if DEBUG
import Foundation
import HealthKit

/// Only selected with the isolated UI-test store. The real engine and persistence
/// run unchanged while source latency leaves time to exercise tab navigation.
@MainActor
final class ActivitySyncUIFixture: HealthKitManager {
    override func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        try await Task.sleep(for: .seconds(3))
        let start = Date().addingTimeInterval(-3600)
        let rows = anchor == nil ? [HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(1800))] : []
        return (rows, [], HKQueryAnchor(fromValue: 1))
    }
    override func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] { [] }
    override func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        var features = WorkoutFeatures()
        features.heartRate = [.init(start: workout.startDate, end: workout.endDate, value: 150)]
        return features
    }
    override func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] { [] }
    override func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] { [] }
}
#endif
