import XCTest
@testable import TSSEngine

final class LoadCalculatorTests: XCTestCase {

    func testCTLATLProgression() {
        var state = LoadCalculator.DayState(ctl: 50, atl: 50)

        // Day 1: 100 TSS (hard workout)
        state = LoadCalculator.updateLoad(previous: state, dailyTSS: 100)

        // CTL should increase slowly (42-day time constant)
        XCTAssertEqual(state.ctl, 50 + LoadCalculator.CTL_DECAY * (100 - 50), accuracy: 0.01)

        // ATL should increase faster (7-day time constant)
        XCTAssertEqual(state.atl, 50 + LoadCalculator.ATL_DECAY * (100 - 50), accuracy: 0.01)

        // TSB should be negative (fatigued)
        XCTAssertLessThan(state.tsb, 0)
    }

    func testConstantLoad() {
        var state = LoadCalculator.DayState(ctl: 0, atl: 0)

        // Apply constant 80 TSS for 42 days
        for _ in 0..<42 {
            state = LoadCalculator.updateLoad(previous: state, dailyTSS: 80)
        }

        // CTL should converge to 80
        XCTAssertEqual(state.ctl, 80, accuracy: 5)

        // ATL should also converge to 80 (faster)
        XCTAssertEqual(state.atl, 80, accuracy: 1)

        // TSB should be near 0 (balanced)
        XCTAssertEqual(state.tsb, 0, accuracy: 5)
    }

    func testRecoveryWeek() {
        // Start with steady state
        var state = LoadCalculator.DayState(ctl: 80, atl: 80)

        // Recovery week: 7 days of 40 TSS
        for _ in 0..<7 {
            state = LoadCalculator.updateLoad(previous: state, dailyTSS: 40)
        }

        // TSB should be positive (fresh)
        XCTAssertGreaterThan(state.tsb, 0)

        // ATL drops faster than CTL
        XCTAssertLessThan(state.atl, state.ctl)
    }

    func testInitializeLoad() {
        let recentWorkouts = [
            (date: Date(), tss: 80.0),
            (date: Date(), tss: 90.0),
            (date: Date(), tss: 70.0),
            (date: Date(), tss: 100.0),
            (date: Date(), tss: 60.0),
            (date: Date(), tss: 85.0),
            (date: Date(), tss: 75.0)
        ]

        let state = LoadCalculator.initializeLoad(recentWorkouts: recentWorkouts)

        // Should seed with average of last 7 days
        let expectedAvg = 560.0 / 7.0  // ≈ 80
        XCTAssertEqual(state.ctl, expectedAvg, accuracy: 0.1)
        XCTAssertEqual(state.atl, expectedAvg, accuracy: 0.1)
        XCTAssertEqual(state.tsb, 0, accuracy: 0.1)
    }
}
