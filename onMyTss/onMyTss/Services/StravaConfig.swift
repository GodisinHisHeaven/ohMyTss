//
//  StravaConfig.swift
//  onMyTss
//
//  IMPORTANT: This file references your Strava API credentials via environment variables
//  DO NOT commit real credentials to version control! This file is in .gitignore
//

import Foundation

/// Strava API configuration
/// Get your credentials from https://www.strava.com/settings/api
/// Values are read from environment variables to avoid storing secrets in source.
enum StravaConfig {
    private enum Keys {
        static let clientID = "STRAVA_CLIENT_ID"
        static let clientSecret = "STRAVA_CLIENT_SECRET"
    }

    static var clientID: String? { envValue(for: Keys.clientID) }
    static var clientSecret: String? { envValue(for: Keys.clientSecret) }

    private static func envValue(for key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
