import XCTest
@testable import onMyTss

final class WorkoutLinkGraphTests: XCTestCase {
    func testIncludesTransitiveAliasesWithoutCrossingToIndependentSources() {
        let links: [WorkoutLinkGraph.Link] = [
            .init(id: "garmin", parentID: nil),
            .init(id: "strava", parentID: "garmin"),
            // A manually linked child or a source-deleted alias keeps its own ID.
            .init(id: "manual", parentID: "strava"),
            .init(id: "deleted-source", parentID: "garmin"),
            .init(id: "unrelated", parentID: nil),
            .init(id: "unrelated-child", parentID: "unrelated")
        ]
        let graph = WorkoutLinkGraph(links)
        XCTAssertEqual(graph.relatedIDs(to: "garmin"), ["garmin", "strava", "manual", "deleted-source"])
        XCTAssertEqual(graph.relatedIDs(to: "unrelated"), ["unrelated", "unrelated-child"])
    }

    func testSourceCorrectionSplitsProjectionWithoutMovingOriginalRecords() {
        let grouped = WorkoutLinkGraph([.init(id: "garmin", parentID: nil),
                                        .init(id: "strava", parentID: "garmin"),
                                        .init(id: "manual", parentID: "strava")])
        let corrected = WorkoutLinkGraph([.init(id: "garmin", parentID: nil),
                                          .init(id: "strava", parentID: nil),
                                          .init(id: "manual", parentID: "strava")])
        XCTAssertEqual(grouped.relatedIDs(to: "garmin"), ["garmin", "strava", "manual"])
        XCTAssertEqual(corrected.relatedIDs(to: "garmin"), ["garmin"])
        XCTAssertEqual(corrected.relatedIDs(to: "strava"), ["strava", "manual"])
    }

    func testCyclesAndMissingParentsCannotHangOrLeakOtherGroups() {
        let graph = WorkoutLinkGraph([.init(id: "a", parentID: "b"), .init(id: "b", parentID: "a"),
                                      .init(id: "self", parentID: "self"),
                                      .init(id: "orphan", parentID: "missing")])
        XCTAssertEqual(graph.relatedIDs(to: "a"), ["a", "b"])
        XCTAssertEqual(graph.relatedIDs(to: "self"), ["self"])
        XCTAssertEqual(graph.relatedIDs(to: "orphan"), ["orphan"])
        XCTAssertEqual(graph.relatedIDs(to: "unknown"), ["unknown"])
    }
}
