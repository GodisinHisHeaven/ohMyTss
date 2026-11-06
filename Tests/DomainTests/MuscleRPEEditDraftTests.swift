import XCTest
@testable import OhMyTssDomain

final class MuscleRPEEditDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testChangingEitherSideToBothStartsANewAdjustment() {
        for side in [BodySide.left, .right] {
            var draft = MuscleRPEEditDraft(side: side, rpe: 3, observedAt: now.addingTimeInterval(-86400))
            draft.rpe = 7
            draft.selectSide(.both, now: now)
            XCTAssertEqual(draft.side, .both)
            XCTAssertEqual(draft.rpe, 7)
            XCTAssertEqual(draft.observedAt, now)
            XCTAssertFalse(draft.hasSelectedDate)
        }
    }

    func testSwitchingOppositeSidesAndBackKeepsANewAdjustment() {
        var draft = MuscleRPEEditDraft(side: .left, rpe: 7, observedAt: now.addingTimeInterval(-86400))
        for (index, side) in [BodySide.right, .both, .left].enumerated() {
            let selectionTime = now.addingTimeInterval(Double(index))
            draft.selectSide(side, now: selectionTime)
            XCTAssertEqual(draft.side, side)
            XCTAssertEqual(draft.rpe, 7)
            XCTAssertEqual(draft.observedAt, selectionTime)
        }
    }

    func testEditingWithoutChangingSidePreservesOriginalDate() {
        let date = now.addingTimeInterval(-86400)
        var draft = MuscleRPEEditDraft(side: .left, rpe: 3, observedAt: date)
        draft.rpe = 7
        draft.selectSide(.left, now: now)
        XCTAssertEqual(draft.observedAt, date)
    }

    func testExplicitDateSurvivesEverySubsequentSideChange() {
        // Re-selecting the initial date is an explicit choice too.
        for date in [now.addingTimeInterval(-86400), now.addingTimeInterval(-2 * 86400)] {
            var draft = MuscleRPEEditDraft(side: .left, rpe: 7, observedAt: now.addingTimeInterval(-86400))
            draft.selectDate(date)
            for side in [BodySide.both, .right, .left] {
                draft.selectSide(side, now: now)
                XCTAssertEqual(draft.observedAt, date)
                XCTAssertTrue(draft.hasSelectedDate)
            }
        }
    }

    func testExplicitHistoricalDateAfterSideChangeIsPreserved() {
        var draft = MuscleRPEEditDraft(side: .right, rpe: 7, observedAt: now.addingTimeInterval(-86400))
        draft.selectSide(.both, now: now)
        let historicalDate = now.addingTimeInterval(-3 * 86400)
        draft.selectDate(historicalDate)
        draft.selectSide(.left, now: now.addingTimeInterval(10))
        XCTAssertEqual(draft.observedAt, historicalDate)
    }

    func testUnratedSideRemainsUnratedUntilGradeIsChosen() {
        var draft = MuscleRPEEditDraft(side: .left, rpe: nil, observedAt: now)
        draft.selectSide(.both, now: now)
        XCTAssertNil(draft.rpe)
    }
}
