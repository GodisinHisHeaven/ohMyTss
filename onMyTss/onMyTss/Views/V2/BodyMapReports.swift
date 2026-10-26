import Foundation

/// Presentation of recorded symptoms only. Missing data never becomes a recovery grade.
struct BodyMapReports {
    enum Status {
        case unreported, noDiscomfort, discomfort
    }

    private var reports: [String: LocalObservation] = [:]
    private(set) var unspecifiedRegions: Set<Region> = []

    init(observations: [LocalObservation], now: Date = Date(), calendar: Calendar = .current) {
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let recent = observations.filter { $0.observedAt >= cutoff && $0.observedAt <= now }.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for report in recent {
            guard let region = Region(rawValue: report.regionRaw) else { continue }
            let sides: [BodySide]
            switch BodySide(rawValue: report.sideRaw) {
            case .left: sides = [.left]
            case .right: sides = [.right]
            case .both: sides = [.left, .right]
            default:
                unspecifiedRegions.insert(region)
                continue
            }
            // A newer report for one side overrides only that side of an older "both" report.
            for side in sides {
                let key = Self.key(region, side)
                if reports[key] == nil { reports[key] = report }
            }
        }
    }

    func report(_ region: Region, side: BodySide) -> LocalObservation? {
        reports[Self.key(region, side)]
    }

    func status(_ region: Region, side: BodySide) -> Status {
        guard let report = report(region, side: side) else { return .unreported }
        return report.discomfortRaw == "none" && !report.weakness && !report.tightness && !report.limitedMovement
            ? .noDiscomfort : .discomfort
    }

    private static func key(_ region: Region, _ side: BodySide) -> String {
        "\(region.rawValue).\(side.rawValue)"
    }
}
