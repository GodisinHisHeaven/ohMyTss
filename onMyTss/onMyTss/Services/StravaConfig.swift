//
//  StravaConfig.swift
//  onMyTss
//
//  IMPORTANT: This file references your Strava API credentials via environment variables
//  or Info.plist values injected from build settings. DO NOT commit real credentials to
//  version control! This file is in .gitignore
//

import Foundation

/// Strava API configuration
/// Get your credentials from https://www.strava.com/settings/api
/// Values are read from environment variables first, then Info.plist (fed by build settings)
/// to avoid hardcoding secrets in source.
enum StravaConfig {
    private enum Keys {
        static let clientID = "STRAVA_CLIENT_ID"
        static let clientSecret = "STRAVA_CLIENT_SECRET"
    }

    static var clientID: String? {
        resolveValue(for: Keys.clientID,
                     environment: ProcessInfo.processInfo.environment,
                     infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
    static var clientSecret: String? {
        resolveValue(for: Keys.clientSecret,
                     environment: ProcessInfo.processInfo.environment,
                     infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// Resolve credentials from environment first, then Info.plist (set via build settings).
    /// Returns nil for empty strings or unresolved build placeholders like `$(STRAVA_CLIENT_ID)`.
    static func resolveValue(for key: String,
                             environment: [String: String],
                             infoDictionary: [String: Any]) -> String? {
        if let envRaw = environment[key],
           let env = envRaw.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return env
        }

        if let infoRaw = infoDictionary[key] as? String,
           let info = infoRaw.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           !info.isBuildPlaceholder {
            return info
        }

        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var isBuildPlaceholder: Bool {
        hasPrefix("$(") && hasSuffix(")")
    }
}
