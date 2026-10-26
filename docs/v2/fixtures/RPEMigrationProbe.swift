import Foundation
import SwiftData

@main
struct RPEMigrationProbe {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #if RPE_LEGACY_SEED
        let day = DayAggregate(date: Calendar.current.startOfDay(for: date), totalTSS: 73, ctl: 30, atl: 40, bodyBatteryScore: 65)
        let workout = Workout(id: "synthetic-rpe-upgrade", date: day.date, startTime: date, duration: 3600,
                              workoutType: "Strength", tss: 73, calculationMethod: "hr", source: .manual)
        workout.dayAggregate = day
        context.insert(day)
        context.insert(workout)
        context.insert(UserThresholds(hasCompletedOnboarding: true))
        context.insert(LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 3, observedAt: date))
        context.insert(StrengthSetRecord(sessionID: workout.id, exerciseID: "squat", reps: 8, rir: 0))
        context.insert(LoadEstimateRecord(sessionID: workout.id, version: "preserved-v2",
            inputCutoff: date, computedAt: date, payloadData: Data("original-payload".utf8), inputData: Data("original-input".utf8)))
        try context.save()
        print("Seeded a synthetic Build 26 store.")
        #else
        let workouts = try context.fetch(FetchDescriptor<Workout>())
        let days = try context.fetch(FetchDescriptor<DayAggregate>())
        let reports = try context.fetch(FetchDescriptor<LocalObservation>())
        let sets = try context.fetch(FetchDescriptor<StrengthSetRecord>())
        let estimates = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        try require(workouts.count == 1 && workouts[0].tss == 73, "Workout and TSS retained")
        try require(days.count == 1 && days[0].bodyBatteryScore == 65, "Readiness retained")
        try require(workouts[0].dayAggregate?.date == days[0].date, "Relationship retained")
        try require(reports.count == 1 && reports[0].severity == 3 && reports[0].sideRaw == "left", "Symptoms retained")
        try require(sets.count == 1 && sets[0].rir == 0, "RIR zero retained")
        try require(estimates.count == 1 && estimates[0].inputData == Data("original-input".utf8)
                    && estimates[0].payloadData == Data("original-payload".utf8), "Snapshots retained byte for byte")
        try require(try context.fetchCount(FetchDescriptor<MuscleRPERecord>()) == 0, "Symptoms never become RPE")
        context.insert(MuscleRPERecord(regionRaw: "quads", sideRaw: "right", rpe: 8, observedAt: date))
        try context.save()
        try require(try context.fetch(FetchDescriptor<MuscleRPERecord>()).first?.rpe == 8, "RPE entity writable")
        try require(reports[0].severity == 3 && estimates[0].inputData == Data("original-input".utf8), "New rating preserves old data")
        print("PASS: Build 26 store migrated; workouts, readiness, symptoms, sets and estimate bytes retained; muscle RPE writes succeeded.")
        #endif
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "RPEMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
