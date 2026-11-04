import XCTest
@testable import onMyTss

@MainActor
final class RegionDetailEstimateSelectionTests: XCTestCase {
    func testUsesNewestRecordForEachRequestedWorkoutWithoutFallingBackFromInvalidData() {
        func record(_ session: String, _ time: TimeInterval, _ payload: String) -> LoadEstimateRecord {
            let date = Date(timeIntervalSince1970: time)
            return LoadEstimateRecord(sessionID: session, version: "test", inputCutoff: date,
                                      computedAt: date, payloadData: Data(payload.utf8), inputData: Data())
        }
        let unrelated = record("other", 50, "{}")
        let newest = record("a", 40, "invalid")
        let newestB = record("b", 30, "{}")
        let older = record("a", 20, "{}")
        let olderB = record("b", 10, "{}")
        let ordered = [unrelated, newest, newestB, older, olderB]

        let selected = RegionDetailView.latestEstimates(for: ["a", "b", "missing"], in: ordered)
        XCTAssertTrue(selected["a"] === newest)
        XCTAssertNil(selected["a"]?.value)
        XCTAssertTrue(selected["b"] === newestB)
        XCTAssertNil(selected["missing"])
        XCTAssertNil(selected["other"])
        XCTAssertTrue(RegionDetailView.latestEstimates(for: [], in: ordered).isEmpty)
    }
}
