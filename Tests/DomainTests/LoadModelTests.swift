import Foundation
import XCTest
@testable import OhMyTssDomain

final class LoadModelTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    func sample(_ start: Double, _ end: Double, _ value: Double) -> TimedValue {
        .init(start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end), value: value)
    }
    func estimate(type: String = "Running", duration: Double = 600,
                  features: WorkoutFeatures = .init(), sets: [StrengthSetInput] = [],
                  tags: [String] = [], maxHR: Int? = 200, now: Date? = nil) -> LoadEstimateValue {
        LoadModel.estimate(type: type, start: origin, duration: duration, distance: nil,
            features: features, sets: sets, tags: tags, maxHeartRate: maxHR,
            now: now ?? origin.addingTimeInterval(86_400))
    }

    func testFutureAltitudeAndWholeSessionSummaryCannotEnterEarlierEstimate() {
        var known = WorkoutFeatures()
        known.end = origin.addingTimeInterval(600)
        known.elevation = (0...5).map { sample(Double($0 * 10), Double($0 * 10), 100) }
        var future = known
        future.elevation += (6...60).map { sample(Double($0 * 10), Double($0 * 10), Double($0 * 20)) }
        future.ascentMeters = 1100
        future.descentMeters = 400
        let cutoff = origin.addingTimeInterval(50)
        let before = estimate(features: known, now: cutoff)
        let withFuture = estimate(features: future, now: cutoff)
        XCTAssertEqual(withFuture.regions, before.regions)
        XCTAssertEqual(withFuture.inputCutoff, cutoff)
    }

    func testHeartRateDistributionUsesTimeNotWholeWorkoutMean() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 300, 80), sample(300, 600, 200)]
        let result = estimate(features: features)
        // Five observed minutes below 50% -> 0; five at max -> 25 zone minutes.
        XCTAssertEqual(try XCTUnwrap(result.cardio).points, 25)
        features.heartRate = [sample(0, 600, 140)]
        // Mean HR alone would produce 10 minutes in the 70–80% band = 30.
        XCTAssertEqual(try XCTUnwrap(estimate(features: features).cardio).points, 30)
    }

    func testMissingHRAndConfiguredMaximumAreUnknownNotZero() throws {
        XCTAssertNil(estimate().cardio)
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 600, 100)]
        XCTAssertNil(estimate(features: features, maxHR: nil).cardio)
        XCTAssertNil(estimate(features: features, maxHR: 0).cardio)
        features.heartRate = [sample(0, 600, 80)]
        let measured = try XCTUnwrap(estimate(features: features).cardio)
        XCTAssertEqual(measured.points, 0)
        XCTAssertEqual(measured.coverage, 1)
    }

    func testMissingTimeDoesNotScaleObservedCardioToFullDuration() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 60, 180)]
        let cardio = try XCTUnwrap(estimate(features: features).cardio)
        XCTAssertEqual(cardio.points, 5)
        XCTAssertEqual(cardio.coverage, 0.1, accuracy: 0.001)
    }

    func testPausesExcludeCardioAndUseActualElapsedEndpoint() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 900, 180)]
        features.end = origin.addingTimeInterval(900)
        features.pauses = [.init(start: origin.addingTimeInterval(300), end: origin.addingTimeInterval(600))]
        let cardio = try XCTUnwrap(estimate(duration: 600, features: features).cardio)
        XCTAssertEqual(cardio.points, 50)
        XCTAssertEqual(cardio.coverage, 1)
    }

    func testNoFutureSamplesEnterFrozenCutoff() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 600, 180)]
        let cutoff = origin.addingTimeInterval(60)
        let result = estimate(features: features, now: cutoff)
        XCTAssertEqual(result.inputCutoff, cutoff)
        XCTAssertEqual(result.computedAt, cutoff)
        XCTAssertEqual(try XCTUnwrap(result.cardio).points, 5)
    }

    func testNoFTPRequiredForAnyModalityOrCardio() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 600, 180)]
        for type in ["Running", "Cycling", "Swimming", "Strength"] {
            XCTAssertEqual(try XCTUnwrap(estimate(type: type, features: features).cardio).points, 50)
        }
    }

    func testInvalidEmptyDurationNeverProducesNaNOrFakeRecovery() throws {
        for duration in [0, -1, Double.nan, .infinity] {
            let result = estimate(duration: duration)
            XCTAssertNil(result.cardio)
            XCTAssertTrue(result.regions.isEmpty)
            XCTAssertTrue(result.coverage.isFinite)
            XCTAssertTrue(result.reasons.contains { $0.contains("recovery time cannot yet be estimated") })
        }
    }

    func testRIRZeroAndMissingEffortStayDistinct() throws {
        let failure = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 50, rir: 0)
        let unknown = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 50, rir: nil)
        let a = try XCTUnwrap(estimate(type: "Strength", sets: [failure]).regions.first { $0.region == .quads })
        let b = try XCTUnwrap(estimate(type: "Strength", sets: [unknown]).regions.first { $0.region == .quads })
        XCTAssertEqual(a.exposure, 1.25)
        XCTAssertEqual(b.exposure, 1)
        XCTAssertEqual(a.coverage, 1)
        XCTAssertEqual(b.coverage, 0)
        XCTAssertTrue(b.reasons.contains { $0.contains("effort unknown") })
    }

    func testStrengthAddEditDeleteChangesRegionWithoutAddingCardio() throws {
        let squat = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 50, rir: 2)
        let press = StrengthSetInput(exerciseID: "bench_press", reps: 10, weightKG: 50, rir: 2)
        let one = estimate(type: "Strength", sets: [squat])
        let two = estimate(type: "Strength", sets: [squat, squat])
        let edit = estimate(type: "Strength", sets: [press])
        XCTAssertEqual(try XCTUnwrap(one.regions.first { $0.region == .quads }).exposure, 1)
        XCTAssertEqual(try XCTUnwrap(two.regions.first { $0.region == .quads }).exposure, 2)
        XCTAssertFalse(edit.regions.contains { $0.region == .quads })
        XCTAssertTrue(estimate(type: "Strength", sets: []).regions.isEmpty)
        XCTAssertNil(two.cardio)
    }

    func testUnsupportedExerciseRequiresExplicitManualRegionAndIsLowConfidence() throws {
        let unknown = StrengthSetInput(exerciseID: "unknown", reps: 10, weightKG: nil, rir: nil)
        XCTAssertTrue(estimate(type: "Strength", sets: [unknown]).regions.isEmpty)
        var manual = unknown
        manual.manualRegions = [.back]
        let region = try XCTUnwrap(estimate(type: "Strength", sets: [manual]).regions.first)
        XCTAssertEqual(region.region, .back)
        XCTAssertEqual(region.coverage, 0)
        XCTAssertTrue(region.reasons.contains { $0.contains("low confidence") })
    }

    func testStrengthMassIsContextNotUniversalFatigueOrRecovery() throws {
        let light = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 20, rir: 2)
        let heavy = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 80, rir: 2)
        let a = try XCTUnwrap(estimate(type: "Strength", sets: [light]).regions.first)
        let b = try XCTUnwrap(estimate(type: "Strength", sets: [heavy]).regions.first)
        XCTAssertEqual(a.exposure, b.exposure)
        XCTAssertNotEqual(a.reasons, b.reasons)
        XCTAssertTrue(b.reasons.contains { $0.contains("800.0 kg·reps") })
    }

    func testFeaturesOnlyInfluenceRegionsWhenObserved() throws {
        let missing = estimate(type: "Cycling", duration: 1200)
        var features = WorkoutFeatures()
        features.power = [sample(0, 1200, 300)]
        features.cadence = [sample(0, 1200, 40)]
        let observed = estimate(type: "Cycling", duration: 1200, features: features)
        XCTAssertEqual(try XCTUnwrap(missing.regions.first { $0.region == .quads }).level, "Moderate")
        XCTAssertEqual(try XCTUnwrap(observed.regions.first { $0.region == .quads }).level, "High")
        XCTAssertTrue(missing.regions.allSatisfy { $0.reasons.contains { $0.contains("torque unknown") } })
    }

    func testNoRouteDoesNotInventSlopeButMeasuredDownhillChangesQuads() throws {
        let missing = estimate()
        var features = WorkoutFeatures()
        features.grade = [sample(0, 600, -0.05)]
        let downhill = estimate(features: features)
        XCTAssertEqual(try XCTUnwrap(missing.regions.first { $0.region == .quads }).level, "Low")
        XCTAssertEqual(try XCTUnwrap(downhill.regions.first { $0.region == .quads }).level, "Moderate")
        XCTAssertTrue(missing.regions.allSatisfy { $0.reasons.contains { $0.contains("slope unavailable") } })
    }

    func testSwimStrokeAndUserEquipmentRemainDistinctFromUnknown() throws {
        var features = WorkoutFeatures()
        features.swimSegments = [.init(start: origin, end: origin.addingTimeInterval(300), stroke: "breaststroke")]
        let unknown = estimate(type: "Swimming")
        let known = estimate(type: "Swimming", features: features, tags: ["paddles"])
        XCTAssertFalse(unknown.regions.contains { $0.region == .chest })
        XCTAssertTrue(known.regions.contains { $0.region == .chest })
        XCTAssertEqual(try XCTUnwrap(known.regions.first { $0.region == .shoulders }).level, "Moderate")
        XCTAssertTrue(unknown.regions.allSatisfy { $0.reasons.contains { $0.contains("Equipment unknown") } })
    }

    func testSnapshotRoundTripRetainsVersionCutoffAndSeparateMethods() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 600, 180)]
        let original = estimate(features: features)
        let decoded = try JSONDecoder().decode(LoadEstimateValue.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, "v2-exposure-1")
        XCTAssertNotEqual(decoded.cardio?.method, decoded.regions.first?.method)
        XCTAssertEqual(ExerciseCatalog.exercises.count, 26)
        XCTAssertEqual(Set(ExerciseCatalog.exercises.map(\.id)).count, 26)
    }
    func testUnlocatedPausesUseElapsedCoverageAndExplicitMethod() throws {
        var features = WorkoutFeatures()
        features.end = origin.addingTimeInterval(3600)
        features.heartRate = [sample(0, 3600, 180)]
        let cardio = try XCTUnwrap(estimate(duration: 1800, features: features).cardio)
        // Measured elapsed HR is retained, with uncertainty about pause locations.
        XCTAssertEqual(cardio.points, 300)
        XCTAssertEqual(cardio.coverage, 1)
        XCTAssertEqual(cardio.method, "HR zone minutes (unlocated pauses)")
        XCTAssertTrue(cardio.reasons.contains { $0.contains("Unlocated inactive time") })
        features.heartRate = [sample(0, 1800, 180)]
        XCTAssertEqual(try XCTUnwrap(estimate(duration: 1800, features: features).cardio).coverage, 0.5)
    }

    func testStrengthDetailsDoNotEraseEnduranceOrDoubleCardio() throws {
        var features = WorkoutFeatures()
        features.heartRate = [sample(0, 600, 180)]
        let squat = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 50, rir: 2)
        let original = estimate(type: "Running", features: features)
        let supplemented = estimate(type: "Running", features: features, sets: [squat])
        XCTAssertEqual(supplemented.cardio, original.cardio)
        XCTAssertEqual(supplemented.regions.filter { $0.unit == "running minutes" }, original.regions)
        XCTAssertEqual(supplemented.regions.filter { $0.region == .quads }.count, 2)
        XCTAssertEqual(Set(supplemented.regions.map(\.id)).count, supplemented.regions.count)
    }

    func testFutureSessionDoesNotPretendCompletedSetsOrLoad() {
        let squat = StrengthSetInput(exerciseID: "squat", reps: 10, weightKG: 50, rir: 2)
        let now = origin.addingTimeInterval(-60)
        let result = estimate(type: "Strength", sets: [squat], now: now)
        XCTAssertTrue(result.regions.isEmpty)
        XCTAssertNil(result.cardio)
        XCTAssertEqual(result.inputCutoff, now)
    }

}
