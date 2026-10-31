import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class GarminEstimateTests: XCTestCase {
    private struct Input: Decodable { let features: WorkoutFeatures }
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ begin: Double, _ end: Double, _ value: Double) -> TimedValue {
        TimedValue(start: start.addingTimeInterval(begin), end: start.addingTimeInterval(end), value: value)
    }

    private func makeInput(garminFeatures: WorkoutFeatures, otherFeatures: WorkoutFeatures,
                           reverseInsert: Bool = false) throws -> WorkoutFeatures {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let garmin = Workout(id: "garmin", date: start.startOfDay, startTime: start, duration: 600,
                             workoutType: "Running", tss: 10, calculationMethod: "hr", source: .healthKit)
        garmin.sourceBundleIdentifier = "com.garmin.connect.mobile"
        garmin.features = garminFeatures
        let other = Workout(id: "other", date: start.startOfDay, startTime: start, duration: 600,
                            workoutType: "Run", tss: 20, calculationMethod: "hr", source: .strava)
        other.features = otherFeatures
        other.isSuppressed = true
        other.linkedSessionID = garmin.id
        for row in reverseInsert ? [other, garmin] : [garmin, other] { context.insert(row) }
        let result = try V2EstimateBatch(context: context).calculate(now: start.addingTimeInterval(600))
        return try JSONDecoder().decode(Input.self, from: XCTUnwrap(result.first).inputData).features
    }

    func testGarminWinsOverlappingIntervalsAndOtherSourceFillsGaps() throws {
        var garmin = WorkoutFeatures()
        garmin.end = start.addingTimeInterval(600)
        garmin.heartRate = [sample(0, 60, 160)]
        var other = WorkoutFeatures()
        other.end = start.addingTimeInterval(600)
        other.heartRate = [sample(0, 600, 140)]
        other.power = [sample(0, 600, 180)]
        let input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.heartRate, [sample(0, 60, 160), sample(60, 600, 140)])
        XCTAssertEqual(input.power, other.power)
        XCTAssertEqual(SignalProcessing.coveredSeconds(input.heartRate), 600)
        XCTAssertEqual(input, try makeInput(garminFeatures: garmin, otherFeatures: other, reverseInsert: true))
    }

    func testEachSourcePausesAreHonoredWithoutErasingGarminMeasurements() throws {
        var garmin = WorkoutFeatures()
        garmin.end = start.addingTimeInterval(600)
        garmin.heartRate = [sample(0, 60, 160)]
        garmin.pauses = [TimeRange(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180))]
        var other = WorkoutFeatures()
        other.end = start.addingTimeInterval(600)
        other.heartRate = [sample(0, 600, 140)]
        other.pauses = [TimeRange(start: start.addingTimeInterval(300), end: start.addingTimeInterval(400)),
                        TimeRange(start: start.addingTimeInterval(10), end: start.addingTimeInterval(20))]
        let input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.heartRate, [sample(0, 60, 160), sample(60, 120, 140),
                                         sample(180, 300, 140), sample(400, 600, 140)])
        XCTAssertEqual(input.pauses, garmin.pauses)
        XCTAssertEqual(SignalProcessing.coveredSeconds(input.heartRate), 440)
    }

    func testUnavailableGarminChannelFallsBackToOtherSource() throws {
        var garmin = WorkoutFeatures()
        garmin.end = start.addingTimeInterval(600)
        // Out-of-range data is not usable Garmin support.
        garmin.heartRate = [sample(0, 600, 999)]
        var other = WorkoutFeatures()
        other.end = start.addingTimeInterval(600)
        other.heartRate = [sample(0, 600, 140)]
        let input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.heartRate, other.heartRate)
    }

    func testGarminIntervalsRemainOrderedAndNeverDoubleCountOverlappingSources() throws {
        var garmin = WorkoutFeatures()
        garmin.end = start.addingTimeInterval(600)
        garmin.heartRate = [sample(200, 300, 160), sample(400, 500, 170)]
        var other = WorkoutFeatures()
        other.end = start.addingTimeInterval(600)
        other.heartRate = [sample(0, 600, 140)]
        let input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.heartRate, [sample(0, 200, 140), sample(200, 300, 160), sample(300, 400, 140),
                                         sample(400, 500, 170), sample(500, 600, 140)])
        XCTAssertEqual(SignalProcessing.coveredSeconds(input.heartRate), 600)
    }

    func testGarminSwimSegmentsAndAscentWinWithMissingFieldsFallingBack() throws {
        var garmin = WorkoutFeatures()
        garmin.end = start.addingTimeInterval(600)
        garmin.swimSegments = [SwimSegment(start: start, end: start.addingTimeInterval(100), stroke: "freestyle")]
        garmin.ascentMeters = 100
        var other = WorkoutFeatures()
        other.end = start.addingTimeInterval(600)
        other.swimSegments = [SwimSegment(start: start, end: start.addingTimeInterval(100), stroke: "backstroke"),
                              SwimSegment(start: start.addingTimeInterval(100), end: start.addingTimeInterval(200), stroke: "backstroke")]
        other.ascentMeters = 200
        other.descentMeters = 30
        var input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.swimSegments, garmin.swimSegments)
        XCTAssertEqual(input.ascentMeters, 100)
        XCTAssertEqual(input.descentMeters, 30)
        garmin.swimSegments = []
        garmin.ascentMeters = nil
        input = try makeInput(garminFeatures: garmin, otherFeatures: other)
        XCTAssertEqual(input.swimSegments, other.swimSegments)
        XCTAssertEqual(input.ascentMeters, 200)
    }
}
