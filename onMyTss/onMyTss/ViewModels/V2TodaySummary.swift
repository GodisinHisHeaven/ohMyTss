import Foundation

/// Build once per Today render. Sorting regions must not repeatedly scan SwiftData
/// history or decode the same estimate for every comparison and row.
@MainActor
struct V2TodaySummary {
    let activeWorkouts: [Workout]
    let todayCount: Int
    let cardio: [CardioEstimate]
    let prioritizedRegions: [Region]
    let regionalSummaries: [Region: [RegionalEstimate]]
    let reports: [Region: [LocalObservation]]

    init(workouts: [Workout], estimates: [LoadEstimateRecord], observations: [LocalObservation],
         now: Date = Date(), calendar: Calendar = .current) {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let active = workouts.filter { !$0.isSuppressed && !$0.isTombstoned }
        let today = active.filter { calendar.isDate($0.startTime, inSameDayAs: now) }
        let recent = active.filter { $0.startTime >= cutoff }
        let neededIDs = Set((recent + today).map(\.id))
        var latest: [String: LoadEstimateRecord] = [:]
        for record in estimates where neededIDs.contains(record.sessionID) {
            if let previous = latest[record.sessionID], previous.computedAt >= record.computedAt { continue }
            latest[record.sessionID] = record
        }
        let values = latest.compactMapValues(\.value)
        let regional = Dictionary(grouping: recent.flatMap { values[$0.id]?.regions ?? [] }, by: \.region)
        var reportsByRegion: [Region: [LocalObservation]] = [:]
        // Query order is newest observed time first. Keep independent latest sides.
        for report in observations {
            guard let region = Region(rawValue: report.regionRaw),
                  !(reportsByRegion[region] ?? []).contains(where: { $0.sideRaw == report.sideRaw }) else { continue }
            reportsByRegion[region, default: []].append(report)
        }
        var reportRanks: [Region: Int] = [:]
        var loadRanks: [Region: Int] = [:]
        var summaries: [Region: [RegionalEstimate]] = [:]
        for region in Region.allCases {
            reportRanks[region] = (reportsByRegion[region] ?? []).filter { $0.observedAt >= cutoff }.map {
                if $0.discomfortRaw == "none" { return 0 }
                let symptoms = $0.weakness || $0.tightness || $0.limitedMovement
                return max($0.severity ?? 0, symptoms || $0.discomfortRaw != "soreness" ? 1 : 0)
            }.max() ?? 0
            let entries = regional[region] ?? []
            loadRanks[region] = entries.map { Self.levelOrder($0.level) }.max() ?? 0
            let groups = Dictionary(grouping: entries) { "\($0.method):\($0.unit)" }
            summaries[region] = groups.keys.sorted().compactMap { key in
                groups[key]?.max { Self.levelOrder($0.level) < Self.levelOrder($1.level) }
            }
        }
        activeWorkouts = active
        todayCount = today.count
        cardio = today.compactMap { values[$0.id]?.cardio }
        reports = reportsByRegion
        regionalSummaries = summaries
        prioritizedRegions = Region.allCases.sorted { left, right in
            let leftReport = reportRanks[left, default: 0], rightReport = reportRanks[right, default: 0]
            if leftReport != rightReport { return leftReport > rightReport }
            let leftLoad = loadRanks[left, default: 0], rightLoad = loadRanks[right, default: 0]
            if leftLoad != rightLoad { return leftLoad > rightLoad }
            return left.label < right.label
        }
    }

    private static func levelOrder(_ level: String) -> Int {
        switch level { case "High": return 3; case "Moderate": return 2; case "Low": return 1; default: return 0 }
    }
}
