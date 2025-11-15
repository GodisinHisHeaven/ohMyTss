//
//  StravaAuth.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

/// Strava connection state and token information
/// Stored in SwiftData for persistence across app sessions
@Model
final class StravaAuth {
    /// Athlete ID from Strava
    var athleteId: Int?

    /// Athlete name
    var athleteName: String?

    /// Profile image URL
    var profileImageURL: String?

    /// Access token (short-lived, expires in 6 hours)
    /// NOTE: Actual token stored in Keychain for security
    /// This field tracks whether we HAVE a token
    var hasAccessToken: Bool

    /// Refresh token (long-lived)
    /// NOTE: Actual token stored in Keychain for security
    /// This field tracks whether we HAVE a refresh token
    var hasRefreshToken: Bool

    /// Access token expiration date
    var accessTokenExpiresAt: Date?

    /// When the connection was established
    var connectedAt: Date?

    /// Last successful sync timestamp
    var lastSyncDate: Date?

    /// Strava cursor for incremental syncs (last activity ID fetched)
    var syncCursor: Int?

    /// Whether connection is currently active
    var isConnected: Bool

    /// Strava FTP value (if available from athlete profile)
    var stravaFTP: Int?

    init(
        athleteId: Int? = nil,
        athleteName: String? = nil,
        profileImageURL: String? = nil,
        hasAccessToken: Bool = false,
        hasRefreshToken: Bool = false,
        accessTokenExpiresAt: Date? = nil,
        connectedAt: Date? = nil,
        lastSyncDate: Date? = nil,
        syncCursor: Int? = nil,
        isConnected: Bool = false,
        stravaFTP: Int? = nil
    ) {
        self.athleteId = athleteId
        self.athleteName = athleteName
        self.profileImageURL = profileImageURL
        self.hasAccessToken = hasAccessToken
        self.hasRefreshToken = hasRefreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.connectedAt = connectedAt
        self.lastSyncDate = lastSyncDate
        self.syncCursor = syncCursor
        self.isConnected = isConnected
        self.stravaFTP = stravaFTP
    }

    /// Check if access token needs refresh (expires within 5 minutes)
    var needsTokenRefresh: Bool {
        guard let expiresAt = accessTokenExpiresAt else { return true }
        return Date().addingTimeInterval(300) >= expiresAt
    }
}
