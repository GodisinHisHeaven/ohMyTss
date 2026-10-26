import Foundation
import SwiftData

// Compiled as a separate macOS fixture tool, never included in the app target.
// Its only output is a new synthetic store supplied on the command line.
extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
}

@main
struct ReleaseDashboardSeed {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        try LaunchHistoryFixture.seed(in: container, includeEstimates: false)
        let context = ModelContext(container)
        let now = Date()
        for workout in try context.fetch(FetchDescriptor<Workout>()) {
            workout.startTime = workout.startTime.addingTimeInterval(-7 * 86400)
            workout.date = workout.startTime.startOfDay
            var features = WorkoutFeatures()
            features.end = workout.startTime.addingTimeInterval(workout.duration)
            features.heartRate = (0..<30).map {
                TimedValue(start: workout.startTime.addingTimeInterval(Double($0) * 120),
                           end: workout.startTime.addingTimeInterval(Double($0 + 1) * 120), value: 150)
            }
            workout.features = features
            let estimate = LoadModel.estimate(type: workout.workoutType, start: workout.startTime,
                duration: workout.duration, distance: nil, features: features, sets: [], tags: [],
                maxHeartRate: 170, now: now)
            context.insert(LoadEstimateRecord(sessionID: workout.id, version: estimate.version,
                inputCutoff: estimate.inputCutoff, computedAt: now.addingTimeInterval(-60),
                payloadData: try JSONEncoder().encode(estimate), inputData: Data("synthetic-original".utf8)))
        }
        context.insert(LocalObservation(regionRaw: "calves", sideRaw: "right", severity: 2, observedAt: now))
        try context.save()
        try LaunchHistoryFixture.seedDashboard(in: container)
        print("Created synthetic Release store: 1,008 workouts, 1,000 retained estimates, 30 days, 7 RPE ratings, 1 discomfort report.")
    }
}
