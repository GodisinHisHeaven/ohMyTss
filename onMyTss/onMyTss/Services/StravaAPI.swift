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

    /// Strava OAuth credentials loaded from environment variables via StravaConfig
    /// See StravaConfig.swift.template for setup instructions
    private static func loadCredentials() throws -> (clientID: String, clientSecret: String) {
        guard let clientID = StravaConfig.clientID,
              let clientSecret = StravaConfig.clientSecret else {
            throw StravaAPIError.missingConfiguration
        }

        return (clientID, clientSecret)
    }
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
        case missingConfiguration

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
            case .missingConfiguration:
                return "Missing Strava credentials. Set STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET in build settings (Info.plist) or scheme environment variables."
            }
        }
    }

    // MARK: - OAuth

    /// Generate authorization URL for OAuth flow
    static func getAuthorizationURL() throws -> URL {
        let credentials = try loadCredentials()
        var components = URLComponents(string: Endpoint.authorize)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read,activity:read_all"),
            URLQueryItem(name: "approval_prompt", value: "auto")
        ]
        guard let url = components?.url else {
            throw StravaAPIError.invalidURL
        }
        return url
    }

    /// Exchange authorization code for access and refresh tokens
    static func exchangeToken(code: String) async throws -> TokenResponse {
        let credentials = try loadCredentials()
        guard let url = URL(string: Endpoint.token) else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "code": code,
            "grant_type": "authorization_code"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await performRequest(request)
    }

    /// Refresh access token using refresh token
    static func refreshToken(_ refreshToken: String) async throws -> TokenResponse {
        let credentials = try loadCredentials()
        guard let url = URL(string: Endpoint.token) else {
            throw StravaAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
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
    let athlete: StravaAthlete?

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
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case distance
        case movingTime
        case elapsedTime
        case totalElevationGain
        case type
        case sportType
        case startDate
        case startDateLocal
        case timezone
        case averageSpeed
        case maxSpeed
        case averageCadence
        case averageWatts
        case weightedAverageWatts
        case kilojoules
        case deviceWatts
        case hasHeartrate
        case averageHeartrate
        case maxHeartrate
        case deviceName
    }

    let id: Int
    var name: String
    var distance: Double
    var movingTime: Int
    var elapsedTime: Int
    var totalElevationGain: Double
    var type: String
    var sportType: String
    var startDate: String
    var startDateLocal: String
    var timezone: String
    var averageSpeed: Double
    var maxSpeed: Double
    var averageCadence: Double?
    var averageWatts: Double?
    var weightedAverageWatts: Int? // This is Strava's Normalized Power equivalent
    var kilojoules: Double?
    var deviceWatts: Bool?
    var hasHeartrate: Bool
    var averageHeartrate: Double?
    var maxHeartrate: Double?
    var deviceName: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? -1
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Activity"
        distance = try container.decodeIfPresent(Double.self, forKey: .distance) ?? 0
        movingTime = try container.decodeIfPresent(Int.self, forKey: .movingTime) ?? 0
        elapsedTime = try container.decodeIfPresent(Int.self, forKey: .elapsedTime) ?? movingTime
        totalElevationGain = try container.decodeIfPresent(Double.self, forKey: .totalElevationGain) ?? 0

        let decodedType = try container.decodeIfPresent(String.self, forKey: .type) ?? "Workout"
        type = decodedType
        sportType = try container.decodeIfPresent(String.self, forKey: .sportType) ?? decodedType

        startDate = try container.decodeIfPresent(String.self, forKey: .startDate) ?? ""
        startDateLocal = try container.decodeIfPresent(String.self, forKey: .startDateLocal) ?? startDate
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
        averageSpeed = try container.decodeIfPresent(Double.self, forKey: .averageSpeed) ?? 0
        maxSpeed = try container.decodeIfPresent(Double.self, forKey: .maxSpeed) ?? 0
        averageCadence = try container.decodeIfPresent(Double.self, forKey: .averageCadence)
        averageWatts = try container.decodeIfPresent(Double.self, forKey: .averageWatts)
        weightedAverageWatts = try container.decodeIfPresent(Int.self, forKey: .weightedAverageWatts)
        kilojoules = try container.decodeIfPresent(Double.self, forKey: .kilojoules)
        deviceWatts = try container.decodeIfPresent(Bool.self, forKey: .deviceWatts)
        hasHeartrate = try container.decodeIfPresent(Bool.self, forKey: .hasHeartrate) ?? false
        averageHeartrate = try container.decodeIfPresent(Double.self, forKey: .averageHeartrate)
        maxHeartrate = try container.decodeIfPresent(Double.self, forKey: .maxHeartrate)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(distance, forKey: .distance)
        try container.encode(movingTime, forKey: .movingTime)
        try container.encode(elapsedTime, forKey: .elapsedTime)
        try container.encode(totalElevationGain, forKey: .totalElevationGain)
        try container.encode(type, forKey: .type)
        try container.encode(sportType, forKey: .sportType)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(startDateLocal, forKey: .startDateLocal)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(averageSpeed, forKey: .averageSpeed)
        try container.encode(maxSpeed, forKey: .maxSpeed)
        try container.encodeIfPresent(averageCadence, forKey: .averageCadence)
        try container.encodeIfPresent(averageWatts, forKey: .averageWatts)
        try container.encodeIfPresent(weightedAverageWatts, forKey: .weightedAverageWatts)
        try container.encodeIfPresent(kilojoules, forKey: .kilojoules)
        try container.encodeIfPresent(deviceWatts, forKey: .deviceWatts)
        try container.encode(hasHeartrate, forKey: .hasHeartrate)
        try container.encodeIfPresent(averageHeartrate, forKey: .averageHeartrate)
        try container.encodeIfPresent(maxHeartrate, forKey: .maxHeartrate)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
    }

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
