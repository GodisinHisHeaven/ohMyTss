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
    private let workoutAggregator: WorkoutAggregator

    // Observable state
    var isProcessing: Bool = false
    var lastError: Error?
    var lastSyncDate: Date?

    init(healthKitManager: HealthKitManager, dataStore: DataStore, stravaAuthManager: StravaAuthManager) {
        self.healthKitManager = healthKitManager
        self.dataStore = dataStore
        self.workoutAggregator = WorkoutAggregator(
            healthKitManager: healthKitManager,
            stravaAuthManager: stravaAuthManager,
            dataStore: dataStore
        )
    }

    // Convenience init for backward compatibility (no Strava)
    convenience init(healthKitManager: HealthKitManager, dataStore: DataStore) {
        let stravaAuthManager = StravaAuthManager(dataStore: dataStore)
        self.init(healthKitManager: healthKitManager, dataStore: dataStore, stravaAuthManager: stravaAuthManager)
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

            // Step 3: Fetch workouts from both Strava and HealthKit
            let workouts = try await workoutAggregator.fetchWorkouts(from: startDate, to: endDate)

            // Step 4: Save workouts to database
            try dataStore.saveWorkouts(workouts)

            // Step 5: Process each workout and calculate daily TSS
            let dailyTSSMap = processDailyTSS(workouts: workouts)

            // Step 6: Calculate CTL/ATL/TSB time series
            try await computeAndSaveMetrics(dailyTSSMap: dailyTSSMap, startDate: startDate, endDate: endDate, workouts: workouts)

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
            // Get last sync date for incremental Strava fetch
            let appState = try dataStore.fetchAppState()
            let previousSyncDate = appState.lastHealthKitSyncDate ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!

            // Fetch workouts from both sources since last sync
            let workouts = try await workoutAggregator.fetchWorkouts(from: previousSyncDate, to: Date())

            guard !workouts.isEmpty else {
                // No new workouts
                return
            }

            // Save workouts to database
            try dataStore.saveWorkouts(workouts)

            // Process new workouts
            let dailyTSSMap = processDailyTSS(workouts: workouts)

            // Get the date range of new workouts
            let dates = dailyTSSMap.keys.sorted()
            guard let startDate = dates.first, let endDate = dates.last else {
                return
            }

            // Recompute metrics from the earliest affected date
            try await computeAndSaveMetrics(dailyTSSMap: dailyTSSMap, startDate: startDate, endDate: Date(), workouts: workouts)

            // Update sync date
            try dataStore.updateHealthKitSyncDate(Date(), anchor: nil)

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

        // Fetch all HRV and RHR samples in parallel
        async let hrvSamples = healthKitManager.fetchHRVSamples(from: startDate, to: endDate)
        async let rhrSamples = healthKitManager.fetchRestingHeartRateSamples(from: startDate, to: endDate)

        let (hrv, rhr) = try await (hrvSamples, rhrSamples)

        // Group samples by day
        var dailyHRVSamples: [Date: [HKQuantitySample]] = [:]
        var dailyRHRSamples: [Date: [HKQuantitySample]] = [:]

        for sample in hrv {
            let day = sample.startDate.startOfDay
            dailyHRVSamples[day, default: []].append(sample)
        }

        for sample in rhr {
            let day = sample.startDate.startOfDay
            dailyRHRSamples[day, default: []].append(sample)
        }

        // Calculate baseline from last 14 days of data (median of available values)
        let baselineHRV = PhysiologyModifier.calculateBaselineHRV(from: hrv)
        let baselineRHR = PhysiologyModifier.calculateBaselineRHR(from: rhr)

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

    /// Fetch and process sleep data for a date range
    private func processSleepData(from startDate: Date, to endDate: Date) async throws -> [Date: SleepQuality] {
        var sleepMap: [Date: SleepQuality] = [:]

        // Fetch all sleep samples for the range
        let sleepSamples = try await healthKitManager.fetchSleepSamples(from: startDate, to: endDate)

        // Group samples by day (sleep belongs to the day it ends, not starts)
        var dailySleepSamples: [Date: [HKCategorySample]] = [:]

        for sample in sleepSamples {
            // Assign sleep to the day it ends (morning day)
            let day = sample.endDate.startOfDay
            dailySleepSamples[day, default: []].append(sample)
        }

        // Process each day
        for (date, samples) in dailySleepSamples {
            if let quality = SleepAnalyzer.calculateSleepQuality(from: samples) {
                sleepMap[date] = quality
            }
        }

        return sleepMap
    }

    /// Process workouts and aggregate TSS by day
    /// TSS is already calculated by WorkoutAggregator, just aggregate by day
    private func processDailyTSS(workouts: [Workout]) -> [Date: Double] {
        var dailyTSSMap: [Date: Double] = [:]

        for workout in workouts {
            // Skip suppressed workouts (duplicates)
            guard !workout.isSuppressed else { continue }

            // Aggregate TSS by day
            dailyTSSMap[workout.date, default: 0] += workout.tss
        }

        return dailyTSSMap
    }

    /// Get recent resting heart rate for more accurate HR-based TSS calculations
    /// Note: TSS calculation is now handled by WorkoutAggregator
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
        endDate: Date,
        workouts: [Workout]
    ) async throws {
        // Group workouts by day for linking to aggregates
        var workoutsByDay: [Date: [Workout]] = [:]
        for workout in workouts where !workout.isSuppressed {
            workoutsByDay[workout.date, default: []].append(workout)
        }
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

        // Fetch and process data in parallel for better performance
        async let physiologyMap = processPhysiologyData(from: startDate, to: endDate)
        async let sleepMap = processSleepData(from: startDate, to: endDate)

        let (physiology, sleep) = try await (physiologyMap, sleepMap)

        // Collect all aggregates for batch save (better performance)
        var aggregatesToSave: [DayAggregate] = []

        // Process each day's aggregate
        for (index, date) in allDates.enumerated() {
            let tss = tssValues[index]
            let metrics = timeSeries[index]

            // Get physiological data for this day
            let physiologyData = physiology[date]
            let avgHRV = physiologyData?.hrv
            let avgRHR = physiologyData?.rhr
            let hrvModifier = physiologyData?.hrvMod
            let rhrModifier = physiologyData?.rhrMod

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

            // Get sleep data for this day
            let sleepData = sleep[date]
            let sleepDuration = sleepData?.durationHours
            let sleepQualityScore = sleepData?.qualityScore
            let deepSleepDuration = sleepData?.deepSleepHours

            // Calculate ramp rate if we have data from a week ago
            var rampRate: Double?
            if index >= 7 {
                let ctlOneWeekAgo = timeSeries[index - 7].ctl
                rampRate = LoadCalculator.calculateCTLRampRate(currentCTL: metrics.ctl, ctlOneWeekAgo: ctlOneWeekAgo)
            }

            // Get workout count for this day
            let workoutCount = dailyTSSMap[date] != nil ? 1 : 0 // Simplified for MVP

            // Get workouts for this day
            let dayWorkouts = workoutsByDay[date] ?? []
            let actualWorkoutCount = dayWorkouts.count
            let maxTSS = dayWorkouts.map { $0.tss }.max()

            // Try to fetch existing aggregate or create new one
            if let existing = try dataStore.fetchDayAggregate(for: date) {
                // Update existing
                existing.totalTSS = tss
                existing.ctl = metrics.ctl
                existing.atl = metrics.atl
                existing.tsb = metrics.tsb
                existing.bodyBatteryScore = bodyBatteryScore
                existing.rampRate = rampRate
                existing.workoutCount = actualWorkoutCount
                existing.maxTSSWorkout = maxTSS
                existing.avgHRV = avgHRV
                existing.avgRHR = avgRHR
                existing.hrvModifier = hrvModifier
                existing.rhrModifier = rhrModifier
                existing.illnessLikelihood = illnessLikelihood
                existing.sleepDuration = sleepDuration
                existing.sleepQualityScore = sleepQualityScore
                existing.deepSleepDuration = deepSleepDuration

                // Link workouts to aggregate
                for workout in dayWorkouts {
                    workout.dayAggregate = existing
                }

                aggregatesToSave.append(existing)
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
                    workoutCount: actualWorkoutCount,
                    maxTSSWorkout: maxTSS,
                    avgHRV: avgHRV,
                    avgRHR: avgRHR,
                    hrvModifier: hrvModifier,
                    rhrModifier: rhrModifier,
                    illnessLikelihood: illnessLikelihood,
                    sleepDuration: sleepDuration,
                    sleepQualityScore: sleepQualityScore,
                    deepSleepDuration: deepSleepDuration
                )

                // Link workouts to aggregate
                for workout in dayWorkouts {
                    workout.dayAggregate = aggregate
                }

                aggregatesToSave.append(aggregate)
            }
        }

        // Batch save all aggregates in one transaction (much faster)
        if !aggregatesToSave.isEmpty {
            try dataStore.saveDayAggregatesBatch(aggregatesToSave)
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
