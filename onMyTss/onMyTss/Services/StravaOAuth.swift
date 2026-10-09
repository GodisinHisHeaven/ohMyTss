import Foundation

enum StravaOAuth {
    static let callbackScheme = "onmytss"
    static let redirectURI = "onmytss://onmytss.com"

    enum AuthorizationError: LocalizedError {
        case invalidCallback
        case accessDenied
        case missingActivityPermission

        var errorDescription: String? {
            switch self {
            case .invalidCallback:
                return "Strava returned an invalid authorization response. Please try connecting again."
            case .accessDenied:
                return "Strava authorization was cancelled. Connect again when you are ready."
            case .missingActivityPermission:
                return "Allow access to your Strava activities, including private activities, to sync workouts."
            }
        }
    }

    static func authorizationURL(clientID: String, state: String) throws -> URL {
        var components = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read,activity:read_all"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw AuthorizationError.invalidCallback
        }
        return url
    }

    static func authorizationCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirect = URLComponents(string: redirectURI),
              components.scheme == redirect.scheme,
              components.host == redirect.host,
              components.path == redirect.path,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw AuthorizationError.invalidCallback
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches.first?.value : nil
        }

        guard !expectedState.isEmpty, value("state") == expectedState else {
            throw AuthorizationError.invalidCallback
        }
        if value("error") == "access_denied" {
            throw AuthorizationError.accessDenied
        }
        guard !items.contains(where: { $0.name == "error" }),
              let code = value("code"), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthorizationError.invalidCallback
        }

        let scopes = Set((value("scope") ?? "").split { $0 == "," || $0.isWhitespace }.map(String.init))
        guard scopes.contains("activity:read_all") else {
            throw AuthorizationError.missingActivityPermission
        }
        return code
    }
}
