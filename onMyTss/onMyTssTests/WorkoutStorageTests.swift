//
//  WorkoutStorageTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class WorkoutStorageTests: XCTestCase {

    func testSaveWorkoutsUpsertsById() throws {
        let schema = Schema([DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)

        let date = Date().startOfDay
        let workout1 = Workout(
            id: "w1",
            date: date,
            startTime: date,
            duration: 3600,
            workoutType: "Ride",
            tss: 50,
            calculationMethod: "power",
            source: .strava,
            averagePower: 200,
            normalizedPower: 220
        )

        try store.saveWorkouts([workout1])
        var fetched = try store.fetchWorkout(byId: "w1")
        XCTAssertEqual(fetched?.tss, 50)

        // Update same ID with new TSS and ensure it's replaced, not duplicated
        let workoutUpdated = Workout(
            id: "w1",
            date: date,
            startTime: date,
            duration: 3600,
            workoutType: "Ride",
            tss: 75,
            calculationMethod: "power",
            source: .strava,
            averagePower: 205,
            normalizedPower: 225
        )

        try store.saveWorkouts([workoutUpdated])
        fetched = try store.fetchWorkout(byId: "w1")
        XCTAssertEqual(fetched?.tss, 75)

        // Ensure only one record exists
        let all = try store.fetchWorkouts(from: date, to: date, includeSupressed: true)
        XCTAssertEqual(all.count, 1)
    }
}
