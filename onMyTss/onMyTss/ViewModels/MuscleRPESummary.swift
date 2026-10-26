import Foundation

/// A bounded seven-day view. Workout summaries supply starting grades without
/// decoding sensor history, backfilling estimates, or writing perceived RPE.
@MainActor
struct MuscleRPESummary {
    struct Reading {
        enum Source: Int { case history, sets, reported }
        let rpe: Int
        let observedAt: Date
        let updatedAt: Date
        let source: Source
        var grade: MuscleEffortGrade { MuscleEffortGrade(rpe: rpe)! }
        var isReportedEffort: Bool { source != .history }
    }

    private var readings: [String: Reading] = [:]

    static func cutoff(for now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    init(records: [MuscleRPERecord], workouts: [Workout] = [], sets: [StrengthSetRecord] = [],
         now: Date = Date(), calendar: Calendar = .current) {
        let cutoff = Self.cutoff(for: now, calendar: calendar)
        let recent = workouts.filter {
            !$0.isTombstoned && !$0.isSuppressed && $0.startTime >= cutoff && $0.startTime <= now
        }
        let sessions = Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let setsBySession = Dictionary(grouping: sets, by: \.sessionID)
        for workout in recent {
            let inputs = (setsBySession[workout.id] ?? []).map {
                StrengthSetInput(exerciseID: $0.exerciseID, reps: $0.reps, weightKG: $0.weightKG,
                                 rir: $0.rir, effort: $0.effortRaw.flatMap(StrengthEffort.init(rawValue:)),
                                 manualRegions: $0.manualRegionsRaw.compactMap(Region.init(rawValue:)))
            }
            let load = LoadModel.estimate(type: workout.workoutType, start: workout.startTime,
                duration: workout.duration, distance: workout.distance, features: WorkoutFeatures(),
                sets: inputs, tags: workout.userTags, maxHeartRate: nil, now: now)
            for region in load.regions {
                let grade: MuscleEffortGrade
                switch region.level {
                case "Low": grade = .easy
                case "Moderate": grade = .moderate
                case "High": grade = .hard
                default: continue
                }
                let reading = Reading(rpe: grade.defaultRPE, observedAt: workout.startTime,
                                      updatedAt: workout.startTime, source: .history)
                apply(reading, region: region.region, side: .left)
                apply(reading, region: region.region, side: .right)
            }
            if WorkoutCategory(type: workout.workoutType) == .walking,
               workout.duration.isFinite, workout.duration > 0 {
                // The same coarse duration bands used for endurance exposure;
                // neither pace nor individual perceived effort is fabricated.
                let minutes = min(workout.duration, max(0, now.timeIntervalSince(workout.startTime))) / 60
                guard minutes > 0 else { continue }
                let grade: MuscleEffortGrade = minutes < 20 ? .easy : minutes < 60 ? .moderate : .hard
                let reading = Reading(rpe: grade.defaultRPE, observedAt: workout.startTime,
                                      updatedAt: workout.startTime, source: .history)
                for region in [Region.quads, .hamstrings, .glutes, .calves] {
                    apply(reading, region: region, side: .left)
                    apply(reading, region: region, side: .right)
                }
            }
        }
        for set in sets {
            guard let workout = sessions[set.sessionID], (1...500).contains(set.reps),
                  set.weightKG == nil || (set.weightKG!.isFinite && (0...1500).contains(set.weightKG!)),
                  set.rir == nil || (0...10).contains(set.rir!) else { continue }
            let rpe: Int
            if let rir = set.rir, (0...4).contains(rir) {
                rpe = 10 - rir
            } else if let effort = set.effortRaw.flatMap(StrengthEffort.init(rawValue:)) {
                switch effort {
                case .easy: rpe = MuscleEffortGrade.easy.defaultRPE
                case .moderate: rpe = MuscleEffortGrade.moderate.defaultRPE
                case .hard: rpe = MuscleEffortGrade.hard.defaultRPE
                }
            } else { continue }
            let regions = Set((ExerciseCatalog.exercise(id: set.exerciseID)?.regions ?? [])
                              + set.manualRegionsRaw.compactMap(Region.init(rawValue:)))
            let reading = Reading(rpe: rpe, observedAt: workout.startTime,
                                  updatedAt: set.updatedAt, source: .sets)
            for region in regions {
                apply(reading, region: region, side: .left)
                apply(reading, region: region, side: .right)
            }
        }
        for record in records {
            guard record.observedAt >= cutoff, record.observedAt <= now,
                  MuscleEffortGrade(rpe: record.rpe) != nil,
                  let region = Region(rawValue: record.regionRaw) else { continue }
            let reading = Reading(rpe: record.rpe, observedAt: record.observedAt,
                                  updatedAt: record.updatedAt, source: .reported)
            switch BodySide(rawValue: record.sideRaw) {
            case .left: apply(reading, region: region, side: .left)
            case .right: apply(reading, region: region, side: .right)
            case .both:
                apply(reading, region: region, side: .left)
                apply(reading, region: region, side: .right)
            default: break
            }
        }
    }

    func reading(_ region: Region, side: BodySide) -> Reading? {
        readings["\(region.rawValue).\(side.rawValue)"]
    }

    var ratedRegions: [Region] {
        Region.allCases.filter { reading($0, side: .left) != nil || reading($0, side: .right) != nil }
    }

    func latest(_ region: Region) -> Reading? {
        [reading(region, side: .left), reading(region, side: .right)].compactMap { $0 }
            .max { $0.observedAt == $1.observedAt ? $0.rpe < $1.rpe : $0.observedAt < $1.observedAt }
    }

    private mutating func apply(_ incoming: Reading, region: Region, side: BodySide) {
        let key = "\(region.rawValue).\(side.rawValue)"
        if let current = readings[key] {
            if current.observedAt > incoming.observedAt { return }
            if current.observedAt == incoming.observedAt {
                if current.source.rawValue > incoming.source.rawValue { return }
                if current.source == incoming.source {
                    if current.source != .reported && current.rpe >= incoming.rpe { return }
                    if current.source == .reported && current.updatedAt > incoming.updatedAt { return }
                }
            }
        }
        readings[key] = incoming
    }
}
