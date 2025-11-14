//
//  BodyBatteryEngine.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit
import SwiftData

/// Main orchestration engine for Body Battery calculations
/// Coordinates HealthKit data fetching, TSS calculation, load metric computation, and persistence
@MainActor
@Observable
class BodyBatteryEngine {
    private let healthKitManager: HealthKitManager
    private let dataStore: DataStore

    // Observable state
    var isProcessing: Bool = false
    var lastError: Error?
    var lastSyncDate: Date?

    init(healthKitManager: HealthKitManager, dataStore: DataStore) {
        self.healthKitManager = healthKitManager
        self.dataStore = dataStore
    }

    // MARK: - Main Computation

    /// Recompute all Body Battery metrics from historical HealthKit data
    /// This is the main function called when:
    /// - User completes onboarding
    /// - User requests a manual refresh
    /// - App launches after being inactive
    func recomputeAll() async throws {
        guard !isProcessing else {
            throw EngineError.alreadyProcessing
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            // Step 1: Fetch user thresholds
            let thresholds = try dataStore.fetchUserThresholds()

            guard thresholds.hasCompletedOnboarding else {
                throw EngineError.onboardingIncomplete
            }

            // Step 2: Determine date range for computation
            let endDate = Date()
            let startDate = Calendar.current.date(byAdding: .day, value: -Constants.initialSyncDays, to: endDate) ?? endDate

            // Step 3: Fetch workouts from HealthKit
            let workouts = try await healthKitManager.fetchWorkouts(from: startDate, to: endDate)

            // Step 4: Process each workout and calculate daily TSS
            let dailyTSSMap = try await processDailyTSS(workouts: workouts, ftp: thresholds.cyclingFTP)

            // Step 5: Calculate CTL/ATL/TSB time series
            try await computeAndSaveMetrics(dailyTSSMap: dailyTSSMap, startDate: startDate, endDate: endDate)

            // Step 6: Update sync state
            try dataStore.updateHealthKitSyncDate(Date(), anchor: nil)
            lastSyncDate = Date()
            lastError = nil

        } catch {
            lastError = error
            throw error
        }
    }

    /// Incremental update using HealthKit anchored query
    /// Called periodically to sync new workouts without reprocessing everything
    func incrementalUpdate() async throws {
        guard !isProcessing else {
            throw EngineError.alreadyProcessing
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            // Fetch app state to get last anchor
            let appState = try dataStore.fetchAppState()
            let anchor = appState.healthKitAnchor.flatMap { healthKitManager.decodeAnchor(from: $0) }

            // Fetch new workouts since last sync
            let result = try await healthKitManager.fetchWorkouts(anchor: anchor)

            guard !result.workouts.isEmpty else {
                // No new workouts
                return
            }

            // Get user thresholds
            let thresholds = try dataStore.fetchUserThresholds()

            // Process new workouts
            let dailyTSSMap = try await processDailyTSS(workouts: result.workouts, ftp: thresholds.cyclingFTP)

            // Get the date range of new workouts
            let dates = dailyTSSMap.keys.sorted()
            guard let startDate = dates.first, let endDate = dates.last else {
                return
            }

            // Recompute metrics from the earliest affected date
            try await computeAndSaveMetrics(dailyTSSMap: dailyTSSMap, startDate: startDate, endDate: Date())

            // Save new anchor
            if let anchorData = healthKitManager.encodeAnchor(result.newAnchor) {
                try dataStore.updateHealthKitSyncDate(Date(), anchor: anchorData)
            }

            lastSyncDate = Date()
            lastError = nil

        } catch {
            lastError = error
            throw error
        }
    }

    // MARK: - Private Helper Methods

