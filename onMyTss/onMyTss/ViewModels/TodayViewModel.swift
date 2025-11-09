//
//  TodayViewModel.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

/// View model for the Today screen
/// Manages state and data fetching for the main Body Battery view
@MainActor
@Observable
class TodayViewModel {
    // Dependencies
    private let engine: BodyBatteryEngine
    private let dataStore: DataStore

    // UI State
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?

    // Data
    var todayScore: Int = Constants.defaultBodyBatteryScore
    var readinessLevel: ReadinessLevel = .medium
    var tssRecommendation: TSSRecommendation?
    var weekScores: [DayScore] = []
    var todayMetrics: DayMetrics?

    init(engine: BodyBatteryEngine, dataStore: DataStore) {
        self.engine = engine
        self.dataStore = dataStore
    }

    // MARK: - Data Loading

    /// Load all data for the Today screen
    func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            try await fetchTodayData()
            try await fetchWeekTrend()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh data (pull-to-refresh)
    func refresh() async {
        isRefreshing = true
        errorMessage = nil

        do {
            // Perform incremental HealthKit sync
            try await engine.incrementalUpdate()

            // Reload data
            try await fetchTodayData()
            try await fetchWeekTrend()
        } catch {
            errorMessage = error.localizedDescription
        }

        isRefreshing = false
    }

    // MARK: - Private Methods

    /// Fetch today's metrics
    private func fetchTodayData() async throws {
        let today = Date().startOfDay

        guard let aggregate = try dataStore.fetchDayAggregate(for: today) else {
            // No data for today yet - use default values
            todayScore = Constants.defaultBodyBatteryScore
            readinessLevel = .medium
            tssRecommendation = nil
            todayMetrics = nil
            return
        }

        // Update score and readiness
        todayScore = aggregate.bodyBatteryScore
        readinessLevel = BodyBatteryCalculator.getReadinessLevel(score: todayScore)

        // Get TSS recommendation
        tssRecommendation = GuidanceEngine.getRecommendedTSSRange(
            bodyBatteryScore: todayScore,
            tsb: aggregate.tsb,
            ctl: aggregate.ctl
        )

        // Store metrics for display
        todayMetrics = DayMetrics(
            date: aggregate.date,
            tss: aggregate.totalTSS,
            ctl: aggregate.ctl,
            atl: aggregate.atl,
            tsb: aggregate.tsb,
            rampRate: aggregate.rampRate,
            workoutCount: aggregate.workoutCount,
            avgHRV: aggregate.avgHRV,
            avgRHR: aggregate.avgRHR,
            hrvModifier: aggregate.hrvModifier,
            rhrModifier: aggregate.rhrModifier
        )
    }

    /// Fetch last 7 days of scores for trend view
    private func fetchWeekTrend() async throws {
        let aggregates = try dataStore.fetchRecentDayAggregates(days: 7)

        weekScores = aggregates.map { aggregate in
            DayScore(
                date: aggregate.date,
                score: aggregate.bodyBatteryScore
            )
        }
    }

    // MARK: - Computed Properties

    /// Formatted TSB string (e.g., "+12" or "-5")
    var tsbFormatted: String {
        guard let metrics = todayMetrics else { return "—" }

        if metrics.tsb >= 0 {
            return "+\(Int(metrics.tsb))"
        } else {
            return "\(Int(metrics.tsb))"
        }
    }

    /// Description text for the readiness level
    var readinessDescription: String {
        readinessLevel.description
    }

    /// Trend arrow and description
    var trendDescription: String? {
        guard weekScores.count >= 3 else { return nil }

        let scores = weekScores.map { $0.score }
        let trend = BodyBatteryCalculator.calculateTrend(scores: scores)

        return "\(trend.arrow) \(trend.description)"
    }

    /// Show empty state (no data)
    var showEmptyState: Bool {
        todayMetrics == nil && !isLoading
    }

    /// Today's TSS so far
    var todayTSS: String {
        guard let metrics = todayMetrics else { return "0" }
        return "\(Int(metrics.tss))"
    }

