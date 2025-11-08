import XCTest
@testable import TSSEngine

final class PhysiologyModifierTests: XCTestCase {

    func testBaselineCalculation() {
        let samples = [50.0, 52.0, 48.0, 51.0, 49.0, 53.0, 47.0, 50.0, 52.0, 48.0]
        let baseline = PhysiologyModifier.calculateBaseline(samples: samples, excludeLast: 0)

        // Median should be around 50
        XCTAssertEqual(baseline.median, 50, accuracy: 1)

        // MAD should be around 2
        XCTAssertGreaterThan(baseline.mad, 0)
    }

    func testRobustZScore() {
        let baseline = PhysiologyModifier.Baseline(median: 50, mad: 5)

        // Value at median → z = 0
        XCTAssertEqual(PhysiologyModifier.robustZScore(value: 50, baseline: baseline), 0, accuracy: 0.1)

        // Value above median → positive z
        let zPositive = PhysiologyModifier.robustZScore(value: 60, baseline: baseline)
        XCTAssertGreaterThan(zPositive, 0)

        // Value below median → negative z
        let zNegative = PhysiologyModifier.robustZScore(value: 40, baseline: baseline)
        XCTAssertLessThan(zNegative, 0)
    }

    func testIllnessDetection() {
        // Normal: no illness
        XCTAssertFalse(PhysiologyModifier.detectIllness(hrvZ: 0.5, rhrZ: -0.3))

        // Illness: low HRV + high RHR
        XCTAssertTrue(PhysiologyModifier.detectIllness(hrvZ: -2.5, rhrZ: 2.1))

        // Low HRV alone: not illness
        XCTAssertFalse(PhysiologyModifier.detectIllness(hrvZ: -2.5, rhrZ: 0.5))

        // High RHR alone: not illness
        XCTAssertFalse(PhysiologyModifier.detectIllness(hrvZ: 0.5, rhrZ: 2.5))
    }

    func testAdjustmentCalculation() {
        // High HRV, low RHR → positive adjustment
        let adjPositive = PhysiologyModifier.calculateAdjustment(
            hrvZ: 1.5,
            rhrZ: -1.5,
            previousAdjustment: 0
        )
        XCTAssertGreaterThan(adjPositive, 0)

        // Low HRV, high RHR → negative adjustment
        let adjNegative = PhysiologyModifier.calculateAdjustment(
            hrvZ: -1.5,
            rhrZ: 1.5,
            previousAdjustment: 0
        )
        XCTAssertLessThan(adjNegative, 0)

        // Adjustment should be clamped to ±12
        let adjExtreme = PhysiologyModifier.calculateAdjustment(
            hrvZ: 10,
            rhrZ: -10,
            previousAdjustment: 0
        )
        XCTAssertLessThanOrEqual(abs(adjExtreme), 12)
    }

    func testSmoothing() {
        // Large spike should be smoothed by previous adjustment
        let adj1 = PhysiologyModifier.calculateAdjustment(
            hrvZ: 2.0,
            rhrZ: -2.0,
            previousAdjustment: -5
        )

        // Should be weighted toward previous (-5), not raw calculation
        XCTAssertLessThan(adj1, 0)  // Still negative from previous
    }
}
