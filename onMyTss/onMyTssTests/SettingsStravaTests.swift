import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class SettingsStravaTests: XCTestCase {
    func testSyncFailureDoesNotReportSuccessfulAuthorizationAsConnectionFailure() async throws {
        let container = try ModelContainer(for: StravaAuth.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        let auth = StubStravaConnection(store: store)
        let viewModel = SettingsViewModel(dataStore: store, engine: FailingSyncEngine(), stravaAuthManager: auth)

        await viewModel.connectStrava()

        XCTAssertTrue(viewModel.isStravaConnected)
        XCTAssertFalse(viewModel.isConnectingStrava)
        XCTAssertEqual(viewModel.successMessage, "Connected to Strava successfully")
        XCTAssertTrue(viewModel.errorMessage?.hasPrefix("Strava connected, but workout sync failed:") == true)
    }

    func testAuthorizationFailureDoesNotClaimConnectionSucceeded() async throws {
        let container = try ModelContainer(for: StravaAuth.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        let auth = StubStravaConnection(store: store, fails: true)
        let viewModel = SettingsViewModel(dataStore: store, engine: FailingSyncEngine(), stravaAuthManager: auth)

        await viewModel.connectStrava()

        XCTAssertFalse(viewModel.isStravaConnected)
        XCTAssertNil(viewModel.successMessage)
        XCTAssertTrue(viewModel.errorMessage?.hasPrefix("Failed to connect Strava:") == true)
    }
}

@MainActor
private final class StubStravaConnection: StravaConnectionManaging {
    let store: onMyTss.DataStore
    let fails: Bool

    init(store: onMyTss.DataStore, fails: Bool = false) {
        self.store = store
        self.fails = fails
    }

    func connectStrava() async throws {
        if fails { throw StravaOAuth.AuthorizationError.accessDenied }
        try store.saveStravaAuth(StravaAuth(athleteId: 42, hasAccessToken: true, hasRefreshToken: true, isConnected: true))
    }

    func disconnectStrava() async throws {}
}

@MainActor
private final class FailingSyncEngine: BodyBatteryEngineProtocol {
    func recomputeAll() async throws { throw URLError(.notConnectedToInternet) }
    func incrementalUpdate() async throws { throw URLError(.notConnectedToInternet) }
}
