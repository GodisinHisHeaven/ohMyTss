import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class V2StoreBatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let schema = Schema(AppSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func set(_ sessionID: String, reps: Int = 8) -> StrengthSetRecord {
        StrengthSetRecord(sessionID: sessionID, exerciseID: "squat", reps: reps, weightKG: 40, rir: 2)
    }

    func testTwentySetsPersistInOneSessionAndOneNewEstimate() throws {
        let context = try makeContext()
        let store = V2Store(context: context)
        let session = try store.createStrengthSession(start: start, duration: 600)
        session.userTags = ["retained"]
        let before = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        let records = (1...20).map { set(session.id, reps: $0) }

        try store.saveSets(records)

        let saved = try context.fetch(FetchDescriptor<StrengthSetRecord>())
        XCTAssertEqual(saved.count, 20)
        XCTAssertEqual(Set(saved.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(saved.map(\.reps).sorted(), Array(1...20))
        XCTAssertTrue(saved.allSatisfy { $0.sessionID == session.id && $0.weightKG == 40 && $0.rir == 2 })
        XCTAssertEqual(session.userTags, ["retained"])
        let estimates = try context.fetch(FetchDescriptor<LoadEstimateRecord>())
        XCTAssertEqual(estimates.count, before.count + 1)
        let previousIDs = Set(before.map(\.id))
        let newest = try XCTUnwrap(estimates.first { $0.sessionID == session.id && !previousIDs.contains($0.id) })
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: newest.inputData) as? [String: Any])
        XCTAssertEqual((input["sets"] as? [[String: Any]])?.count, 20)
    }

    func testCrossSessionAndInvalidInputsRejectWholeBatchWithoutRollingBackPendingChanges() throws {
        let context = try makeContext()
        let store = V2Store(context: context)
        let first = try store.createStrengthSession(start: start, duration: 600)
        let second = try store.createStrengthSession(start: start, duration: 600)
        let deleted = try store.createStrengthSession(start: start, duration: 600)
        let suppressed = try store.createStrengthSession(start: start, duration: 600)
        deleted.isTombstoned = true
        suppressed.isSuppressed = true
        try context.save()
        let before = try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count
        first.userTags = ["pending"]

        func assertRejected(_ rows: [StrengthSetRecord], expected: V2StoreError, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertThrowsError(try store.saveSets(rows), file: file, line: line) { error in
                XCTAssertEqual(error as? V2StoreError, expected, file: file, line: line)
            }
            XCTAssertTrue(try context.fetch(FetchDescriptor<StrengthSetRecord>()).isEmpty, file: file, line: line)
            XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, before, file: file, line: line)
            XCTAssertEqual(first.userTags, ["pending"], file: file, line: line)
            XCTAssertTrue(context.hasChanges, file: file, line: line)
        }

        try assertRejected([set(first.id), set(second.id)], expected: .invalidSession)
        // The entire batch is validated before the cross-session check.
        try assertRejected([set(first.id), set(second.id), set(first.id, reps: 0)], expected: .invalidSet)
        try assertRejected([set(first.id), set(first.id, reps: 0)], expected: .invalidSet)
        try assertRejected([set(first.id), set("missing")], expected: .invalidSet)
        try assertRejected([set(first.id), set(deleted.id)], expected: .invalidSet)
        try assertRejected([set(first.id), set(suppressed.id)], expected: .invalidSet)
    }

    func testPendingSessionInsertAndUnsavedInactiveChanges() throws {
        let context = try makeContext()
        let store = V2Store(context: context)
        let session = Workout(id: "pending-session", date: start, startTime: start,
                              duration: 600, workoutType: "Strength", tss: 0,
                              calculationMethod: "unknown", source: .manual)
        context.insert(session)
        XCTAssertTrue(context.hasChanges)
        try store.saveSets([set(session.id), set(session.id, reps: 9)])
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 2)
        let estimatesBefore = try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count

        session.isSuppressed = true
        XCTAssertThrowsError(try store.saveSets([set(session.id), set(session.id)])) { error in
            XCTAssertEqual(error as? V2StoreError, .invalidSet)
        }
        XCTAssertTrue(session.isSuppressed)
        XCTAssertTrue(context.hasChanges)

        session.isSuppressed = false
        session.isTombstoned = true
        XCTAssertThrowsError(try store.saveSets([set(session.id), set(session.id)])) { error in
            XCTAssertEqual(error as? V2StoreError, .invalidSet)
        }
        XCTAssertTrue(session.isTombstoned)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StrengthSetRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LoadEstimateRecord>()).count, estimatesBefore)
    }
}
