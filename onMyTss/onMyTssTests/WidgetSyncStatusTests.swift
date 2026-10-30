import Foundation
import SwiftData
import XCTest
@testable import onMyTss

@MainActor
final class WidgetSyncStatusTests: XCTestCase {
    func testPendingWidgetMessagePreservesSyncResultAndSurvivesReload() throws {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = DataStore(modelContext: container.mainContext)
        let state = try store.fetchAppState()
        let syncedAt = Date(timeIntervalSince1970: 1_780_000_000)
        state.lastHealthKitSyncDate = syncedAt
        state.lastSyncMessage = "Sync complete. Saved history remains available offline."
        try store.saveAppState(state)

        XCTAssertTrue(AppSyncRuntime.noteWidgetUpdatePending(store: store))
        XCTAssertTrue(AppSyncRuntime.noteWidgetUpdatePending(store: store))
        let reloaded = try DataStore(modelContext: ModelContext(container)).fetchAppState()
        XCTAssertEqual(reloaded.lastHealthKitSyncDate, syncedAt)
        XCTAssertEqual(reloaded.lastSyncMessage,
                       "Sync complete. Saved history remains available offline.\nWidget may not be up to date yet.")
    }

    func testPendingWidgetMessageKeepsExistingSourceWarning() throws {
        let schema = Schema(AppSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = DataStore(modelContext: container.mainContext)
        let state = try store.fetchAppState()
        state.lastSyncMessage = "Strava could not sync. Saved history is retained."
        try store.saveAppState(state)
        XCTAssertTrue(AppSyncRuntime.noteWidgetUpdatePending(store: store))
        XCTAssertEqual(try store.fetchAppState().lastSyncMessage,
                       "Strava could not sync. Saved history is retained.\nWidget may not be up to date yet.")
    }
}
