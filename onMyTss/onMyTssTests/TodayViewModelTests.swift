//
//  TodayViewModelTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class TodayViewModelTests: XCTestCase {

    func testLoadDataTriggersSyncWhenNoAggregate() async throws {
        let schema = Schema([
            DayAggregate.self,
            UserThresholds.self,
            AppState.self,
            Workout.self,
            StravaAuth.self
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dataStore = DataStore(modelContainer: container)

        let mockEngine = MockEngine(dataStore: dataStore)
        let viewModel = TodayViewModel(engine: mockEngine, dataStore: dataStore)

        await viewModel.loadData()

        XCTAssertTrue(mockEngine.recomputeCalled, "Expected recomputeAll to be called when no aggregate exists.")
        XCTAssertNotNil(viewModel.todayMetrics, "Today metrics should be populated after sync.")
    }
}

// MARK: - Test Doubles

@MainActor
private final class MockEngine: BodyBatteryEngineProtocol {
    let dataStore: onMyTss.DataStore
    var recomputeCalled = false

    init(dataStore: onMyTss.DataStore) {
        self.dataStore = dataStore
    }

    func recomputeAll() async throws {
        recomputeCalled = true
        let today = Date().startOfDay
        let aggregate = DayAggregate(
            date: today,
            totalTSS: 0,
            ctl: 0,
            atl: 0,
            tsb: 0,
            bodyBatteryScore: 50,
            rampRate: nil,
            workoutCount: 0,
            maxTSSWorkout: nil
        )
        try dataStore.saveDayAggregate(aggregate)
    }

    func incrementalUpdate() async throws {
        // No-op for this test
    }
}
