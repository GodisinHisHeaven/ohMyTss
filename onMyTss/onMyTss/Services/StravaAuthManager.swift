//
//  StravaAuthManager.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData
import AuthenticationServices
import Combine

@MainActor
protocol StravaConnectionManaging {
    func connectStrava() async throws
    func disconnectStrava() async throws
}

/// Manages Strava OAuth flow and token lifecycle
/// Coordinates between StravaAPI, Keychain, and SwiftData
@MainActor
final class StravaAuthManager: NSObject, ObservableObject, StravaConnectionManaging {

    // MARK: - Dependencies

    private let dataStore: DataStore
    private let tokenStore: any StravaTokenStoring
    private let tokenRefresher: (String) async throws -> TokenResponse

    // MARK: - State

    @Published var isAuthenticating: Bool = false
    @Published var authError: String?

    // OAuth session
    private var authSession: ASWebAuthenticationSession?

    // MARK: - Initialization

    convenience init(dataStore: DataStore) {
        self.init(dataStore: dataStore, tokenStore: KeychainStravaTokenStore())
    }

    init(
        dataStore: DataStore,
        tokenStore: any StravaTokenStoring,
        tokenRefresher: @escaping (String) async throws -> TokenResponse = { try await StravaAPI.refreshToken($0) }
    ) {
        self.dataStore = dataStore
        self.tokenStore = tokenStore
        self.tokenRefresher = tokenRefresher
    }

    // MARK: - Connection

    /// Initiate Strava OAuth flow
    func connectStrava() async throws {
        isAuthenticating = true
        authError = nil
        defer {
            isAuthenticating = false
            authSession = nil
        }

        do {
            let state = UUID().uuidString
            let authURL = try StravaAPI.getAuthorizationURL(state: state)
            let callbackURL = try await authenticate(with: authURL)
            try await handleCallback(url: callbackURL, expectedState: state)
        } catch {
            authError = error.localizedDescription
            throw error
        }
    }

    /// Disconnect Strava (revoke tokens and clear data)
    func disconnectStrava() async throws {
        // Clear tokens from keychain
        try tokenStore.deleteTokens()

        // Clear auth state from database
        if let auth = try dataStore.fetchStravaAuth() {
            try dataStore.deleteStravaAuth(auth)
        }

        // Note: We keep Workout records for audit trail
        // but mark them as suppressed if needed
    }

    // MARK: - Token Management

    /// Get valid access token (refreshing if needed)
    func getValidAccessToken() async throws -> String {
        guard let auth = try dataStore.fetchStravaAuth(),
              auth.isConnected else {
            throw StravaAPI.StravaAPIError.unauthorized
        }

        if !auth.needsTokenRefresh {
            do {
                let token = try tokenStore.accessToken()
                if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return token
                }
            } catch KeychainHelper.KeychainError.itemNotFound {
                // Database state can outlive a keychain token. Recover with the refresh token.
            } catch KeychainHelper.KeychainError.invalidData {
                // An unreadable stored token also needs replacement.
            }
        }

        try await refreshAccessToken()
        return try tokenStore.accessToken()
    }

    /// Refresh access token using refresh token
    private func refreshAccessToken() async throws {
        let refreshToken: String
        do {
            refreshToken = try tokenStore.refreshToken()
            guard !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeychainHelper.KeychainError.invalidData
            }
        } catch KeychainHelper.KeychainError.itemNotFound {
            try requireReconnection()
            throw StravaAPI.StravaAPIError.unauthorized
        } catch KeychainHelper.KeychainError.invalidData {
            try requireReconnection()
            throw StravaAPI.StravaAPIError.unauthorized
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try await tokenRefresher(refreshToken)
        } catch StravaAPI.StravaAPIError.unauthorized {
            try requireReconnection()
            throw StravaAPI.StravaAPIError.unauthorized
        }
        try saveTokens(tokenResponse)

        // Update auth state
        guard let auth = try dataStore.fetchStravaAuth() else {
            throw StravaAPI.StravaAPIError.unauthorized
        }

        auth.hasAccessToken = true
        auth.hasRefreshToken = true
        auth.accessTokenExpiresAt = tokenResponse.expirationDate

        try dataStore.updateStravaAuth(auth)
    }

    private func requireReconnection() throws {
        guard let auth = try dataStore.fetchStravaAuth() else { return }
        auth.isConnected = false
        auth.hasAccessToken = false
        auth.hasRefreshToken = false
        try dataStore.updateStravaAuth(auth)
    }

    private func saveTokens(_ response: TokenResponse) throws {
        guard !response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StravaAPI.StravaAPIError.invalidResponse
        }
        try tokenStore.save(accessToken: response.accessToken, refreshToken: response.refreshToken)
    }

    // MARK: - Private Helpers

    /// Present ASWebAuthenticationSession for OAuth
    private func authenticate(with url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: StravaOAuth.callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: StravaAPI.StravaAPIError.invalidResponse)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            self.authSession = session
            session.start()
        }
    }

    /// Handle OAuth callback and exchange code for tokens
    private func handleCallback(url: URL, expectedState: String) async throws {
        let code = try StravaOAuth.authorizationCode(from: url, expectedState: expectedState)

        // Exchange code for tokens
        let tokenResponse = try await StravaAPI.exchangeToken(code: code)
        guard let athlete = tokenResponse.athlete else {
            throw StravaAPI.StravaAPIError.invalidResponse
        }

        // Save tokens to keychain
        try saveTokens(tokenResponse)

        // Create or update StravaAuth
        let auth = StravaAuth(
            athleteId: athlete.id,
            athleteName: athlete.fullName,
            profileImageURL: athlete.profile,
            hasAccessToken: true,
            hasRefreshToken: true,
            accessTokenExpiresAt: tokenResponse.expirationDate,
            connectedAt: Date(),
            lastSyncDate: nil,
            syncCursor: nil,
            isConnected: true,
            stravaFTP: athlete.ftp
        )

        try dataStore.saveStravaAuth(auth)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension StravaAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the key window
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
    }
}
