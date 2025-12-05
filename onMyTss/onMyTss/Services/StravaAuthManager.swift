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

/// Manages Strava OAuth flow and token lifecycle
/// Coordinates between StravaAPI, Keychain, and SwiftData
@MainActor
final class StravaAuthManager: NSObject, ObservableObject {

    // MARK: - Dependencies

    private let dataStore: DataStore

    // MARK: - State

    @Published var isAuthenticating: Bool = false
    @Published var authError: String?

    // OAuth session
    private var authSession: ASWebAuthenticationSession?

    // MARK: - Initialization

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Connection

    /// Initiate Strava OAuth flow
    func connectStrava() async throws {
        guard let authURL = StravaAPI.getAuthorizationURL() else {
            throw StravaAPI.StravaAPIError.invalidURL
        }

        isAuthenticating = true
        authError = nil

        do {
            let callbackURL = try await authenticate(with: authURL)
            try await handleCallback(url: callbackURL)
            isAuthenticating = false
        } catch {
            isAuthenticating = false
            authError = error.localizedDescription
            throw error
        }
    }

    /// Disconnect Strava (revoke tokens and clear data)
    func disconnectStrava() async throws {
        // Clear tokens from keychain
        try KeychainHelper.deleteStravaTokens()

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

        // Check if token needs refresh
        if auth.needsTokenRefresh {
            try await refreshAccessToken()
        }

        // Get token from keychain
        return try KeychainHelper.getStravaAccessToken()
    }

    /// Refresh access token using refresh token
    private func refreshAccessToken() async throws {
        // Get refresh token from keychain
        let refreshToken = try KeychainHelper.getStravaRefreshToken()

        // Call Strava API to refresh
        let tokenResponse = try await StravaAPI.refreshToken(refreshToken)

        // Save new tokens
        try KeychainHelper.saveStravaAccessToken(tokenResponse.accessToken)
        try KeychainHelper.saveStravaRefreshToken(tokenResponse.refreshToken)

        // Update auth state
        guard let auth = try dataStore.fetchStravaAuth() else {
            throw StravaAPI.StravaAPIError.unauthorized
        }

        auth.hasAccessToken = true
        auth.hasRefreshToken = true
        auth.accessTokenExpiresAt = tokenResponse.expirationDate

        try dataStore.updateStravaAuth(auth)
    }

    // MARK: - Private Helpers

    /// Present ASWebAuthenticationSession for OAuth
    private func authenticate(with url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "onmytss"
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
    private func handleCallback(url: URL) async throws {
        // Extract authorization code from callback URL
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw StravaAPI.StravaAPIError.invalidResponse
        }

        // Exchange code for tokens
        let tokenResponse = try await StravaAPI.exchangeToken(code: code)
        guard let athlete = tokenResponse.athlete else {
            throw StravaAPI.StravaAPIError.invalidResponse
        }

        // Save tokens to keychain
        try KeychainHelper.saveStravaAccessToken(tokenResponse.accessToken)
        try KeychainHelper.saveStravaRefreshToken(tokenResponse.refreshToken)

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
