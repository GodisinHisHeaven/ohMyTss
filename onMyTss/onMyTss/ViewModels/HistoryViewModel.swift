//
//  HistoryViewModel.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

/// View model for the History screen
@MainActor
@Observable
class HistoryViewModel {
    // Dependencies
    private let dataStore: DataStore

    // UI State
    var isLoading: Bool = false
    var errorMessage: String?

    // Data
    var historyItems: [HistoryItem] = []
    var selectedDays: Int = 30 // Default to 30 days to show charts
    var chartData: [ChartDataPoint] = []

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Data Loading

    /// Load history data
    func loadHistory() async {
        isLoading = true
        errorMessage = nil

        do {
            let now = Date()
            let cutoff = now.startOfDay.addingDays(1 - selectedDays)
            let rows = try dataStore.fetchDayAggregates(from: TrainingReadiness.historyStart(for: cutoff, calendar: .current), to: now)
            let history = DayAggregate.byLocalDay(rows, calendar: .current)
            let aggregates = rows.filter { $0.date >= cutoff }

            historyItems = aggregates.map { aggregate in
                let score = TrainingReadiness.assess(aggregate, history: history, asOf: now, calendar: .current).score
                return HistoryItem(
                    date: aggregate.date,
                    score: score,
                    tss: aggregate.totalTSS,
                    ctl: aggregate.ctl,
                    atl: aggregate.atl,
                    tsb: aggregate.tsb,
                    workoutCount: aggregate.workoutCount,
                    readinessLevel: score.map(BodyBatteryCalculator.getReadinessLevel)
                )
            }.reversed() // Most recent first

            // Prepare chart data (chronological order for charts)
            chartData = aggregates.map { aggregate in
                ChartDataPoint(
                    date: aggregate.date,
                    ctl: aggregate.ctl,
                    atl: aggregate.atl,
                    tsb: aggregate.tsb,
                    tss: aggregate.totalTSS
                )
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Change the number of days to display
    func changeDaysSelection(_ days: Int) async {
        selectedDays = days
        await loadHistory()
    }

    // MARK: - Computed Properties

    /// Average score over the period
    var averageScore: Int {
        let scores = historyItems.compactMap(\.score)
        return scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count
    }

    /// Average CTL over the period
    var averageCTL: Int {
        guard !historyItems.isEmpty else { return 0 }
        let total = historyItems.map { $0.ctl }.reduce(0, +)
        return Int(total / Double(historyItems.count))
    }

    /// Total TSS over the period
    var totalTSS: Int {
        Int(historyItems.map { $0.tss }.reduce(0, +))
    }

    /// Total workouts over the period
    var totalWorkouts: Int {
        historyItems.map { $0.workoutCount }.reduce(0, +)
    }

    /// Show empty state
    var showEmptyState: Bool {
        historyItems.isEmpty && !isLoading
    }
}

// MARK: - History Item

struct HistoryItem: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let score: Int?
    let tss: Double
    let ctl: Double
    let atl: Double
    let tsb: Double
    let workoutCount: Int
    let readinessLevel: ReadinessLevel?

    // Equatable conformance for efficient SwiftUI diffing
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.date == rhs.date && lhs.score == rhs.score && lhs.tss == rhs.tss
    }

    var dateDisplay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    var weekdayDisplay: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    var tsbDisplay: String {
        if tsb >= 0 {
            return "+\(Int(tsb))"
        } else {
            return "\(Int(tsb))"
        }
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - Chart Data Point

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let ctl: Double
    let atl: Double
    let tsb: Double
    let tss: Double
}