    /// Fetch and process HRV/RHR data for a date range
    private func processPhysiologyData(from startDate: Date, to endDate: Date) async throws -> [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)] {
        var physiologyMap: [Date: (hrv: Double?, rhr: Double?, hrvMod: Double?, rhrMod: Double?)] = [:]

        // Fetch all HRV and RHR samples for the range
        let hrvSamples = try await healthKitManager.fetchHRVSamples(from: startDate, to: endDate)
        let rhrSamples = try await healthKitManager.fetchRestingHeartRateSamples(from: startDate, to: endDate)

        // Group samples by day
        var dailyHRVSamples: [Date: [HKQuantitySample]] = [:]
        var dailyRHRSamples: [Date: [HKQuantitySample]] = [:]

        for sample in hrvSamples {
            let day = sample.startDate.startOfDay
            dailyHRVSamples[day, default: []].append(sample)
        }

        for sample in rhrSamples {
            let day = sample.startDate.startOfDay
            dailyRHRSamples[day, default: []].append(sample)
        }

        // Calculate baseline from last 14 days of data (median of available values)
        let baselineHRV = PhysiologyModifier.calculateBaselineHRV(from: hrvSamples)
        let baselineRHR = PhysiologyModifier.calculateBaselineRHR(from: rhrSamples)

        // Process each day
        let calendar = Calendar.current
        var currentDate = startDate.startOfDay

        while currentDate <= endDate.startOfDay {
            // Calculate daily averages
            let dailyHRV = dailyHRVSamples[currentDate].flatMap {
                PhysiologyModifier.calculateDailyAverageHRV(from: $0)
            }
            let dailyRHR = dailyRHRSamples[currentDate].flatMap {
                PhysiologyModifier.calculateDailyAverageRHR(from: $0)
            }

            // Calculate modifiers if we have baselines
            var hrvModifier: Double?
            var rhrModifier: Double?

            if let hrv = dailyHRV, let baseline = baselineHRV {
                hrvModifier = PhysiologyModifier.calculateHRVModifier(currentHRV: hrv, baselineHRV: baseline)
            }

            if let rhr = dailyRHR, let baseline = baselineRHR {
                rhrModifier = PhysiologyModifier.calculateRHRModifier(currentRHR: rhr, baselineRHR: baseline)
            }

            physiologyMap[currentDate] = (dailyHRV, dailyRHR, hrvModifier, rhrModifier)
            currentDate = currentDate.addingDays(1)
        }

        return physiologyMap
    }

    /// Process workouts and aggregate TSS by day
    private func processDailyTSS(workouts: [HKWorkout], ftp: Int?) async throws -> [Date: Double] {
        var dailyTSSMap: [Date: Double] = [:]

        for workout in workouts {
            // Calculate TSS for this workout
            let tss = try await calculateWorkoutTSS(workout: workout, ftp: ftp)

            // Aggregate by day
            let day = workout.startDate.startOfDay
            dailyTSSMap[day, default: 0] += tss
        }

        return dailyTSSMap
    }

    /// Calculate TSS for a single workout
    /// Supports multiple sport types with power-based and heart rate-based calculations
    private func calculateWorkoutTSS(workout: HKWorkout, ftp: Int?) async throws -> Double {
        let workoutType = workout.workoutActivityType
        let duration = workout.duration

        // Strategy 1: Power-based TSS (cycling with power meter)
        if workoutType == .cycling {
            let powerSamples = try await healthKitManager.fetchPowerSamples(for: workout)

            if !powerSamples.isEmpty, let ftp = ftp, ftp > 0 {
                return TSSCalculator.calculateTSS(
                    powerSamples: powerSamples,
                    ftp: ftp,
                    duration: duration
                )
            }
        }

        // Strategy 2: Heart rate-based TSS (all workout types)
        // This is the primary method for running, swimming, and cycling without power
        let heartRateSamples = try await healthKitManager.fetchHeartRateSamples(for: workout)

        // Require minimum HR sample density for reliable TSS calculation
        // We need at least 1 sample per 5 minutes, or 10 samples minimum (whichever is higher)
        let durationMinutes = duration / 60.0
        let minRequiredSamples = max(10, Int(durationMinutes / 5.0))

        if heartRateSamples.count >= minRequiredSamples {
            // Get recent RHR data to improve HR-based TSS accuracy
            let recentRHR = try? await getRecentRestingHeartRate()

            // Use sport-specific TSS calculation for better accuracy
            return TSSCalculator.calculateTSSFromHeartRateWithType(
                heartRateSamples: heartRateSamples,
                duration: duration,
                workoutType: workoutType,
                maxHeartRate: nil, // Will use age-based estimation
                restingHeartRate: recentRHR
            )
        }

        // Strategy 3: Duration-based estimation (last resort when no HR data)
        return TSSCalculator.estimateTSSFromDuration(workout: workout)
    }

    /// Get recent resting heart rate for more accurate HR-based TSS calculations
    private func getRecentRestingHeartRate() async throws -> Int? {
        let today = Date().startOfDay

        // Try today's RHR first
        if let aggregate = try dataStore.fetchDayAggregate(for: today),
           let rhr = aggregate.avgRHR {
            return Int(rhr)
        }

        // Fall back to recent week average
        let recentAggregates = try dataStore.fetchRecentDayAggregates(days: 7)
        let rhrValues = recentAggregates.compactMap { $0.avgRHR }

        guard !rhrValues.isEmpty else { return nil }

        let avgRHR = rhrValues.reduce(0, +) / Double(rhrValues.count)
        return Int(avgRHR)
    }

    /// Compute CTL/ATL/TSB time series and save to database
    private func computeAndSaveMetrics(
        dailyTSSMap: [Date: Double],
        startDate: Date,
        endDate: Date
    ) async throws {
        // Generate array of all dates in range
        let calendar = Calendar.current
        var currentDate = startDate.startOfDay
        var allDates: [Date] = []

        while currentDate <= endDate.startOfDay {
            allDates.append(currentDate)
            currentDate = currentDate.addingDays(1)
        }

        // Build TSS array for all days (0 for days with no workouts)
        let tssValues = allDates.map { date -> Double in
            dailyTSSMap[date] ?? 0
        }

        // Calculate time series
        let timeSeries = LoadCalculator.calculateTimeSeries(tssValues: tssValues)

        // Fetch and process physiological data (HRV/RHR)
        let physiologyMap = try await processPhysiologyData(from: startDate, to: endDate)

        // Save each day's aggregate
        for (index, date) in allDates.enumerated() {
            let tss = tssValues[index]
            let metrics = timeSeries[index]

            // Get physiological data for this day
            let physiology = physiologyMap[date]
            let avgHRV = physiology?.hrv
            let avgRHR = physiology?.rhr
            let hrvModifier = physiology?.hrvMod
            let rhrModifier = physiology?.rhrMod

            // Calculate Body Battery score with HRV/RHR modifiers
            let bodyBatteryScore = BodyBatteryCalculator.calculateScoreWithModifiers(
                tsb: metrics.tsb,
                hrvModifier: hrvModifier,
                rhrModifier: rhrModifier
            )

            // Detect potential illness from HRV/RHR signals
            let illnessLikelihood = PhysiologyModifier.detectIllness(
                hrvModifier: hrvModifier,
                rhrModifier: rhrModifier
            )

            // Calculate ramp rate if we have data from a week ago
            var rampRate: Double?
            if index >= 7 {
                let ctlOneWeekAgo = timeSeries[index - 7].ctl
                rampRate = LoadCalculator.calculateCTLRampRate(currentCTL: metrics.ctl, ctlOneWeekAgo: ctlOneWeekAgo)
            }

            // Get workout count for this day
            let workoutCount = dailyTSSMap[date] != nil ? 1 : 0 // Simplified for MVP

            // Try to fetch existing aggregate or create new one
            if let existing = try dataStore.fetchDayAggregate(for: date) {
                // Update existing
                existing.totalTSS = tss
                existing.ctl = metrics.ctl
                existing.atl = metrics.atl
                existing.tsb = metrics.tsb
                existing.bodyBatteryScore = bodyBatteryScore
                existing.rampRate = rampRate
                existing.workoutCount = workoutCount
                existing.maxTSSWorkout = tss > 0 ? tss : nil
                existing.avgHRV = avgHRV
                existing.avgRHR = avgRHR
                existing.hrvModifier = hrvModifier
                existing.rhrModifier = rhrModifier
                existing.illnessLikelihood = illnessLikelihood

                try dataStore.saveDayAggregate(existing)
            } else {
                // Create new aggregate
                let aggregate = DayAggregate(
                    date: date,
                    totalTSS: tss,
                    ctl: metrics.ctl,
                    atl: metrics.atl,
                    tsb: metrics.tsb,
                    bodyBatteryScore: bodyBatteryScore,
                    rampRate: rampRate,
                    workoutCount: workoutCount,
                    maxTSSWorkout: tss > 0 ? tss : nil,
                    avgHRV: avgHRV,
                    avgRHR: avgRHR,
                    hrvModifier: hrvModifier,
                    rhrModifier: rhrModifier,
                    illnessLikelihood: illnessLikelihood
                )

                try dataStore.saveDayAggregate(aggregate)
            }
        }
    }

    // MARK: - Utility Methods

    /// Get today's Body Battery score
    func getTodayScore() throws -> Int {
        let today = Date().startOfDay
        if let aggregate = try dataStore.fetchDayAggregate(for: today) {
            return aggregate.bodyBatteryScore
        }
        return Constants.defaultBodyBatteryScore
    }

    /// Get recent scores for trend analysis
    func getRecentScores(days: Int = 7) throws -> [Int] {
        let aggregates = try dataStore.fetchRecentDayAggregates(days: days)
        return aggregates.map { $0.bodyBatteryScore }
    }

    /// Get training recommendations for today
    func getTodayRecommendations() throws -> [String] {
        guard let today = try dataStore.fetchDayAggregate(for: Date().startOfDay) else {
            return ["Complete your first workout to get recommendations."]
        }

        let recentAggregates = try dataStore.fetchRecentDayAggregates(days: 14)
        let recentTSS = recentAggregates.map { $0.totalTSS }

        return GuidanceEngine.getTrainingSuggestions(
            bodyBatteryScore: today.bodyBatteryScore,
            tsb: today.tsb,
            ctl: today.ctl,
            atl: today.atl,
            rampRate: today.rampRate,
            recentTSS: recentTSS
        )
    }

    /// Get recommended TSS range for today
    func getTodayTSSRecommendation() throws -> TSSRecommendation? {
        guard let today = try dataStore.fetchDayAggregate(for: Date().startOfDay) else {
            return nil
        }

        return GuidanceEngine.getRecommendedTSSRange(
            bodyBatteryScore: today.bodyBatteryScore,
            tsb: today.tsb,
            ctl: today.ctl
        )
    }
}

// MARK: - Engine Errors

enum EngineError: LocalizedError {
    case alreadyProcessing
    case onboardingIncomplete
    case noData

    var errorDescription: String? {
        switch self {
        case .alreadyProcessing:
            return "A computation is already in progress."
        case .onboardingIncomplete:
            return "Please complete onboarding before using Body Battery."
        case .noData:
            return "No workout data available. Start tracking workouts in the Health app."
        }
    }
}
