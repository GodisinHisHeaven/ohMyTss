// Synthetic migration fixture. Compiled with the exact baseline model sources in a separate process.
import Foundation
import SwiftData

@main
struct LegacyStoreSeed {
    @MainActor
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "V2Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing to overwrite an existing store"])
        }
        let schema = Schema([DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self])
        let configuration = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: start)
        let aggregate = DayAggregate(date: day, totalTSS: 73, ctl: 21, atl: 33, tsb: -12,
                                     bodyBatteryScore: 44, workoutCount: 1, maxTSSWorkout: 73)
        let workout = Workout(id: "synthetic-legacy-migration", date: day, startTime: start, duration: 3600,
                              workoutType: "Ride", distance: 25_000, tss: 73, calculationMethod: "power",
                              source: .healthKit, healthKitUUID: "synthetic-legacy-migration",
                              averagePower: 180, normalizedPower: 190)
        let settings = UserThresholds(cyclingFTP: 240, maxHeartRate: 181, hasCompletedOnboarding: true)
        let state = AppState(lastHealthKitSyncDate: start, appInstallDate: start, lastOpenDate: start)
        let auth = StravaAuth(isConnected: false)
        context.insert(aggregate)
        context.insert(workout)
        context.insert(settings)
        context.insert(state)
        context.insert(auth)
        workout.dayAggregate = aggregate
        try context.save()
        print("Synthetic baseline store created; no personal records or credentials.")
    }
}
