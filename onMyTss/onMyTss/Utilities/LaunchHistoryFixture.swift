#if DEBUG
import Foundation
import SwiftData

/// Synthetic history for the isolated launch regression test. Never touches a disk store.
@MainActor
enum LaunchHistoryFixture {
    static func seed(in container: ModelContainer, includeEstimates: Bool = true) throws {
        let context = ModelContext(container)
        let now = Date()
        context.insert(UserThresholds(hasCompletedOnboarding: true))
        for index in 0..<1000 {
            let start = now.addingTimeInterval(-Double(index + 1) * 86400)
            let workout = Workout(id: "synthetic-launch-\(index)", date: start.startOfDay,
                                  startTime: start, duration: 3600, workoutType: "Run", tss: 50,
                                  calculationMethod: "duration", source: .healthKit)
            context.insert(workout)
            guard includeEstimates else { continue }
            let value = LoadModel.estimate(type: "Run", start: start, duration: 3600, distance: nil,
                                           features: WorkoutFeatures(), sets: [], tags: [],
                                           maxHeartRate: nil, now: now)
            context.insert(LoadEstimateRecord(sessionID: workout.id, version: value.version,
                                              inputCutoff: value.inputCutoff, computedAt: now,
                                              payloadData: try JSONEncoder().encode(value), inputData: Data()))
        }
        try context.save()
    }
}
#endif
