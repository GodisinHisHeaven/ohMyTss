import Foundation
import XCTest
@testable import OhMyTssDomain

final class HRPowerDeflectionEstimatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var window: TimeRange { .init(start: start, end: start.addingTimeInterval(16 * 60)) }
    private typealias Fixture = (heartRate: [TimedValue], power: [TimedValue])

    private func fixture() -> Fixture {
        var heartRate = [TimedValue](), power = [TimedValue]()
        for minute in 0..<16 {
            for index in 0..<12 {
                let date = start.addingTimeInterval(Double(minute * 60 + index * 5))
                let end = date.addingTimeInterval(5)
                let hr = 100 + 4 * Double(min(minute, 8)) + 1.2 * Double(max(0, minute - 8))
                heartRate.append(.init(start: date, end: end, value: hr))
                power.append(.init(start: date, end: end, value: 100 + 15 * Double(minute)))
            }
        }
        return (heartRate, power)
    }

    private func estimate(_ input: Fixture, confirmed: Bool = true, pauses: [TimeRange] = [])
        -> HRPowerDeflectionCandidate? {
        HRPowerDeflectionEstimator.candidate(window: window, heartRate: input.heartRate,
            power: input.power, userConfirmedCompleteIncrementalTest: confirmed, pauses: pauses)
    }

    func testUserConfirmationIsRequired() {
        XCTAssertNil(estimate(fixture(), confirmed: false))
    }

    func testSyntheticDeflectionAndSmallNoise() throws {
        var input = fixture()
        let candidate = try XCTUnwrap(estimate(input))
        XCTAssertEqual(candidate.powerWatts, 220, accuracy: 0.01)
        XCTAssertEqual(candidate.heartRateBPM, 132, accuracy: 0.01)
        XCTAssertEqual(candidate.testWindow, window)
        XCTAssertEqual(candidate.analyzedWindow, window)
        for i in input.heartRate.indices { input.heartRate[i].value += [0.5, -0.5, 1.0, -1.0][i % 4] }
        XCTAssertNotNil(estimate(input))
    }

    func testPartialFinalMinuteIsExcludedAndBothWindowsAreRecorded() throws {
        var input = fixture()
        let selectedWindow = TimeRange(start: start, end: window.end.addingTimeInterval(17.25))
        for offset in stride(from: 0.0, to: 17.25, by: 5) {
            let begin = window.end.addingTimeInterval(offset)
            let end = min(begin.addingTimeInterval(5), selectedWindow.end)
            input.heartRate.append(.init(start: begin, end: end, value: 142))
            input.power.append(.init(start: begin, end: end, value: 340))
        }
        let candidate = try XCTUnwrap(HRPowerDeflectionEstimator.candidate(
            window: selectedWindow, heartRate: input.heartRate, power: input.power,
            userConfirmedCompleteIncrementalTest: true))
        XCTAssertEqual(candidate.testWindow, selectedWindow)
        XCTAssertEqual(candidate.analyzedWindow, window)
        XCTAssertEqual(candidate.powerWatts, 220, accuracy: 0.01)
    }

    func testTailMustBeCoveredAndContinueIncrementally() {
        let selectedWindow = TimeRange(start: start, end: window.end.addingTimeInterval(5))
        var input = fixture()
        func run() -> HRPowerDeflectionCandidate? {
            HRPowerDeflectionEstimator.candidate(window: selectedWindow, heartRate: input.heartRate,
                power: input.power, userConfirmedCompleteIncrementalTest: true)
        }
        XCTAssertNil(run(), "Missing tail cannot be silently ignored")
        input.heartRate.append(.init(start: window.end, end: selectedWindow.end, value: 142))
        input.power.append(.init(start: window.end, end: selectedWindow.end, value: 100))
        XCTAssertNil(run(), "Power drop in tail must be rejected")
        input.power[input.power.count - 1].value = 340
        XCTAssertNotNil(run())
        input.heartRate[input.heartRate.count - 1].value = 80
        XCTAssertNil(run(), "Heart-rate drop in tail must be rejected")
    }

    func testRawSamplesRejectConflictInvalidPointsAndLongAverages() {
        var input = fixture()
        input.heartRate.append(.init(start: input.heartRate[20].start,
                                     end: input.heartRate[20].end, value: 200))
        XCTAssertNil(estimate(input), "Conflicting duplicate must not be resolved silently")
        input = fixture()
        input.power.append(input.power[20])
        XCTAssertNotNil(estimate(input), "An exact duplicate is harmless")
        input = fixture()
        for i in input.heartRate.indices { input.heartRate[i].end = input.heartRate[i].start }
        input.heartRate.append(.init(start: window.end, end: window.end, value: 142))
        XCTAssertNotNil(estimate(input), "A boundary observation supports the final point interval")
        input.heartRate[20].value = .nan
        XCTAssertNil(estimate(input), "Invalid point must not disappear under interpolation")
        input = fixture()
        input.power = [.init(start: start, end: window.end, value: 200)]
        XCTAssertNil(estimate(input), "One long average must not claim fine-grained coverage")
    }

    func testRejectsMissingInvalidAndInterruptedObservations() {
        var input = fixture()
        input.heartRate.removeSubrange(5..<11)
        XCTAssertNil(estimate(input))
        input = fixture()
        input.power.removeSubrange(90..<96)
        XCTAssertNil(estimate(input))
        input = fixture()
        input.heartRate = []
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.heartRate.indices { input.heartRate[i].value = .nan }
        XCTAssertNil(estimate(input))
        input = fixture()
        XCTAssertNil(estimate(input, pauses: [.init(start: start.addingTimeInterval(400),
                                                   end: start.addingTimeInterval(410))]))
        XCTAssertNil(HRPowerDeflectionEstimator.candidate(
            window: .init(start: start, end: start.addingTimeInterval(10 * 60)),
            heartRate: input.heartRate, power: input.power,
            userConfirmedCompleteIncrementalTest: true))
    }

    func testIrregularPointTimesAndBoundaryCoverage() {
        var input = fixture()
        input.heartRate = input.heartRate.flatMap { sample in
            [TimedValue(start: sample.start, end: sample.start, value: sample.value),
             TimedValue(start: sample.start.addingTimeInterval(2),
                        end: sample.start.addingTimeInterval(2), value: sample.value)]
        }
        input.heartRate.append(.init(start: window.end, end: window.end, value: 142))
        XCTAssertNotNil(estimate(input), "2/3-second points provide complete coverage")
        input.heartRate.removeSubrange(20..<23)
        XCTAssertNil(estimate(input), "An irregular gap over five seconds remains missing")
    }

    func testRejectsInsufficientSpanOrNonIncrementalPower() {
        var input = fixture()
        for i in input.power.indices { input.power[i].value = 100 + 5 * Double(i / 12) }
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.heartRate.indices { input.heartRate[i].value = 110 }
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.power.indices where i / 12 == 7 { input.power[i].value -= 30 }
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.power.indices where i / 12 >= 10 { input.power[i].value -= 60 }
        XCTAssertNil(estimate(input))
    }

    func testRejectsMissingOrEdgeDeflection() {
        var input = fixture()
        for i in input.heartRate.indices { input.heartRate[i].value = 100 + 3 * Double(i / 12) }
        XCTAssertNil(estimate(input))
        for knot in [2, 13] {
            input = fixture()
            for i in input.heartRate.indices {
                let minute = i / 12
                input.heartRate[i].value = 100 + 4 * Double(min(minute, knot))
                    + 1.2 * Double(max(0, minute - knot))
            }
            XCTAssertNil(estimate(input), "Out-of-range knot \(knot)")
        }
    }

    func testRejectsInterference() {
        var input = fixture()
        input.heartRate[89].value = 220
        XCTAssertNil(estimate(input))
        input = fixture()
        input.power[89].value = 500
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.heartRate.indices where i / 12 == 7 { input.heartRate[i].value -= 20 }
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.heartRate.indices where i / 12 == 7 { input.heartRate[i].value += i % 2 == 0 ? 10 : -10 }
        XCTAssertNil(estimate(input))
        input = fixture()
        for i in input.power.indices where i / 12 == 7 { input.power[i].value += i % 2 == 0 ? 25 : -25 }
        XCTAssertNil(estimate(input))
    }
}
