// Opens the actual store written by LegacyStoreSeed with current production models.
import Foundation
import SwiftData

@main
struct V2MigrationProbe {
    @MainActor
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try check(FileManager.default.fileExists(atPath: url.path), "Legacy store must exist")
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        try check(workouts.count == 1, "Legacy Workout count")
        let workout = workouts[0]
        try check(workout.id == "synthetic-legacy-migration", "Legacy source ID")
        try check(workout.tss == 73 && workout.calculationMethod == "power", "Legacy TSS and method")
        try check(workout.duration == 3600 && workout.distance == 25_000, "Legacy measured fields")
        try check(workout.averagePower == 180 && workout.normalizedPower == 190, "Legacy power fields")
        try check(workout.featuresData == nil && workout.userTags.isEmpty, "Missing v2 input remains missing")
        try check(!workout.isTombstoned && workout.linkedSessionID == nil, "Default v2 session state")
        let days = try context.fetch(FetchDescriptor<DayAggregate>())
        try check(days.count == 1 && days[0].totalTSS == 73, "Legacy daily history")
        try check(days[0].ctl == 21 && days[0].atl == 33 && days[0].tsb == -12, "Legacy CTL/ATL/TSB")
        try check(workout.dayAggregate?.date == days[0].date, "Legacy relationship")
        let settings = try context.fetch(FetchDescriptor<UserThresholds>())
        try check(settings.count == 1 && settings[0].cyclingFTP == 240, "Legacy cycling threshold")
        try check(settings[0].maxHeartRate == 181 && settings[0].hasCompletedOnboarding, "Legacy settings")
        let states = try context.fetch(FetchDescriptor<AppState>())
        try check(states.count == 1 && states[0].lastHealthKitSyncDate == workout.startTime, "Legacy sync metadata")
        try check(try context.fetch(FetchDescriptor<StravaAuth>()).count == 1, "Legacy connection metadata")
        let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 0,
                                           observedAt: workout.startTime, sessionID: workout.id)
        let set = StrengthSetRecord(sessionID: workout.id, exerciseID: "squat", reps: 8, weightKG: nil, rir: 0)
        context.insert(observation)
        context.insert(set)
        workout.userTags = ["synthetic-migration-check"]
        try context.save()
        try check(try context.fetch(FetchDescriptor<StrengthSetRecord>()).first?.rir == 0, "Can write v2 sets")
        try check(try context.fetch(FetchDescriptor<LocalObservation>()).first?.severity == 0, "Can write v2 feedback")
        try check(workout.tss == 73 && days[0].totalTSS == 73, "New user data does not rewrite old TSS")
        print("PASS: real SwiftData baseline-to-current migration preserved legacy rows, settings and relationships; v2 writes succeeded.")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "V2Migration", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
