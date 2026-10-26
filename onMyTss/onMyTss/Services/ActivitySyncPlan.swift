import Foundation

struct ActivitySyncPlan {
    let stravaStart: Date
    let reconcileStrava: Bool
    let refreshHealthKitSamples: Bool
    let recoveryStart: Date
    let healthKitRetryIDs: [String]

    init(now: Date, state: AppState, strava: StravaAuth?) {
        healthKitRetryIDs = state.pendingHealthKitWorkoutIDs
        let initial = now.addingDays(-Constants.initialSyncDays)
        reconcileStrava = strava?.lastReconciliationDate.map {
            now.timeIntervalSince($0) >= 7 * 86400
        } ?? true
        // Strava's `after` is an activity start time, not a modification cursor.
        // Retain overlap for edits/late uploads and a weekly 90-day reconciliation.
        let incremental = strava?.lastSyncDate.map { min($0, now).addingDays(-7) } ?? initial
        stravaStart = reconcileStrava ? min(initial, incremental) : incremental
        refreshHealthKitSamples = state.lastHealthKitSampleRefreshDate.map {
            now.timeIntervalSince($0) >= 6 * 3600
        } ?? true
        recoveryStart = state.lastRecoverySyncDate.map { min($0, now).addingDays(-3).startOfDay }
            ?? initial.startOfDay
    }
}

/// Value-only work; sample integration and encoding never occupy the UI actor.
nonisolated struct WorkoutImportCalculation: Sendable {
    let tss: Double
    let method: String
    let averagePower: Double?
    let normalizedPower: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let featuresData: Data

    init(features: WorkoutFeatures, start: Date, end: Date, duration: Double,
         cycling: Bool, ftp: Int?, maxHR: Int?, encodeFeatures: Bool = true) throws {
        let window = TimeRange(start: start, end: end)
        let power = SignalProcessing.intervals(samples: features.power, window: window,
                                              pauses: features.pauses, validRange: 0...2500)
        let heartRate = SignalProcessing.intervals(samples: features.heartRate, window: window,
                                                  pauses: features.pauses, validRange: 30...240)
        normalizedPower = SignalProcessing.normalizedPower(power)
        if cycling, let ftp, ftp > 0, let np = normalizedPower {
            tss = SignalProcessing.coveredSeconds(power) / 3600 * pow(np / Double(ftp), 2) * 100
            method = "power-time-v2"
        } else if !heartRate.isEmpty, let maxHR, maxHR > 60 {
            tss = TSSCalculator.legacyHeartRateTSS(intervals: heartRate, maxHeartRate: maxHR, restingHeartRate: 60)
            method = "hr-time-v2 (resting HR assumed 60)"
        } else {
            tss = max(0, duration) / 3600 * 60
            method = "duration estimate"
        }
        averagePower = SignalProcessing.weightedMean(power)
        averageHeartRate = SignalProcessing.weightedMean(heartRate)
        maxHeartRate = heartRate.map(\.value).max()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        featuresData = encodeFeatures ? try encoder.encode(features) : Data()
    }
}

nonisolated struct LegacyWorkoutInput: Equatable, Sendable {
    let id: String
    let source: String
    let start: Date
    let duration: Double
    let cycling: Bool
    let featuresData: Data?
    let normalizedPower: Double?
    let averageHeartRate: Double?
    let tss: Double
    let method: String

    @MainActor init(_ row: Workout) {
        id = row.id; source = row.source; start = row.startTime; duration = row.duration
        cycling = WorkoutAggregator.normalizeWorkoutType(row.workoutType) == "cycling"
        featuresData = row.featuresData; normalizedPower = row.normalizedPower
        averageHeartRate = row.averageHeartRate; tss = row.tss; method = row.calculationMethod
    }

    func calculate(ftp: Int?, maxHR: Int?) throws -> (tss: Double, method: String) {
        if source == "healthKit", let featuresData,
           let features = try? JSONDecoder().decode(WorkoutFeatures.self, from: featuresData) {
            let value = try WorkoutImportCalculation(features: features, start: start,
                end: features.end ?? start.addingTimeInterval(duration), duration: duration,
                cycling: cycling, ftp: ftp, maxHR: maxHR, encodeFeatures: false)
            return (value.tss, value.method)
        }
        guard source == "strava" else { return (tss, method) }
        if cycling, let power = normalizedPower, power >= 0, let ftp, ftp > 0 {
            return (duration / 3600 * pow(power / Double(ftp), 2) * 100, "power")
        }
        if let hr = averageHeartRate, hr.isFinite, let maxHR, maxHR > 60 {
            let ratio = min(1, max(0, (hr - 60) / Double(maxHR - 60)))
            return (duration / 60 * ratio * exp(1.92 * ratio) / (60 * 0.85 * exp(1.92 * 0.85)) * 100,
                    "hr summary estimate")
        }
        return (max(0, duration) / 3600 * 60, "duration estimate")
    }
}
