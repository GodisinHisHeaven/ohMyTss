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

    @MainActor
    func testDetailProjectionReflectsCorrectionsAndDeletionOrigins() {
        func workout(_ id: String, parent: String? = nil) -> Workout {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let value = Workout(id: id, date: date, startTime: date, duration: 600,
                                workoutType: "Ride", tss: 10, calculationMethod: "duration", source: .healthKit)
            value.linkedSessionID = parent
            value.userTags = ["tag-\(id)"]
            return value
        }

        let canonical = workout("garmin")
        let alias = workout("strava", parent: canonical.id)
        let manual = workout("manual", parent: alias.id)
        let sourceDeleted = workout("source-deleted", parent: canonical.id)
        sourceDeleted.isTombstoned = true
        sourceDeleted.deletionOrigin = "source"
        let userDeleted = workout("user-deleted", parent: canonical.id)
        userDeleted.isTombstoned = true
        userDeleted.deletionOrigin = "user"
        let userDeletedChild = workout("user-deleted-child", parent: userDeleted.id)
        let unrelated = (0..<1_000).map { workout("unrelated-\($0)") }
        let workouts = unrelated + [userDeletedChild, sourceDeleted, manual, alias, canonical, userDeleted]

        let grouped = V2ActivityDetailProjection.linkedSources(for: canonical, in: workouts)
        XCTAssertEqual(grouped.map(\.id), ["manual", "source-deleted", "strava"])
        XCTAssertEqual(grouped.map(\.userTags), [["tag-manual"], ["tag-source-deleted"], ["tag-strava"]])

        alias.linkedSessionID = nil
        XCTAssertEqual(V2ActivityDetailProjection.linkedSources(for: canonical, in: workouts).map(\.id), ["source-deleted"])
        XCTAssertEqual(V2ActivityDetailProjection.linkedSources(for: alias, in: workouts).map(\.id), ["manual"])

        sourceDeleted.deletionOrigin = "user"
        XCTAssertTrue(V2ActivityDetailProjection.linkedSources(for: canonical, in: workouts).isEmpty)
        canonical.isSuppressed = true
        alias.linkedSessionID = canonical.id
        XCTAssertTrue(V2ActivityDetailProjection.linkedSources(for: canonical, in: workouts).isEmpty)
        canonical.isSuppressed = false
        canonical.isTombstoned = true
        XCTAssertTrue(V2ActivityDetailProjection.linkedSources(for: canonical, in: workouts).isEmpty)
    }
}
