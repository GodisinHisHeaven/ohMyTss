//
//  KeychainHelper.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import Security

/// Helper for securely storing sensitive data in iOS Keychain
struct KeychainHelper {

    // MARK: - Keys

    enum Key: String {
        case stravaAccessToken = "com.onmytss.strava.accessToken"
        case stravaRefreshToken = "com.onmytss.strava.refreshToken"
    }

    // MARK: - Errors

    enum KeychainError: LocalizedError {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .itemNotFound, .invalidData:
                return "Your saved Strava credentials are unavailable. Please reconnect Strava."
            case .duplicateItem, .unexpectedStatus:
                return "Unable to access saved Strava credentials. Unlock your device and try again."
            }
        }
    }

    // MARK: - Save

    /// Save a string value to the keychain
    static func save(_ value: String, forKey key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Update in place so a failed write cannot delete the previous token.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Retrieve

    /// Retrieve a string value from the keychain
    static func retrieve(_ key: Key) throws -> String {
        // Prepare query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Fetch from keychain
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    // MARK: - Delete

    /// Delete a value from the keychain
    static func delete(_ key: Key) throws {
        // Prepare query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]

        // Delete from keychain
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Convenience Methods

    /// Save Strava access token
    static func saveStravaAccessToken(_ token: String) throws {
        try save(token, forKey: .stravaAccessToken)
    }

    /// Retrieve Strava access token
    static func getStravaAccessToken() throws -> String {
        try retrieve(.stravaAccessToken)
    }

    /// Save Strava refresh token
    static func saveStravaRefreshToken(_ token: String) throws {
        try save(token, forKey: .stravaRefreshToken)
    }

    /// Retrieve Strava refresh token
    static func getStravaRefreshToken() throws -> String {
        try retrieve(.stravaRefreshToken)
    }

    /// Delete all Strava tokens (for disconnecting)
    static func deleteStravaTokens() throws {
        try delete(.stravaAccessToken)
        try delete(.stravaRefreshToken)
    }
}
