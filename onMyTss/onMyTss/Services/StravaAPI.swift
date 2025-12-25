//
//  StravaAPI.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation

/// Low-level Strava API client using async/await
/// Handles OAuth and activity fetching with modern Swift concurrency
@MainActor
final class StravaAPI {

    // MARK: - Configuration

    /// Strava OAuth credentials loaded from StravaConfig.swift
    /// See StravaConfig.swift.template for setup instructions
    static var clientID: String = StravaConfig.clientID
    static var clientSecret: String = StravaConfig.clientSecret
    static var redirectURI: String = "onmytss://onmytss.com"

    // MARK: - Endpoints

    private enum Endpoint {
        static let baseURL = "https://www.strava.com/api/v3"
        static let authorize = "https://www.strava.com/oauth/authorize"
        static let token = "https://www.strava.com/oauth/token"
        static let athlete = "\(baseURL)/athlete"
        static let activities = "\(baseURL)/athlete/activities"
    }

    // MARK: - Errors

    enum StravaAPIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)
        case decodingError(Error)
        case unauthorized
        case rateLimited
        case networkError(Error)
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid API URL"
            case .invalidResponse:
                return "Invalid response from Strava"
            case .httpError(let code):
                return "HTTP error: \(code)"
            case .decodingError(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            case .unauthorized:
                return "Unauthorized - please reconnect Strava"
            case .rateLimited:
                return "Strava API rate limit exceeded - please try again later"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .notConfigured:
                return """
                Strava API Not Configured

                To connect Strava:
                1. Create an app at https://www.strava.com/settings/api
                2. Set Authorization Callback Domain to: onmytss.com
                3. Copy your Client ID and Client Secret
                4. Add them to StravaConfig.swift in Xcode
                """
            }
        }
    }

    // MARK: - Configuration Validation

    /// Check if Strava API is properly configured
    static func isConfigured() -> Bool {
        return clientID != "YOUR_CLIENT_ID" &&
               clientSecret != "YOUR_CLIENT_SECRET" &&
               !clientID.isEmpty &&
               !clientSecret.isEmpty
    }

    // MARK: - OAuth

    /// Generate authorization URL for OAuth flow
    static func getAuthorizationURL() -> URL? {
        guard isConfigured() else {
            return nil
        }

        var components = URLComponents(string: Endpoint.authorize)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read,activity:read_all"),
            URLQueryItem(name: "approval_prompt", value: "auto")
        ]
        return components?.url
    }

    /// Exchange authorization code for access and refresh tokens
    static func exchangeToken(code: String) async throws -> TokenResponse {
        guard isConfigured() else {
            throw StravaAPIError.notConfigured
        }

        guard let url = URL(string: Endpoint.token) else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "grant_type": "authorization_code"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performRequest(request)
    }

    /// Refresh access token using refresh token
    static func refreshToken(_ refreshToken: String) async throws -> TokenResponse {
        guard isConfigured() else {
            throw StravaAPIError.notConfigured
        }

        guard let url = URL(string: Endpoint.token) else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performRequest(request)
    }

    // MARK: - API Calls

    /// Get athlete profile
    static func getAthlete(accessToken: String) async throws -> StravaAthlete {
        guard let url = URL(string: Endpoint.athlete) else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await performRequest(request)
    }

    /// Fetch athlete activities with pagination
    /// - Parameters:
    ///   - accessToken: Strava access token
    ///   - after: Unix timestamp to fetch activities after
    ///   - before: Unix timestamp to fetch activities before
    ///   - page: Page number (1-indexed)
    ///   - perPage: Activities per page (max 200)
    static func getActivities(
        accessToken: String,
        after: Date? = nil,
        before: Date? = nil,
        page: Int = 1,
        perPage: Int = 200
    ) async throws -> [StravaActivity] {
        var components = URLComponents(string: Endpoint.activities)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "per_page", value: "\(perPage)")
        ]

        if let after = after {
            queryItems.append(URLQueryItem(name: "after", value: "\(Int(after.timeIntervalSince1970))"))
        }

        if let before = before {
            queryItems.append(URLQueryItem(name: "before", value: "\(Int(before.timeIntervalSince1970))"))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await performRequest(request)
    }

    // MARK: - Request Execution

    /// Configured URLSession with timeouts to prevent indefinite hangs
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30  // 30 seconds per request
        config.timeoutIntervalForResource = 60 // 60 seconds total
        return URLSession(configuration: config)
    }()

    /// Generic request performer with error handling
    private static func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw StravaAPIError.invalidResponse
            }

            // Handle HTTP errors
            switch httpResponse.statusCode {
            case 200...299:
                break // Success
            case 401:
                throw StravaAPIError.unauthorized
            case 429:
                throw StravaAPIError.rateLimited
            default:
                throw StravaAPIError.httpError(httpResponse.statusCode)
            }

            // Decode response
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw StravaAPIError.decodingError(error)
            }

        } catch let error as StravaAPIError {
            throw error
        } catch {
            throw StravaAPIError.networkError(error)
        }
    }
}

// MARK: - Response Models

struct TokenResponse: Codable {
    let tokenType: String
    let expiresAt: Int
    let expiresIn: Int
    let refreshToken: String
    let accessToken: String
    let athlete: StravaAthlete

    var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }
}

struct StravaAthlete: Codable {
    let id: Int
    let username: String?
    let firstname: String?
    let lastname: String?
    let profile: String?
    let ftp: Int?

    var fullName: String {
        if let first = firstname, let last = lastname {
            return "\(first) \(last)"
        }
        return username ?? "Strava Athlete"
    }
}

struct StravaActivity: Codable {
    let id: Int
    let name: String
    let distance: Double
    let movingTime: Int
    let elapsedTime: Int
    let totalElevationGain: Double
    let type: String
    let sportType: String
    let startDate: String
    let startDateLocal: String
    let timezone: String
    let averageSpeed: Double
    let maxSpeed: Double
    let averageCadence: Double?
    let averageWatts: Double?
    let weightedAverageWatts: Int? // This is Strava's Normalized Power equivalent
    let kilojoules: Double?
    let deviceWatts: Bool?
    let hasHeartrate: Bool
    let averageHeartrate: Double?
    let maxHeartrate: Double?
    let deviceName: String?

    /// Parse start date from ISO 8601 string
    var startDateTime: Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: startDate)
    }

    /// Check if activity has power data
    var hasPowerData: Bool {
        (deviceWatts == true) && (averageWatts != nil || weightedAverageWatts != nil)
    }
}
