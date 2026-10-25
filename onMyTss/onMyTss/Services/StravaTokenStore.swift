import Foundation

@MainActor
protocol StravaTokenStoring {
    func accessToken() throws -> String
    func refreshToken() throws -> String
    func save(accessToken: String, refreshToken: String) throws
    func deleteTokens() throws
}

struct KeychainStravaTokenStore: StravaTokenStoring {
    func accessToken() throws -> String {
        try KeychainHelper.getStravaAccessToken()
    }

    func refreshToken() throws -> String {
        try KeychainHelper.getStravaRefreshToken()
    }

    func save(accessToken: String, refreshToken: String) throws {
        // Preserve the rotated refresh token first so an access-token write failure is recoverable.
        try KeychainHelper.saveStravaRefreshToken(refreshToken)
        try KeychainHelper.saveStravaAccessToken(accessToken)
    }

    func deleteTokens() throws {
        try KeychainHelper.deleteStravaTokens()
    }
}
