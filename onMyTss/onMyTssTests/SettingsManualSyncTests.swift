import Foundation
import SwiftData
import XCTest
@testable import onMyTss

@MainActor
final class SettingsManualSyncTests: XCTestCase {
    func testManualSyncShowsPersistedSourceAndWidgetWarningsWithoutLosingSettings() async throws {
        let container = try makeContainer()
        let store = DataStore(modelContainer: container)
        let thresholds = try store.fetchUserThresholds()
        thresholds.cyclingFTP = 240
        try store.saveUserThresholds(thresholds)
        let completedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let message = "Strava could not sync. Saved history is retained.\nWidget may not be up to date yet."
        let engine = ManualSyncEngine {
            let state = try store.fetchAppState()
            state.lastHealthKitSyncDate = completedAt
            state.lastSyncMessage = message
            try store.saveAppState(state)
        }
        let viewModel = SettingsViewModel(dataStore: store, engine: engine)

        await viewModel.syncData()

        XCTAssertEqual(viewModel.successMessage, message)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.lastSyncDate, completedAt)
        XCTAssertEqual(try store.fetchUserThresholds().cyclingFTP, 240)
        XCTAssertFalse(viewModel.isSaving)
    }

    func testManualSyncUsesFallbackWhenNoStatusIsAvailable() async throws {
        for message in [nil, " \n "] as [String?] {
            let container = try makeContainer()
            let store = DataStore(modelContainer: container)
            let engine = ManualSyncEngine {
                let state = try store.fetchAppState()
                state.lastSyncMessage = message
                try store.saveAppState(state)
            }
            let viewModel = SettingsViewModel(dataStore: store, engine: engine)

            await viewModel.syncData()

            XCTAssertEqual(viewModel.successMessage, "Data synced successfully")
            XCTAssertNil(viewModel.errorMessage)
        }
    }

    func testManualSyncFailureDoesNotShowAnEarlierSuccess() async throws {
        let container = try makeContainer()
        let store = DataStore(modelContainer: container)
        let state = try store.fetchAppState()
        state.lastSyncMessage = "An earlier sync succeeded."
        try store.saveAppState(state)
        let viewModel = SettingsViewModel(dataStore: store, engine: ManualSyncEngine {
            throw URLError(.notConnectedToInternet)
        })

        await viewModel.syncData()

        XCTAssertNil(viewModel.successMessage)
        XCTAssertTrue(viewModel.errorMessage?.hasPrefix("Sync failed:") == true)
        XCTAssertFalse(viewModel.isSaving)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}

@MainActor
private final class ManualSyncEngine: BodyBatteryEngineProtocol {
    private let work: () throws -> Void

    init(work: @escaping () throws -> Void) { self.work = work }
    func recomputeAll() async throws { try work() }
    func incrementalUpdate() async throws { try work() }
}
