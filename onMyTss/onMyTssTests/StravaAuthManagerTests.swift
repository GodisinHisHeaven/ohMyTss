import XCTest
import SwiftData
@testable import onMyTss

@MainActor
final class StravaAuthManagerTests: XCTestCase {
    func testValidStoredAccessTokenDoesNotRefresh() async throws {
        let store = try makeStore()
        let tokens = MemoryStravaTokens(access: "existing-access", refresh: "existing-refresh")
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in
            XCTFail("A valid token should not make a network request")
            throw URLError(.badServerResponse)
        }
        let token = try await manager.getValidAccessToken()
        XCTAssertEqual(token, "existing-access")
    }

    func testMissingAccessTokenIsRecoveredEvenBeforeRecordedExpiry() async throws {
        let store = try makeStore()
        let tokens = MemoryStravaTokens(access: nil, refresh: "existing-refresh")
        let response = refreshedTokens()
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { refresh in
            XCTAssertEqual(refresh, "existing-refresh")
            return response
        }

        let token = try await manager.getValidAccessToken()
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(tokens.refresh, "rotated-refresh")
        let auth = try XCTUnwrap(store.fetchStravaAuth())
        XCTAssertTrue(auth.isConnected)
        XCTAssertEqual(auth.accessTokenExpiresAt, response.expirationDate)
    }

    func testEmptyAccessTokenIsRecovered() async throws {
        let store = try makeStore()
        let tokens = MemoryStravaTokens(access: " ", refresh: "existing-refresh")
        let response = refreshedTokens()
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in response }
        let token = try await manager.getValidAccessToken()
        XCTAssertEqual(token, "new-access")
    }

    func testExpiredAccessTokenIsRefreshedAndRotated() async throws {
        let store = try makeStore(expiresAt: .distantPast)
        let tokens = MemoryStravaTokens(access: "expired-access", refresh: "existing-refresh")
        let response = refreshedTokens()
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in response }
        let token = try await manager.getValidAccessToken()
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(tokens.refresh, "rotated-refresh")
    }

    func testMissingRefreshTokenRequiresReconnection() async throws {
        for refresh in [nil, ""] as [String?] {
            let store = try makeStore()
            let tokens = MemoryStravaTokens(access: nil, refresh: refresh)
            let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in
                XCTFail("Missing credentials must not be sent to Strava")
                throw URLError(.badServerResponse)
            }
            do {
                _ = try await manager.getValidAccessToken()
                XCTFail("Expected a reconnect error")
            } catch StravaAPI.StravaAPIError.unauthorized {
                let auth = try XCTUnwrap(store.fetchStravaAuth())
                XCTAssertFalse(auth.isConnected)
                XCTAssertFalse(auth.hasAccessToken)
                XCTAssertFalse(auth.hasRefreshToken)
            }
        }
    }

    func testTemporarilyLockedKeychainDoesNotDisconnect() async throws {
        let store = try makeStore()
        let tokens = MemoryStravaTokens(access: "existing-access", refresh: "existing-refresh")
        tokens.accessError = .unexpectedStatus(-25308)
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in
            XCTFail("A temporarily inaccessible keychain should not trigger token rotation")
            throw URLError(.badServerResponse)
        }
        do {
            _ = try await manager.getValidAccessToken()
            XCTFail("Expected keychain error")
        } catch KeychainHelper.KeychainError.unexpectedStatus {
            XCTAssertTrue(try XCTUnwrap(store.fetchStravaAuth()).isConnected)
            XCTAssertEqual(tokens.refresh, "existing-refresh")
        }
    }

    func testNetworkFailureKeepsConnectionAndRefreshTokenForRetry() async throws {
        let store = try makeStore(expiresAt: .distantPast)
        let tokens = MemoryStravaTokens(access: "expired-access", refresh: "existing-refresh")
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await manager.getValidAccessToken()
            XCTFail("Expected network error")
        } catch is URLError {
            XCTAssertTrue(try XCTUnwrap(store.fetchStravaAuth()).isConnected)
            XCTAssertEqual(tokens.refresh, "existing-refresh")
        }
    }

    func testRevokedRefreshTokenRequiresReconnection() async throws {
        let store = try makeStore(expiresAt: .distantPast)
        let tokens = MemoryStravaTokens(access: "expired-access", refresh: "revoked-refresh")
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in
            throw StravaAPI.StravaAPIError.unauthorized
        }
        do {
            _ = try await manager.getValidAccessToken()
            XCTFail("Expected authorization error")
        } catch StravaAPI.StravaAPIError.unauthorized {
            XCTAssertFalse(try XCTUnwrap(store.fetchStravaAuth()).isConnected)
        }
    }

    func testEmptyTokenResponseDoesNotOverwriteSavedTokens() async throws {
        let store = try makeStore(expiresAt: .distantPast)
        let tokens = MemoryStravaTokens(access: "expired-access", refresh: "existing-refresh")
        let invalidResponse = refreshedTokens(accessToken: "")
        let manager = StravaAuthManager(dataStore: store, tokenStore: tokens) { _ in invalidResponse }
        do {
            _ = try await manager.getValidAccessToken()
            XCTFail("Expected an invalid response error")
        } catch StravaAPI.StravaAPIError.invalidResponse {
            XCTAssertEqual(tokens.access, "expired-access")
            XCTAssertEqual(tokens.refresh, "existing-refresh")
        }
    }

    private func makeStore(expiresAt: Date = Date().addingTimeInterval(3600)) throws -> onMyTss.DataStore {
        let container = try ModelContainer(for: StravaAuth.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = DataStore(modelContainer: container)
        try store.saveStravaAuth(StravaAuth(
            athleteId: 42,
            hasAccessToken: true,
            hasRefreshToken: true,
            accessTokenExpiresAt: expiresAt,
            isConnected: true
        ))
        return store
    }

    private func refreshedTokens(accessToken: String = "new-access") -> TokenResponse {
        TokenResponse(tokenType: "Bearer", expiresAt: Int(Date().addingTimeInterval(21600).timeIntervalSince1970),
                      expiresIn: 21600, refreshToken: "rotated-refresh", accessToken: accessToken, athlete: nil)
    }
}

@MainActor
private final class MemoryStravaTokens: StravaTokenStoring {
    var access: String?
    var refresh: String?
    var accessError: KeychainHelper.KeychainError?

    init(access: String?, refresh: String?) {
        self.access = access
        self.refresh = refresh
    }

    func accessToken() throws -> String {
        if let accessError { throw accessError }
        guard let access else { throw KeychainHelper.KeychainError.itemNotFound }
        return access
    }

    func refreshToken() throws -> String {
        guard let refresh else { throw KeychainHelper.KeychainError.itemNotFound }
        return refresh
    }

    func save(accessToken: String, refreshToken: String) throws {
        access = accessToken
        refresh = refreshToken
    }

    func deleteTokens() throws {
        access = nil
        refresh = nil
    }
}
