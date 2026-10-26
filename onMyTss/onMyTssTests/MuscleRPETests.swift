import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class MuscleRPETests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ rpe: Int, side: String = "both", age: TimeInterval = 0) -> MuscleRPERecord {
        let record = MuscleRPERecord(regionRaw: "quads", sideRaw: side, rpe: rpe,
                                    observedAt: now.addingTimeInterval(-age))
        record.updatedAt = now
        return record
    }

    private func workout(age: TimeInterval = 3600, type: String = "Strength", duration: Double = 1800,
                         source: WorkoutSource = .manual) -> Workout {
        let start = now.addingTimeInterval(-age)
        return Workout(id: UUID().uuidString, date: start.startOfDay, startTime: start, duration: duration,
                       workoutType: type, tss: 0, calculationMethod: "unknown", source: source)
    }

    func testBandsKeepUnknownSeparateFromEasy() {
        XCTAssertNil(MuscleEffortGrade(rpe: 0))
        XCTAssertNil(MuscleEffortGrade(rpe: 11))
        for rpe in 1...10 {
            let grade = MuscleEffortGrade(rpe: rpe)
            XCTAssertEqual(grade, rpe <= 3 ? .easy : rpe <= 6 ? .moderate : rpe <= 8 ? .hard : .veryHard)
        }
        XCTAssertNil(MuscleRPESummary(records: [], now: now).reading(.quads, side: .left))
    }

    func testSevenDayWindowExcludesOldFutureAndInvalidRatings() {
        let values = [record(10, age: 7 * 86400), record(9, age: -60), record(0)]
        XCTAssertTrue(MuscleRPESummary(records: values, now: now).ratedRegions.isEmpty)
        let earliest = record(6)
        earliest.observedAt = Calendar.current.date(byAdding: .day, value: -6,
                                                    to: Calendar.current.startOfDay(for: now))!
        let boundary = MuscleRPESummary(records: [earliest], now: now)
        XCTAssertEqual(boundary.reading(.quads, side: .left)?.rpe, 6)
        earliest.observedAt = earliest.observedAt.addingTimeInterval(-1)
        XCTAssertTrue(MuscleRPESummary(records: [earliest], now: now).ratedRegions.isEmpty)
    }

    func testLatestRatingWinsWithoutAddingOrKeepingHistoricalPeak() {
        let current = record(2, age: 60)
        let summary = MuscleRPESummary(records: [current, record(10, age: 86400)], now: now)
        XCTAssertEqual(summary.reading(.quads, side: .right)?.rpe, 2)
        XCTAssertEqual(summary.reading(.quads, side: .right)?.observedAt, current.observedAt)
    }

    func testSingleSideAdjustmentPreservesOtherSide() {
        let summary = MuscleRPESummary(records: [record(8, age: 3600), record(3, side: "left")], now: now)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.rpe, 3)
        XCTAssertEqual(summary.reading(.quads, side: .right)?.rpe, 8)
        XCTAssertNil(MuscleRPESummary(records: [record(8, side: "unspecified")], now: now).reading(.quads, side: .left))
    }

    func testSetsUseRecordedRIRAndExerciseMusclesOnly() {
        let session = workout()
        let set = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 8, rir: 0)
        let summary = MuscleRPESummary(records: [], workouts: [session], sets: [set], now: now)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.rpe, 10)
        XCTAssertEqual(summary.reading(.glutes, side: .right)?.rpe, 10)
        XCTAssertNil(summary.reading(.chest, side: .left))
        set.rir = nil
        let withoutEffort = MuscleRPESummary(records: [], workouts: [session], sets: [set], now: now)
        XCTAssertEqual(withoutEffort.reading(.quads, side: .left)?.grade, .easy)
        XCTAssertEqual(withoutEffort.reading(.quads, side: .left)?.source, .history)
        set.rir = 8
        XCTAssertEqual(MuscleRPESummary(records: [], workouts: [session], sets: [set], now: now)
            .reading(.quads, side: .left)?.source, .history)
    }

    func testImportedWorkoutsFillMapWithoutRatingsSetsOrBackfill() {
        let run = workout(type: "Run", source: .healthKit)
        // Raw sensor data is intentionally undecodable: the dashboard needs
        // only saved summary fields, even before an estimate has been built.
        run.featuresData = Data("not decoded by the dashboard".utf8)
        let running = MuscleRPESummary(records: [], workouts: [run], now: now)
        XCTAssertEqual(Set(running.ratedRegions), Set([.quads, .hamstrings, .glutes, .calves, .core]))
        XCTAssertEqual(running.reading(.quads, side: .left)?.grade, .moderate)
        XCTAssertEqual(running.reading(.quads, side: .right)?.source, .history)
        XCTAssertEqual(running.reading(.quads, side: .left)?.observedAt, run.startTime)

        let ride = workout(type: "VirtualRide", duration: 600, source: .strava)
        let cycling = MuscleRPESummary(records: [], workouts: [ride], now: now)
        XCTAssertEqual(cycling.reading(.glutes, side: .left)?.grade, .easy)
        XCTAssertNil(cycling.reading(.core, side: .left))
        XCTAssertNil(cycling.reading(.chest, side: .left))

        let swim = workout(age: 7200, type: "Swim", duration: 4200, source: .healthKit)
        let swimming = MuscleRPESummary(records: [], workouts: [swim], now: now)
        XCTAssertEqual(Set(swimming.ratedRegions), Set([.shoulders, .back, .arms, .core]))
        XCTAssertEqual(swimming.reading(.shoulders, side: .right)?.grade, .hard)
    }

    func testWalkingHistoryAndUnknownActivityStaySeparate() {
        for type in ["Walk", "Hiking"] {
            let summary = MuscleRPESummary(records: [], workouts: [workout(type: type)], now: now)
            XCTAssertEqual(summary.reading(.calves, side: .left)?.grade, .moderate)
            XCTAssertNil(summary.reading(.shoulders, side: .left))
        }
        for type in ["Workout", "Strength"] {
            XCTAssertTrue(MuscleRPESummary(records: [], workouts: [workout(type: type)], now: now).ratedRegions.isEmpty)
        }
    }

    func testHistoryUsesLatestWorkoutAndKeepsSideAdjustment() {
        let latest = workout(type: "Ride", duration: 600)
        let oldHard = workout(age: 86400, type: "Run", duration: 7200)
        let adjustment = record(8, side: "left", age: 3600)
        for sessions in [[latest, oldHard], [oldHard, latest]] {
            let summary = MuscleRPESummary(records: [adjustment], workouts: sessions, now: now)
            XCTAssertEqual(summary.reading(.quads, side: .left)?.rpe, 8)
            XCTAssertEqual(summary.reading(.quads, side: .left)?.source, .reported)
            XCTAssertEqual(summary.reading(.quads, side: .right)?.grade, .easy)
            XCTAssertEqual(summary.reading(.quads, side: .right)?.observedAt, latest.startTime)
        }
    }

    func testHistoryHonorsLocalWindowAndExcludesInvalidOrDuplicateSources() {
        let old = workout(age: 8 * 86400, type: "Run")
        let deleted = workout(type: "Run"), suppressed = workout(type: "Ride")
        deleted.isTombstoned = true
        suppressed.isSuppressed = true
        let invalid = [old, deleted, suppressed, workout(age: -60, type: "Swim"),
                       workout(type: "Run", duration: 0), workout(type: "Ride", duration: .nan),
                       workout(type: "Walk", duration: -.infinity)]
        XCTAssertTrue(MuscleRPESummary(records: [], workouts: invalid, now: now).ratedRegions.isEmpty)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let edge = workout(type: "Run")
        edge.startTime = MuscleRPESummary.cutoff(for: now, calendar: calendar)
        XCTAssertFalse(MuscleRPESummary(records: [], workouts: [edge], now: now, calendar: calendar).ratedRegions.isEmpty)
        edge.startTime = edge.startTime.addingTimeInterval(-1)
        XCTAssertTrue(MuscleRPESummary(records: [], workouts: [edge], now: now, calendar: calendar).ratedRegions.isEmpty)
    }

    func testRecordedStrengthEffortWinsOverWorkoutStartingGrade() {
        let session = workout()
        let set = StrengthSetRecord(sessionID: session.id, exerciseID: "bench_press", reps: 8, effortRaw: "hard")
        let summary = MuscleRPESummary(records: [], workouts: [session], sets: [set], now: now)
        XCTAssertEqual(summary.reading(.chest, side: .left)?.grade, .hard)
        XCTAssertEqual(summary.reading(.chest, side: .left)?.source, .sets)
        XCTAssertNil(summary.reading(.quads, side: .left))
        set.reps = 0
        XCTAssertTrue(MuscleRPESummary(records: [], workouts: [session], sets: [set], now: now).ratedRegions.isEmpty)
    }

    func testOpeningHistoryMapDoesNotWriteRatingsOrEstimates() throws {
        let container = try ModelContainer(for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = workout(type: "Run", source: .healthKit)
        context.insert(session)
        try context.save()
        let summary = MuscleRPESummary(records: [], workouts: try context.fetch(FetchDescriptor<Workout>()), now: now)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.grade, .moderate)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MuscleRPERecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testExplicitRatingOverridesSameSessionReferenceWithoutChangingItsDate() {
        let session = workout()
        let set = StrengthSetRecord(sessionID: session.id, exerciseID: "squat", reps: 8, rir: 1)
        let adjustment = record(5, side: "left", age: 3600)
        let summary = MuscleRPESummary(records: [adjustment], workouts: [session], sets: [set], now: now)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.rpe, 5)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.source, .reported)
        XCTAssertEqual(summary.reading(.quads, side: .right)?.rpe, 9)
        XCTAssertEqual(summary.reading(.quads, side: .left)?.observedAt, session.startTime)
    }

    func testDeletedSuppressedAndOldWorkoutsCannotSupplyRatings() {
        let deleted = workout(), suppressed = workout(), old = workout(age: 8 * 86400)
        deleted.isTombstoned = true
        suppressed.isSuppressed = true
        let sessions = [deleted, suppressed, old]
        let sets = sessions.map { StrengthSetRecord(sessionID: $0.id, exerciseID: "squat", reps: 8, rir: 0) }
        XCTAssertTrue(MuscleRPESummary(records: [], workouts: sessions, sets: sets, now: now).ratedRegions.isEmpty)
    }

    func testEditingRatingDoesNotRecalculateHistoryOrOverwriteSymptoms() throws {
        let container = try ModelContainer(for: Schema(AppSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let symptom = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 3, observedAt: now)
        context.insert(symptom)
        let store = MuscleRPEStore(context: context, clock: { self.now })
        let first = try store.save(region: .quads, side: .left, rpe: 8, observedAt: now)
        let edited = try store.save(region: .quads, side: .left, rpe: 3, observedAt: now)
        XCTAssertEqual(first.id, edited.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MuscleRPERecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LoadEstimateRecord>()), 0)
        XCTAssertEqual(symptom.severity, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalObservation>()), 1)
        XCTAssertThrowsError(try store.save(region: .quads, side: .left, rpe: 0, observedAt: now))
        XCTAssertThrowsError(try store.save(region: .quads, side: .unspecified, rpe: 8, observedAt: now))
        XCTAssertThrowsError(try store.save(region: .quads, side: .left, rpe: 8, observedAt: now.addingTimeInterval(60)))
    }

    func testRatingSurvivesDiskReopenWithObservedDateAndSide() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("ratings.store"))
        func write() throws {
            let container = try ModelContainer(for: Schema(AppSchema.models), configurations: config)
            try MuscleRPEStore(context: ModelContext(container), clock: { self.now })
                .save(region: .hamstrings, side: .right, rpe: 7, observedAt: now.addingTimeInterval(-86400))
        }
        try write()
        let reopened = try ModelContainer(for: Schema(AppSchema.models), configurations: config)
        let records = try ModelContext(reopened).fetch(FetchDescriptor<MuscleRPERecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sideRaw, "right")
        XCTAssertEqual(records.first?.rpe, 7)
        XCTAssertEqual(records.first?.observedAt, now.addingTimeInterval(-86400))
    }
}
