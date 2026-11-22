import Foundation
import HealthKit

nonisolated struct RecoveryMeasurements: Sendable {
    let hrv: [Date: Double]
    let rhr: [Date: Double]
    let overnightHRV: [Date: Double]
    let sleep: [Date: SleepQuality]

    @concurrent
    static func collect(hrv: [HKQuantitySample], rhr: [HKQuantitySample], sleep: [HKCategorySample],
                        through end: Date, calendar: Calendar) async throws -> Self {
        let nights = SleepAnalyzer.nights(from: sleep.filter { $0.endDate <= end }, calendar: calendar)
        var dailyHRV: [Date: Mean] = [:], dailyRHR: [Date: Mean] = [:], overnight: [Date: Mean] = [:]
        for sample in hrv where sample.endDate <= end {
            try Task.checkCancellation()
            let value = sample.quantity.doubleValue(for: .secondUnit(with: .milli))
            guard value.isFinite, value > 0 else { continue }
            let day = calendar.startOfDay(for: sample.startDate)
            dailyHRV[day, default: Mean()].add(value)
            // A before-midnight SDNN sample can belong to the following wake date.
            let next = calendar.dateInterval(of: .day, for: day)!.end
            for wake in [day, next] {
                if nights[wake]?.asleepIntervals.contains(where: {
                    $0.start <= sample.startDate && sample.startDate < $0.end && sample.endDate <= $0.end
                }) == true {
                    overnight[wake, default: Mean()].add(value)
                    break
                }
            }
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        for sample in rhr where sample.endDate <= end {
            try Task.checkCancellation()
            let value = sample.quantity.doubleValue(for: unit)
            guard value.isFinite, value > 0 else { continue }
            dailyRHR[calendar.startOfDay(for: sample.startDate), default: Mean()].add(value)
        }
        try Task.checkCancellation()
        return Self(hrv: dailyHRV.mapValues(\.value), rhr: dailyRHR.mapValues(\.value),
                    overnightHRV: overnight.mapValues(\.value), sleep: nights)
    }

    private struct Mean {
        var value = 0.0
        var count = 0
        mutating func add(_ sample: Double) {
            count += 1
            value += (sample - value) / Double(count)
        }
    }
}
