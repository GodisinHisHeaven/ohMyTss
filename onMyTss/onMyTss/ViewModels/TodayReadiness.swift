import Foundation

/// Missing or yesterday's saved data must never become today's default score.
@MainActor
struct TodayReadiness {
    let day: DayAggregate?
    let score: Int?
    let updatedAt: Date?

    init(days: [DayAggregate], lastComputation: Date?, now: Date = Date(), calendar: Calendar = .current) {
        day = days.first { calendar.isDate($0.date, inSameDayAs: now) && $0.date <= now }
        score = day.flatMap(Self.validScore)
        updatedAt = lastComputation.flatMap {
            $0 <= now && calendar.isDate($0, inSameDayAs: now) ? $0 : nil
        }
    }

    static func validScore(_ day: DayAggregate) -> Int? {
        let training = [day.ctl, day.atl, day.totalTSS].contains { $0.isFinite && $0 > 0 }
        let hrv = day.avgHRV.map { $0.isFinite && $0 > 0 } == true
            && day.hrvModifier.map(\.isFinite) == true
        let rhr = day.avgRHR.map { $0.isFinite && $0 > 0 } == true
            && day.rhrModifier.map(\.isFinite) == true
        guard (0...100).contains(day.bodyBatteryScore), training || hrv || rhr else { return nil }
        return day.bodyBatteryScore
    }

    var basis: String {
        guard let day else { return "Sync to see today's estimate." }
        var parts: [String] = []
        if [day.ctl, day.atl, day.totalTSS].contains(where: { $0.isFinite && $0 > 0 }) { parts.append("training load") }
        if day.avgHRV.map({ $0.isFinite && $0 > 0 }) == true, day.hrvModifier?.isFinite == true { parts.append("HRV") }
        if day.avgRHR.map({ $0.isFinite && $0 > 0 }) == true, day.rhrModifier?.isFinite == true { parts.append("resting HR") }
        return parts.isEmpty ? "More recovery data is needed." : "Based on " + parts.joined(separator: " · ")
    }
}
