import XCTest
@testable import onMyTss

@MainActor
final class BodyMapReportsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func report(side: String, kind: String = "soreness", age: TimeInterval = 60) -> LocalObservation {
        LocalObservation(regionRaw: "quads", sideRaw: side, discomfortRaw: kind,
                         severity: kind == "none" ? 0 : 2, observedAt: now.addingTimeInterval(-age))
    }

    func testMissingReportDoesNotMeanNoDiscomfort() {
        let reports = BodyMapReports(observations: [report(side: "left", kind: "none")], now: now)
        XCTAssertEqual(reports.status(.quads, side: .left), .noDiscomfort)
        XCTAssertEqual(reports.status(.quads, side: .right), .unreported)
        XCTAssertEqual(reports.status(.hamstrings, side: .left), .unreported)
    }

    func testRightSideClearDoesNotEraseLeftDiscomfort() {
        let left = report(side: "left", age: 120)
        let right = report(side: "right", kind: "none")
        let reports = BodyMapReports(observations: [right, left], now: now)
        XCTAssertEqual(reports.status(.quads, side: .left), .discomfort)
        XCTAssertEqual(reports.status(.quads, side: .right), .noDiscomfort)
        XCTAssertEqual(reports.report(.quads, side: .left)?.id, left.id)
    }

    func testNewerSingleSideOverridesOnlyThatHalfOfBoth() {
        let both = report(side: "both", age: 120)
        let left = report(side: "left", kind: "none")
        let reports = BodyMapReports(observations: [both, left], now: now)
        XCTAssertEqual(reports.status(.quads, side: .left), .noDiscomfort)
        XCTAssertEqual(reports.status(.quads, side: .right), .discomfort)

        let newerBoth = report(side: "both", kind: "none", age: 0)
        let refreshed = BodyMapReports(observations: [left, newerBoth, both], now: now)
        XCTAssertEqual(refreshed.status(.quads, side: .left), .noDiscomfort)
        XCTAssertEqual(refreshed.status(.quads, side: .right), .noDiscomfort)
    }

    func testWindowUsesObservedTimeAndExcludesFutureReports() {
        let old = report(side: "left", age: 8 * 86_400)
        old.recordedAt = now
        let future = report(side: "right", kind: "none", age: -60)
        let reports = BodyMapReports(observations: [old, future], now: now, calendar: calendar)
        XCTAssertEqual(reports.status(.quads, side: .left), .unreported)
        XCTAssertEqual(reports.status(.quads, side: .right), .unreported)

        let boundary = report(side: "left", age: 7 * 86_400)
        XCTAssertEqual(BodyMapReports(observations: [boundary], now: now, calendar: calendar)
            .status(.quads, side: .left), .discomfort)
    }

    func testUnspecifiedSideIsNeverPaintedOntoEitherSide() {
        let reports = BodyMapReports(observations: [report(side: "unspecified")], now: now)
        XCTAssertEqual(reports.status(.quads, side: .left), .unreported)
        XCTAssertEqual(reports.status(.quads, side: .right), .unreported)
        XCTAssertEqual(reports.unspecifiedRegions, [.quads])
    }

    func testMostRecentlyEditedReportBreaksObservedTimeTie() {
        let previous = report(side: "left")
        previous.updatedAt = now.addingTimeInterval(-30)
        let edited = report(side: "left", kind: "none")
        edited.updatedAt = now
        let reports = BodyMapReports(observations: [previous, edited], now: now)
        XCTAssertEqual(reports.report(.quads, side: .left)?.id, edited.id)
        XCTAssertEqual(reports.status(.quads, side: .left), .noDiscomfort)
    }
}
