import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class StravaCorrectedStartTests: XCTestCase {
    func testMissingElapsedEqualDurationDoesNotPropagateUserDeletionAfterCorrection() async throws {
        let fixture = try makeFixture(healthDuration: 600, userDeletedHealth: true)
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.health.startTime = fixture.correction.startTime.addingTimeInterval(20)
        var healthFeatures = fixture.health.features
        healthFeatures.end = fixture.health.startTime.addingTimeInterval(600)
        fixture.health.features = healthFeatures
        let cache = try await fixture.store.prepareWorkoutEndpoints(incoming: [fixture.correction])
        for _ in 0..<2 {
            try fixture.store.saveWorkouts([fixture.correction], prewarmed: cache)
            _ = try fixture.store.finalizeWorkoutSources(prewarmed: cache)
            _ = try await fixture.store.repairWorkoutSourcesLocally()
            let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
            XCTAssertNil(saved.features.end)
            XCTAssertFalse(saved.isTombstoned)
            XCTAssertFalse(saved.isSuppressed)
            XCTAssertNil(saved.linkedSessionID)
            XCTAssertEqual(saved.userTags, ["personal-tag"])
            XCTAssertEqual(fixture.health.deletionOrigin, "user")
            XCTAssertTrue(fixture.health.isTombstoned)
        }
    }

    func testCorrectedStartWithMissingElapsedStillGroupsMatchingDuration() async throws {
        let fixture = try makeFixture(healthDuration: 600, userDeletedHealth: false)
        defer { withExtendedLifetime(fixture.container) {} }
        let cache = try await fixture.store.prepareWorkoutEndpoints(incoming: [fixture.correction])
        try fixture.store.saveWorkouts([fixture.correction], prewarmed: cache)
        let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
        XCTAssertNil(saved.features.end, "The old absolute end must not be attached to a corrected start")
        XCTAssertEqual(saved.features.heartRate, fixture.retainedHeartRate)
        XCTAssertEqual(saved.userTags, ["personal-tag"])
        XCTAssertTrue(saved.isSuppressed)
        XCTAssertEqual(saved.linkedSessionID, fixture.health.id)
        XCTAssertFalse(fixture.health.isSuppressed)
        _ = try fixture.store.finalizeWorkoutSources(prewarmed: cache)
        _ = try await fixture.store.repairWorkoutSourcesLocally()
        XCTAssertTrue(saved.isSuppressed)
        XCTAssertEqual(saved.linkedSessionID, fixture.health.id)
        XCTAssertFalse(fixture.health.isSuppressed)
    }

    func testCorrectedStartWithMissingElapsedDoesNotPropagateUnrelatedDeletion() async throws {
        let fixture = try makeFixture(healthDuration: 300, userDeletedHealth: true)
        defer { withExtendedLifetime(fixture.container) {} }
        let cache = try await fixture.store.prepareWorkoutEndpoints(incoming: [fixture.correction])
        try fixture.store.saveWorkouts([fixture.correction], prewarmed: cache)
        let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
        XCTAssertNil(saved.features.end)
        XCTAssertFalse(saved.isSuppressed)
        XCTAssertFalse(saved.isTombstoned)
        XCTAssertNil(saved.deletionOrigin)
        XCTAssertNil(saved.linkedSessionID)
        XCTAssertEqual(saved.features.heartRate, fixture.retainedHeartRate)
        XCTAssertTrue(fixture.health.isTombstoned)
        XCTAssertEqual(fixture.health.deletionOrigin, "user")
        _ = try fixture.store.finalizeWorkoutSources(prewarmed: cache)
        _ = try await fixture.store.repairWorkoutSourcesLocally()
        XCTAssertFalse(saved.isSuppressed)
        XCTAssertFalse(saved.isTombstoned)
        XCTAssertNil(saved.deletionOrigin)
        XCTAssertEqual(saved.userTags, ["personal-tag"])
    }

    func testCorrectedStartInvalidatesIdenticalIncompletePayloadAndSurvivesReplay() async throws {
        let fixture = try makeFixture(healthDuration: 300, userDeletedHealth: true)
        defer { withExtendedLifetime(fixture.container) {} }
        let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
        var previous = saved.features
        previous.unavailableChannels = ["elapsed", "heartRate"]
        saved.features = previous
        fixture.correction.featuresData = saved.featuresData
        XCTAssertEqual(fixture.correction.featuresData, saved.featuresData)
        let cache = try await fixture.store.prepareWorkoutEndpoints(incoming: [fixture.correction])
        try fixture.store.saveWorkouts([fixture.correction], prewarmed: cache)
        XCTAssertNil(saved.features.end)
        XCTAssertEqual(saved.features.heartRate, fixture.retainedHeartRate)
        XCTAssertFalse(saved.isTombstoned)
        XCTAssertNil(saved.linkedSessionID)
        // A repeated source response must not reinstate the old absolute end.
        try fixture.store.saveWorkouts([fixture.correction], prewarmed: cache)
        _ = try fixture.store.finalizeWorkoutSources(prewarmed: cache)
        XCTAssertNil(saved.features.end)
        XCTAssertFalse(saved.isTombstoned)
        XCTAssertFalse(saved.isSuppressed)
        XCTAssertEqual(fixture.health.deletionOrigin, "user")
    }

    func testCorrectedStartWithNoPayloadRetainsChannelsButClearsOldEnd() async throws {
        let fixture = try makeFixture(healthDuration: 300, userDeletedHealth: true)
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.correction.featuresData = nil
        try fixture.store.saveWorkouts([fixture.correction])
        let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
        XCTAssertNil(saved.features.end)
        XCTAssertTrue(saved.features.unavailableChannels.contains("elapsed"))
        XCTAssertEqual(saved.features.heartRate, fixture.retainedHeartRate)
        XCTAssertEqual(saved.userTags, ["personal-tag"])
        XCTAssertFalse(saved.isTombstoned)
        XCTAssertFalse(saved.isSuppressed)
        _ = try fixture.store.finalizeWorkoutSources()
        XCTAssertFalse(saved.isTombstoned)
    }

    func testCorrectedStartUsesNewlyReportedEnd() throws {
        let fixture = try makeFixture(healthDuration: 600, userDeletedHealth: false)
        defer { withExtendedLifetime(fixture.container) {} }
        var reported = fixture.correction.features
        reported.unavailableChannels = ["heartRate"]
        reported.end = fixture.correction.startTime.addingTimeInterval(600)
        fixture.correction.features = reported
        try fixture.store.saveWorkouts([fixture.correction])
        let saved = try XCTUnwrap(fixture.store.fetchWorkout(byId: "strava"))
        XCTAssertEqual(saved.features.end, reported.end)
        XCTAssertTrue(saved.isSuppressed)
        XCTAssertEqual(saved.linkedSessionID, fixture.health.id)
        XCTAssertEqual(saved.features.heartRate, fixture.retainedHeartRate)
    }

    private func makeFixture(healthDuration: TimeInterval, userDeletedHealth: Bool) throws
        -> (container: ModelContainer, store: onMyTss.DataStore, health: Workout,
            correction: Workout, retainedHeartRate: [TimedValue]) {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        let originalStart = Date(timeIntervalSince1970: 1_750_000_000)
        let correctedStart = originalStart.addingTimeInterval(300)
        let old = Workout(id: "strava", date: originalStart.startOfDay, startTime: originalStart,
                          duration: 600, workoutType: "Run", tss: 10,
                          calculationMethod: "duration", source: .strava)
        let heartRate = [TimedValue(start: originalStart, end: originalStart.addingTimeInterval(10), value: 140)]
        var oldFeatures = WorkoutFeatures()
        oldFeatures.end = originalStart.addingTimeInterval(600)
        oldFeatures.heartRate = heartRate
        old.features = oldFeatures
        old.userTags = ["personal-tag"]
        let health = Workout(id: "health", date: correctedStart.startOfDay, startTime: correctedStart,
                             duration: healthDuration, workoutType: "Running", tss: 10,
                             calculationMethod: "duration", source: .healthKit)
        health.sourceBundleIdentifier = "com.garmin.connect.mobile"
        var healthFeatures = WorkoutFeatures()
        healthFeatures.end = correctedStart.addingTimeInterval(healthDuration)
        health.features = healthFeatures
        if userDeletedHealth { health.isTombstoned = true; health.deletionOrigin = "user" }
        try store.saveWorkouts([old, health])
        let correction = Workout(id: "strava", date: correctedStart.startOfDay, startTime: correctedStart,
                                 duration: 600, workoutType: "Run", tss: 10,
                                 calculationMethod: "duration", source: .strava)
        var incomplete = WorkoutFeatures()
        incomplete.unavailableChannels = ["elapsed", "heartRate"]
        correction.features = incomplete
        return (container, store, health, correction, heartRate)
    }
}
