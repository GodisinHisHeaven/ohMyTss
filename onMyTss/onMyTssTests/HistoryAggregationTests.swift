//
//  HistoryAggregationTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class HistoryAggregationTests: XCTestCase {

    func testSavingAggregatesDoesNotDuplicateExistingRecords() throws {
        let schema = Schema([DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dataStore = DataStore(modelContainer: container)

        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        // Save initial aggregate
        let aggToday = DayAggregate(date: today, totalTSS: 50, ctl: 10, atl: 5, tsb: 5, bodyBatteryScore: 60, workoutCount: 1)
        try dataStore.saveDayAggregatesBatch([aggToday])

        // Update existing aggregate and save again; should not create a duplicate row
        aggToday.totalTSS = 75
        try dataStore.saveDayAggregatesBatch([aggToday])

        var allAggregates = try dataStore.fetchAllDayAggregates()
        XCTAssertEqual(allAggregates.count, 1)
        XCTAssertEqual(allAggregates.first?.totalTSS, 75)

        // Add a new day and save both together
        let aggTomorrow = DayAggregate(date: tomorrow, totalTSS: 40, ctl: 12, atl: 6, tsb: 6, bodyBatteryScore: 65, workoutCount: 1)
        try dataStore.saveDayAggregatesBatch([aggToday, aggTomorrow])

        allAggregates = try dataStore.fetchAllDayAggregates()
        XCTAssertEqual(allAggregates.count, 2)
        XCTAssertTrue(allAggregates.contains { $0.date == today && $0.totalTSS == 75 })
        XCTAssertTrue(allAggregates.contains { $0.date == tomorrow && $0.totalTSS == 40 })
    }
}