    /// CTL formatted
    var ctlFormatted: String {
        guard let metrics = todayMetrics else { return "—" }
        return "\(Int(metrics.ctl))"
    }

    /// ATL formatted
    var atlFormatted: String {
        guard let metrics = todayMetrics else { return "—" }
        return "\(Int(metrics.atl))"
    }

    /// Ramp rate status
    var rampRateStatus: String? {
        guard let rampRate = todayMetrics?.rampRate else { return nil }

        let status = LoadCalculator.getRampRateStatus(rampRate: rampRate)

        switch status {
        case .dangerous:
            return "⚠️ CTL increasing too fast"
        case .aggressive:
            return "⚡ CTL increasing rapidly"
        case .safe:
            return "✅ Good progression"
        case .detraining:
            return "📉 CTL decreasing"
        }
    }

    // MARK: - HRV/RHR Properties

    /// Formatted HRV value (e.g., "42 ms")
    var hrvFormatted: String? {
        guard let hrv = todayMetrics?.avgHRV else { return nil }
        return "\(Int(hrv)) ms"
    }

    /// Formatted RHR value (e.g., "52 bpm")
    var rhrFormatted: String? {
        guard let rhr = todayMetrics?.avgRHR else { return nil }
        return "\(Int(rhr)) bpm"
    }

    /// HRV modifier impact (e.g., "+12" or "-8")
    var hrvModifierFormatted: String? {
        guard let modifier = todayMetrics?.hrvModifier else { return nil }
        if modifier >= 0 {
            return "+\(Int(modifier))"
        } else {
            return "\(Int(modifier))"
        }
    }

    /// RHR modifier impact (e.g., "+5" or "-3")
    var rhrModifierFormatted: String? {
        guard let modifier = todayMetrics?.rhrModifier else { return nil }
        if modifier >= 0 {
            return "+\(Int(modifier))"
        } else {
            return "\(Int(modifier))"
        }
    }

    /// Combined modifier impact on Body Battery score
    var combinedModifierFormatted: String? {
        guard let hrvMod = todayMetrics?.hrvModifier,
              let rhrMod = todayMetrics?.rhrModifier else {
            return todayMetrics?.hrvModifier != nil ? hrvModifierFormatted :
                   todayMetrics?.rhrModifier != nil ? rhrModifierFormatted : nil
        }

        let combined = PhysiologyModifier.calculateCombinedModifier(
            hrvModifier: hrvMod,
            rhrModifier: rhrMod
        )

        if combined >= 0 {
            return "+\(Int(combined))"
        } else {
            return "\(Int(combined))"
        }
    }

    /// Whether we have any physiological data to display
    var hasPhysiologyData: Bool {
        todayMetrics?.avgHRV != nil || todayMetrics?.avgRHR != nil
    }

    /// Recovery status based on HRV/RHR modifiers
    var recoveryStatus: String? {
        guard let hrvMod = todayMetrics?.hrvModifier,
              let rhrMod = todayMetrics?.rhrModifier else {
            return nil
        }

        let combined = PhysiologyModifier.calculateCombinedModifier(
            hrvModifier: hrvMod,
            rhrModifier: rhrMod
        )

        if combined >= 15 {
            return "💪 Excellent recovery"
        } else if combined >= 8 {
            return "✅ Good recovery"
        } else if combined >= -7 {
            return "➖ Normal recovery"
        } else if combined >= -15 {
            return "⚠️ Poor recovery"
        } else {
            return "🚨 Very poor recovery - consider rest"
        }
    }
}

// MARK: - Day Metrics

struct DayMetrics {
    let date: Date
    let tss: Double
    let ctl: Double
    let atl: Double
    let tsb: Double
    let rampRate: Double?
    let workoutCount: Int

    // Phase 1: HRV/RHR physiological data
    let avgHRV: Double?
    let avgRHR: Double?
    let hrvModifier: Double?
    let rhrModifier: Double?
}
