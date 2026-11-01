#if DEBUG
import Foundation
import SwiftData

/// Synthetic history for isolated in-memory or temporary-disk regression tests.
@MainActor
enum LaunchHistoryFixture {
    static func seed(in container: ModelContainer, includeEstimates: Bool = true,
                     sourceAlreadyKnown: Bool = false) throws {
        let context = ModelContext(container)
        let now = Date()
        context.insert(UserThresholds(hasCompletedOnboarding: true))
        for index in 0..<1000 {
            let start = now.addingTimeInterval(-Double(index + 1) * 86400)
            let workout = Workout(id: "synthetic-launch-\(index)", date: start.startOfDay,
                                  startTime: start, duration: 3600, workoutType: "Run", tss: 50,
                                  calculationMethod: "duration", source: .healthKit)
            // Synthetic IDs are not HealthKit UUIDs, so the sync fixture must
            // represent sources already identified by a previous sync.
            if sourceAlreadyKnown { workout.sourceBundleIdentifier = "com.example.synthetic-workouts" }
            workout.sessionGroupID = workout.id
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
        let intensityFixture = ProcessInfo.processInfo.arguments.contains("--v2-intensity-fixture")
        let deflectionFixture = ProcessInfo.processInfo.arguments.contains("--v2-deflection-fixture")
        if intensityFixture || deflectionFixture {
            UserDefaults.standard.set(0, forKey: "intensityLT1HeartRate")
            UserDefaults.standard.set(0, forKey: "intensityLT2HeartRate")
            UserDefaults.standard.set("", forKey: "intensityLT2Source")
        }
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
            let workout = Workout(id: "synthetic-dashboard-\(index)", date: start.startOfDay, startTime: start,
                duration: deflectionFixture && index == 0 ? 960 : 2700,
                workoutType: type, tss: 48, calculationMethod: "duration", source: .manual)
            if deflectionFixture && index == 0 {
                var features = WorkoutFeatures()
                features.end = start.addingTimeInterval(960)
                for minute in 0..<16 {
                    for sample in 0..<12 {
                        let begin = start.addingTimeInterval(Double(minute * 60 + sample * 5))
                        let end = begin.addingTimeInterval(5)
                        let hr = 100 + 4 * Double(min(minute, 8)) + 1.2 * Double(max(0, minute - 8))
                        features.heartRate.append(TimedValue(start: begin, end: end, value: hr))
                        features.power.append(TimedValue(start: begin, end: end, value: 100 + 15 * Double(minute)))
                    }
                }
                workout.features = features
            } else if intensityFixture && index == 0 {
                var features = WorkoutFeatures()
                features.heartRate = [
                    TimedValue(start: start, end: start.addingTimeInterval(72), value: 120),
                    TimedValue(start: start.addingTimeInterval(72), end: start.addingTimeInterval(92), value: 150),
                    TimedValue(start: start.addingTimeInterval(92), end: start.addingTimeInterval(100), value: 180)
                ]
                workout.features = features
            }
            context.insert(workout)
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
