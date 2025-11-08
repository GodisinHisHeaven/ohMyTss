import XCTest
@testable import TSSEngine

final class BodyBatteryCalculatorTests: XCTestCase {

    func testRawScoreMapping() {
        // TSB of 0 → 50% battery
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 0), 50)

        // TSB of +30 → 100% battery
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 30), 100)

        // TSB of -30 → 0% battery
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: -30), 0)

        // TSB of +15 → 75% battery
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 15), 75)

        // TSB of -15 → 25% battery
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: -15), 25)
    }

    func testClamping() {
        // Values beyond ±30 should clamp to 0-100
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 50), 100)
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: -50), 0)
    }

    func testFinalScoreWithAdjustments() {
        // Base TSB of 0 (50% raw)
        let tsb = 0.0

        // Positive HRV adjustment (+10)
        let scoreHigh = BodyBatteryCalculator.finalScore(tsb: tsb, hrvAdjustment: 10, rhrAdjustment: 0)
        XCTAssertEqual(scoreHigh, 60)

        // Negative HRV adjustment (-10)
        let scoreLow = BodyBatteryCalculator.finalScore(tsb: tsb, hrvAdjustment: -10, rhrAdjustment: 0)
        XCTAssertEqual(scoreLow, 40)

        // Combined adjustment
        let scoreCombined = BodyBatteryCalculator.finalScore(tsb: tsb, hrvAdjustment: 5, rhrAdjustment: -3)
        XCTAssertEqual(scoreCombined, 52)
    }

    func testAdjustmentClamping() {
        // Large adjustments should still clamp to 0-100
        let score = BodyBatteryCalculator.finalScore(tsb: 30, hrvAdjustment: 50, rhrAdjustment: 0)
        XCTAssertEqual(score, 100)

        let scoreLow = BodyBatteryCalculator.finalScore(tsb: -30, hrvAdjustment: -50, rhrAdjustment: 0)
        XCTAssertEqual(scoreLow, 0)
    }
}
