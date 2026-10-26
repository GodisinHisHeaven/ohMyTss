import Foundation
import XCTest
@testable import OhMyTssDomain

final class SignalTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    func value(_ start: Double, _ end: Double, _ value: Double) -> TimedValue {
        TimedValue(start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end), value: value)
    }
    func window(_ seconds: Double) -> TimeRange { TimeRange(start: origin, end: origin.addingTimeInterval(seconds)) }

    func testRegularAndIrregularSamplingOfSameSignalAgree() throws {
        // A known constant 200 W signal sampled at 1s and irregular 2/7/11s.
        let regular = (0...120).map { value(Double($0), Double($0), 200) }
        let times = [0, 2, 9, 20, 27, 31, 40, 51, 60, 67, 78, 80, 91, 100, 110, 120]
        let irregular = times.map { value(Double($0), Double($0), 200) }
        let a = SignalProcessing.intervals(samples: regular, window: window(120), validRange: 0...2500)
        let b = SignalProcessing.intervals(samples: irregular, window: window(120), validRange: 0...2500)
        XCTAssertEqual(SignalProcessing.coveredSeconds(a), 120, accuracy: 0.001)
        XCTAssertEqual(SignalProcessing.coveredSeconds(b), 120, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(a)), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(b)), 200, accuracy: 0.001)
    }

    func testThirtySamplesAreNotAssumedToBeThirtySeconds() throws {
        // 30 one-second intervals are exactly one 30s window; 30 five-second
        // intervals span 150s and include many complete 0 W and 400 W windows.
        let one = (0..<30).map { index -> TimedValue in
            let start = Double(index)
            return value(start, start + 1, index < 15 ? 0 : 400)
        }
        let five = (0..<30).map { index -> TimedValue in
            let start = Double(index * 5)
            return value(start, start + 5, index < 15 ? 0 : 400)
        }
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(one)), 200, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(SignalProcessing.normalizedPower(five)), 300)
    }

    func testStepSignalSamplingInvariantWithKnownWeightedMean() throws {
        let intervals = [value(0, 20, 100), value(20, 60, 250)]
        let split = [value(0, 3, 100), value(3, 20, 100), value(20, 27, 250), value(27, 60, 250)]
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.weightedMean(intervals)), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(intervals)),
                       try XCTUnwrap(SignalProcessing.normalizedPower(split)), accuracy: 0.001)
    }

    func testGapsAreUnknownAndFinalPointIsNotExtended() {
        let points = [value(0, 0, 100), value(5, 5, 100), value(60, 60, 100), value(65, 65, 100)]
        let result = SignalProcessing.intervals(samples: points, window: window(100), validRange: 0...2500)
        XCTAssertEqual(SignalProcessing.coveredSeconds(result), 10)
        XCTAssertNil(SignalProcessing.normalizedPower(result))
    }

    func testPausesRemoveSupportAndPreventRollingWindowBridge() {
        let result = SignalProcessing.intervals(samples: [value(0, 60, 200)], window: window(60),
            pauses: [.init(start: origin.addingTimeInterval(20), end: origin.addingTimeInterval(40))], validRange: 0...2500)
        XCTAssertEqual(SignalProcessing.coveredSeconds(result), 40)
        XCTAssertNil(SignalProcessing.normalizedPower(result))
    }

    func testUnorderedOverlappingDuplicateAndInvalidValuesDoNotDoubleCount() throws {
        let samples = [value(20, 30, 200), value(0, 30, 100), value(0, 30, 100),
                       value(30, 40, .nan), value(40, 50, .infinity), value(50, 60, -1)]
        let result = SignalProcessing.intervals(samples: samples, window: window(60), validRange: 0...2500)
        XCTAssertEqual(SignalProcessing.coveredSeconds(result), 30)
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.weightedMean(result)), 4000.0 / 30, accuracy: 0.001)
        XCTAssertTrue(result.allSatisfy { $0.value.isFinite })
    }

    func testClippingHonorsAbsoluteTimeAcrossMidnight() {
        let beforeMidnight = Date(timeIntervalSince1970: 1_704_153_590) // 2024-01-01 23:59:50Z
        let afterMidnight = beforeMidnight.addingTimeInterval(20)
        let interval = TimedValue(start: beforeMidnight.addingTimeInterval(-10), end: afterMidnight.addingTimeInterval(10), value: 100)
        let result = SignalProcessing.intervals(samples: [interval],
            window: .init(start: beforeMidnight, end: afterMidnight), validRange: 0...2500)
        XCTAssertEqual(result, [.init(start: beforeMidnight, end: afterMidnight, value: 100)])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var pacific = utc
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertNotEqual(utc.startOfDay(for: beforeMidnight), utc.startOfDay(for: afterMidnight))
        XCTAssertEqual(pacific.startOfDay(for: beforeMidnight), pacific.startOfDay(for: afterMidnight))
        XCTAssertEqual(SignalProcessing.coveredSeconds(result), 20)
    }

    func testTrueZeroPowerIsObservedButMissingPowerIsNot() throws {
        let zero = [value(0, 60, 0)]
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(zero)), 0)
        XCTAssertNil(SignalProcessing.normalizedPower([]))
        XCTAssertNil(SignalProcessing.weightedMean([]))
    }

    func testSamePowerDifferentCadenceChangesMechanicalTorqueOnly() throws {
        let power = [value(0, 60, 200)]
        let low = SignalProcessing.torque(power: power, cadence: [value(0, 60, 60)])
        let high = SignalProcessing.torque(power: power, cadence: [value(0, 60, 90)])
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.weightedMean(low)), 200 / (2 * Double.pi), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.weightedMean(high)), 200 / (3 * Double.pi), accuracy: 0.001)
        XCTAssertTrue(SignalProcessing.torque(power: power, cadence: [value(0, 60, 0)]).isEmpty)
        // No assertion about a muscle-force or recovery ratio is made.
    }

    func testAltitudeNoiseDoesNotInventClimbingAndMissingRouteRemainsMissing() throws {
        let noisyFlat = (0..<30).map { value(Double($0), Double($0), $0 % 2 == 0 ? 100 : 101) }
        let elevation = try XCTUnwrap(SignalProcessing.elevationChange(noisyFlat))
        XCTAssertEqual(elevation.ascent, 0)
        XCTAssertEqual(elevation.descent, 0)
        XCTAssertNil(SignalProcessing.elevationChange([]))
    }
    func testLongRideUsesTimestampWindowsWithoutSamplingDrift() throws {
        let samples = (0..<10_800).map { value(Double($0), Double($0 + 1), 180) }
        XCTAssertEqual(try XCTUnwrap(SignalProcessing.normalizedPower(samples)), 180, accuracy: 0.001)
    }

}
