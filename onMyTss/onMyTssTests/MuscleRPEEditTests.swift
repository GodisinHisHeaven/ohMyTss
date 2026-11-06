import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class MuscleRPEEditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testOlderLeftAndOlderRightToBothPersistAndDisplayBothNewRatings() throws {
        for olderSide in [BodySide.left, .right] {
            try verifyBothEdit(olderSide: olderSide, sameDate: false)
        }
    }

    func testSameDateSidesToBothPersistAndDisplayBothNewRatings() throws {
        for side in [BodySide.left, .right] {
            try verifyBothEdit(olderSide: side, sameDate: true)
        }
    }

    private func verifyBothEdit(olderSide: BodySide, sameDate: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("synthetic-rpe.store"))
        func write() throws {
            let container = try ModelContainer(for: Schema(AppSchema.models), configurations: config)
            let context = ModelContext(container)
            let store = MuscleRPEStore(context: context, clock: { self.now })
            let older = try store.save(region: .quads, side: olderSide, rpe: 3,
                                       observedAt: now.addingTimeInterval(-86400))
            _ = try store.save(region: .quads, side: olderSide == .left ? .right : .left, rpe: 4,
                               observedAt: sameDate ? older.observedAt : now.addingTimeInterval(-3600))
            var draft = MuscleRPEEditDraft(side: olderSide, rpe: older.rpe, observedAt: older.observedAt)
            draft.selectSide(.both, now: now)
            draft.rpe = 7
            let saved = try store.save(region: .quads, side: draft.side,
                                       rpe: XCTUnwrap(draft.rpe), observedAt: draft.observedAt)
            XCTAssertEqual(saved.observedAt, now)
            XCTAssertEqual(saved.sideRaw, "both")
        }
        try write()
        let reopened = try ModelContainer(for: Schema(AppSchema.models), configurations: config)
        let records = try ModelContext(reopened).fetch(FetchDescriptor<MuscleRPERecord>())
        XCTAssertEqual(records.count, 3, "Keep the two original historical observations")
        let summary = MuscleRPESummary(records: records, now: now)
        for side in [BodySide.left, .right] {
            XCTAssertEqual(summary.reading(.quads, side: side)?.rpe, 7)
            XCTAssertEqual(summary.reading(.quads, side: side)?.observedAt, now)
        }
    }

    func testSwitchToOppositeSideOnlyUpdatesThatSide() throws {
        for side in [BodySide.left, .right] {
            let container = try memoryContainer()
            let context = ModelContext(container)
            let store = MuscleRPEStore(context: context, clock: { self.now })
            let old = try store.save(region: .quads, side: side, rpe: 3, observedAt: now.addingTimeInterval(-86400))
            let opposite: BodySide = side == .left ? .right : .left
            _ = try store.save(region: .quads, side: opposite, rpe: 4, observedAt: now.addingTimeInterval(-3600))
            var draft = MuscleRPEEditDraft(side: side, rpe: old.rpe, observedAt: old.observedAt)
            draft.rpe = 7
            draft.selectSide(opposite, now: now)
            try store.save(region: .quads, side: draft.side, rpe: XCTUnwrap(draft.rpe), observedAt: draft.observedAt)
            let summary = MuscleRPESummary(records: try context.fetch(FetchDescriptor<MuscleRPERecord>()), now: now)
            XCTAssertEqual(summary.reading(.quads, side: side)?.rpe, 3)
            XCTAssertEqual(summary.reading(.quads, side: side)?.observedAt, old.observedAt)
            XCTAssertEqual(summary.reading(.quads, side: opposite)?.rpe, 7)
            XCTAssertEqual(summary.reading(.quads, side: opposite)?.observedAt, now)
        }
    }

    func testExplicitHistoryBeforeOrAfterSideChangeKeepsNewerSummary() throws {
        for selectDateFirst in [true, false] {
            let container = try memoryContainer()
            let context = ModelContext(container)
            var store = MuscleRPEStore(context: context, clock: { self.now.addingTimeInterval(-60) })
            let historicalDate = now.addingTimeInterval(-86400)
            _ = try store.save(region: .quads, side: .left, rpe: 3, observedAt: historicalDate)
            _ = try store.save(region: .quads, side: .right, rpe: 4, observedAt: now.addingTimeInterval(-3600))
            store.clock = { self.now }
            var draft = MuscleRPEEditDraft(side: .left, rpe: 7, observedAt: historicalDate)
            if selectDateFirst { draft.selectDate(historicalDate) }
            draft.selectSide(.both, now: now)
            if !selectDateFirst { draft.selectDate(historicalDate) }
            let saved = try store.save(region: .quads, side: draft.side, rpe: XCTUnwrap(draft.rpe), observedAt: draft.observedAt)
            XCTAssertEqual(saved.observedAt, historicalDate)
            let summary = MuscleRPESummary(records: try context.fetch(FetchDescriptor<MuscleRPERecord>()), now: now)
            XCTAssertEqual(summary.reading(.quads, side: .left)?.rpe, 7)
            XCTAssertEqual(summary.reading(.quads, side: .right)?.rpe, 4)
        }
    }

    func testDiscardingDraftDoesNotChangePersistedRatings() throws {
        let container = try memoryContainer()
        let context = ModelContext(container)
        let store = MuscleRPEStore(context: context, clock: { self.now })
        let date = now.addingTimeInterval(-86400)
        let original = try store.save(region: .quads, side: .left, rpe: 3, observedAt: date)
        var draft = MuscleRPEEditDraft(side: .left, rpe: original.rpe, observedAt: original.observedAt)
        draft.selectSide(.both, now: now)
        draft.selectDate(now.addingTimeInterval(-2 * 86400))
        draft.rpe = 7
        // Cancel dismisses the draft without invoking the store.
        let records = try ModelContext(container).fetch(FetchDescriptor<MuscleRPERecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sideRaw, "left")
        XCTAssertEqual(records.first?.rpe, 3)
        XCTAssertEqual(records.first?.observedAt, date)
        XCTAssertFalse(context.hasChanges)
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
