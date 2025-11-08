import Foundation
import HealthKit

/// Generates mock HealthKit data for testing
struct MockHealthKitData {

    /// Generates synthetic workout data
    static func generateWorkouts(days: Int, avgTSS: Double = 80) -> [(date: Date, tss: Double)] {
        var workouts: [(date: Date, tss: Double)] = []
        let calendar = Calendar.current

        for i in 0..<days {
            let date = calendar.date(byAdding: .day, value: -i, to: Date())!

            // Vary TSS with some randomness
            let variation = Double.random(in: -20...20)
            let tss = max(0, avgTSS + variation)

            workouts.append((date: date, tss: tss))
        }

        return workouts.reversed()
    }

    /// Generates synthetic HRV samples
    static func generateHRVSamples(nights: Int, baselineHRV: Double = 60) -> [Double] {
        var samples: [Double] = []

        for _ in 0..<nights {
            let variation = Double.random(in: -10...10)
            let hrv = max(20, baselineHRV + variation)
            samples.append(hrv)
        }

        return samples
    }

    /// Generates synthetic RHR samples
    static func generateRHRSamples(days: Int, baselineRHR: Double = 55) -> [Double] {
        var samples: [Double] = []

        for _ in 0..<days {
            let variation = Double.random(in: -5...5)
            let rhr = max(40, baselineRHR + variation)
            samples.append(rhr)
        }

        return samples
    }

    /// Generates a training block with progressive overload
    static func generateTrainingBlock(weeks: Int) -> [(date: Date, tss: Double)] {
        var workouts: [(date: Date, tss: Double)] = []
        let calendar = Calendar.current
        var baseTSS = 60.0

        for week in 0..<weeks {
            let isRecoveryWeek = (week + 1) % 4 == 0

            for day in 0..<7 {
                let date = calendar.date(byAdding: .day, value: -(weeks - week - 1) * 7 - (7 - day), to: Date())!

                var tss = 0.0
                if day < 5 {  // Weekdays
                    tss = isRecoveryWeek ? baseTSS * 0.5 : baseTSS + Double.random(in: -10...10)
                } else {  // Weekend
                    tss = isRecoveryWeek ? baseTSS * 0.6 : baseTSS * 1.5 + Double.random(in: -15...15)
                }

                workouts.append((date: date, tss: max(0, tss)))
            }

            // Increase base TSS each week (except recovery weeks)
            if !isRecoveryWeek {
                baseTSS += 5
            }
        }

        return workouts
    }

    /// Simulates illness: drop in HRV, spike in RHR
    static func simulateIllness(
        normalHRV: [Double],
        normalRHR: [Double],
        illnessDayIndex: Int
    ) -> (hrv: [Double], rhr: [Double]) {
        var hrv = normalHRV
        var rhr = normalRHR

        if illnessDayIndex < hrv.count {
            hrv[illnessDayIndex] *= 0.6  // 40% drop
        }

        if illnessDayIndex < rhr.count {
            rhr[illnessDayIndex] *= 1.2  // 20% increase
        }

        return (hrv, rhr)
    }
}
