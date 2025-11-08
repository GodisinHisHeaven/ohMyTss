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
    private func calculateWorkoutTSS(workout: HKWorkout, ftp: Int?) async throws -> Double {
        // For cycling workouts, try to get power data
        if workout.workoutActivityType == .cycling {
            let powerSamples = try await healthKitManager.fetchPowerSamples(for: workout)

            if !powerSamples.isEmpty, let ftp = ftp, ftp > 0 {
                return TSSCalculator.calculateTSS(
                    powerSamples: powerSamples,
                    ftp: ftp,
                    duration: workout.duration
                )
            }
        }

        // Fall back to heart rate-based TSS
        let heartRateSamples = try await healthKitManager.fetchHeartRateSamples(for: workout)

        if !heartRateSamples.isEmpty {
            return TSSCalculator.calculateTSSFromHeartRate(
                heartRateSamples: heartRateSamples,
                duration: workout.duration,
                maxHeartRate: nil,
                restingHeartRate: nil
            )
        }

        // Last resort: estimate from duration
        return TSSCalculator.estimateTSSFromDuration(workout: workout)
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

        // Save each day's aggregate
        for (index, date) in allDates.enumerated() {
            let tss = tssValues[index]
            let metrics = timeSeries[index]

            // Calculate Body Battery score
            let bodyBatteryScore = BodyBatteryCalculator.calculateScore(from: metrics.tsb)

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
                    maxTSSWorkout: tss > 0 ? tss : nil
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
