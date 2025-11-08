import XCTest
@testable import TSSEngine

final class TSSCalculatorTests: XCTestCase {

    func testCyclingTSS() {
        // 1 hour at FTP = 100 TSS
        let powerSamples = Array(repeating: 250.0, count: 3600)  // 1 hour at 250W
        let tss = TSSCalculator.cyclingTSS(powerSamples: powerSamples, duration: 3600, ftp: 250)

        XCTAssertNotNil(tss)
        XCTAssertEqual(tss!, 100, accuracy: 5)
    }

    func testRunningTSS() {
        // 10km in 50 minutes at threshold pace (5:00/km = 300 sec/km)
        let distance = 10000.0  // meters
        let duration = 3000.0   // seconds (50 minutes)
        let thresholdPace = 300.0 / 1000.0  // sec/meter

        let tss = TSSCalculator.runningTSS(distance: distance, duration: duration, thresholdPace: thresholdPace)

        // 50 minutes at threshold = ~83 TSS
        XCTAssertEqual(tss, 83, accuracy: 10)
    }

    func testSwimmingTSS() {
        // 2km in 40 minutes
        let distance = 2000.0
        let duration = 2400.0  // 40 minutes
        let cssPace = 90.0 / 1000.0  // 1:30/100m = 90 sec/100m

        let tss = TSSCalculator.swimmingTSS(distance: distance, duration: duration, cssPace: cssPace)

        XCTAssertGreaterThan(tss, 0)
    }

    func testHeartRateTSS() {
        // 60 minutes at 85% of max HR
        let tss = TSSCalculator.heartRateTSS(
            avgHR: 160,
            duration: 3600,
            thresholdHR: 170,
            restingHR: 50
        )

        XCTAssertGreaterThan(tss, 50)
        XCTAssertLessThan(tss, 150)
    }

    func testEdgeCases() {
        // Zero power samples
        XCTAssertNil(TSSCalculator.cyclingTSS(powerSamples: [], duration: 3600, ftp: 250))

        // Zero FTP
        XCTAssertNil(TSSCalculator.cyclingTSS(powerSamples: [200], duration: 3600, ftp: 0))

        // Zero distance
        XCTAssertEqual(TSSCalculator.runningTSS(distance: 0, duration: 3600, thresholdPace: 300), 0)
    }
}
