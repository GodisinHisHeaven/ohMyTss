import Foundation
import SwiftUI
import Observation
import TSSEngine

@Observable
class TodayViewModel {
    var todayScore: Int = 50
    var tsb: Double = 0
    var ctl: Double = 0
    var suggestedTSSRange: ClosedRange<Double> = 50...80
    var readinessZone: GuidanceEngine.ReadinessZone = .moderate
    var guidanceText: String = ""
    var last7Days: [Int] = []

    var isLoading: Bool = false
    var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Load from DataStore
        // For now, using mock data
        await MainActor.run {
            todayScore = 75
            tsb = 10
            ctl = 85
            readinessZone = GuidanceEngine.ReadinessZone(bodyBattery: todayScore)
            suggestedTSSRange = GuidanceEngine.suggestedTSSRange(
                bodyBattery: todayScore,
                ctl: ctl
            )
            guidanceText = readinessZone.description
            last7Days = [45, 52, 48, 63, 71, 68, 75]
        }
    }

    func refresh() async {
        await load()
    }

    var tsbFormatted: String {
        let sign = tsb >= 0 ? "+" : ""
        return "\(sign)\(Int(tsb))"
    }

    var zoneColor: Color {
        Color(hex: readinessZone.colorHex)
    }
}
