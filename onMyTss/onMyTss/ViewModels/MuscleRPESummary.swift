import Foundation

/// A bounded seven-day view. It never reads estimates or decodes sensor history.
@MainActor
struct MuscleRPESummary {
    struct Reading {
        enum Source { case reported, sets }
        let rpe: Int
        let observedAt: Date
        let updatedAt: Date
        let source: Source
        var grade: MuscleEffortGrade { MuscleEffortGrade(rpe: rpe)! }
        var sourceLabel: String { source == .reported ? "You" : "From sets" }
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
        for set in sets {
            // Only the established near-failure RIR range is translated. Missing
            // effort, rep count, duration and heart rate do not invent an RPE.
            guard let workout = sessions[set.sessionID], let rir = set.rir, (0...4).contains(rir) else { continue }
            let regions = Set((ExerciseCatalog.exercise(id: set.exerciseID)?.regions ?? [])
                              + set.manualRegionsRaw.compactMap(Region.init(rawValue:)))
            let reading = Reading(rpe: 10 - rir, observedAt: workout.startTime,
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
                if current.source == .reported && incoming.source == .sets { return }
                if current.source == incoming.source {
                    if current.source == .sets && current.rpe >= incoming.rpe { return }
                    if current.source == .reported && current.updatedAt > incoming.updatedAt { return }
                }
            }
        }
        readings[key] = incoming
    }
}
