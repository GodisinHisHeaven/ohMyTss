#if DEBUG
import Foundation
import SwiftData

/// Synthetic history for isolated in-memory or temporary-disk regression tests.
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

    static func seedDashboard(in container: ModelContainer, includeMuscleRatings: Bool = true,
                              includeStrengthSets: Bool = true) throws {
        let context = ModelContext(container)
        let now = Date()
        if try context.fetchCount(FetchDescriptor<UserThresholds>()) == 0 {
            context.insert(UserThresholds(hasCompletedOnboarding: true))
        }
        let state = AppState(lastComputationDate: now)
        context.insert(state)
        for index in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -index, to: now.startOfDay)!
            context.insert(DayAggregate(date: date, totalTSS: index % 3 == 0 ? 48 : 0,
                ctl: 42 + Double(index % 5), atl: 38 + Double(index % 9), bodyBatteryScore: 72 + index % 12,
                avgHRV: 52, avgRHR: 54, hrvModifier: 4, rhrModifier: 2, sleepDuration: 7.6))
        }
        for (index, type) in ["Ride", "Run", "Strength", "Swim", "Walk", "Run", "Ride", "Run"].enumerated() {
            let start = now.addingTimeInterval(-Double(index) * 86400 - 3600)
            context.insert(Workout(id: "synthetic-dashboard-\(index)", date: start.startOfDay, startTime: start,
                duration: 2700, workoutType: type, tss: 48, calculationMethod: "duration", source: .manual))
        }
        if includeStrengthSets {
            context.insert(StrengthSetRecord(sessionID: "synthetic-dashboard-2", exerciseID: "bench_press", reps: 8, rir: 2))
        }
        for (region, side, rpe, age) in [
            ("quads", "left", 8, 0), ("quads", "right", 5, 0),
            ("hamstrings", "both", 7, 1), ("glutes", "both", 8, 1),
            ("calves", "both", 5, 0), ("chest", "both", 3, 1),
            ("core", "both", 4, 2)
        ] {
            guard includeMuscleRatings else { continue }
            context.insert(MuscleRPERecord(regionRaw: region, sideRaw: side, rpe: rpe,
                observedAt: now.addingTimeInterval(-Double(age) * 86400 - 1800)))
        }
        try context.save()
    }
}
#endif
