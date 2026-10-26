import Foundation

enum MorningStatusError: LocalizedError, Equatable {
    case unauthorized, invalidInput, rateLimited, unavailable, invalidResponse, secureStorage, noSubscription, consentRequired

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Verify your phone number again to connect morning status."
        case .invalidInput: "Check the information you entered and try again."
        case .rateLimited: "Too many attempts. Wait before trying again."
        case .unavailable: "Morning status is unavailable. Please try again later."
        case .invalidResponse: "Morning status returned an unexpected response. Please try again later."
        case .secureStorage: "Unable to access your saved morning status session. Unlock your device and try again."
        case .noSubscription: "This phone number has no morning status subscription yet."
        case .consentRequired: "Check your morning text consent and delivery time zone. If you opted out by text, reply START first."
        }
    }
}

struct MorningPhoneChallenge: Decodable, Equatable {
    let challenge: String
    let phoneHint: String
    let expiresIn: Int
    let retryAfter: Int
}

enum MorningPhoneInput {
    static func normalized(_ value: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "().-"))
        var phone = value.unicodeScalars.filter { !separators.contains($0) }.map(String.init).joined()
        if phone.count == 10 { phone = "+1" + phone }
        else if phone.count == 11 && phone.hasPrefix("1") { phone = "+" + phone }
        guard phone.count == 12, phone.hasPrefix("+1"),
              phone.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return phone
    }

    static func validCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

@MainActor
protocol MorningStatusServing {
    func requestCode(phone: String) async throws -> MorningPhoneChallenge
    func verifyCode(challenge: String, code: String) async throws -> String
    func fetchStatus(token: String) async throws -> MorningStatus
    func updateTimezone(_ timezone: String, token: String) async throws -> MorningStatus
    func unsubscribe(token: String) async throws -> MorningStatus
    func subscribe(timezone: String, token: String) async throws -> MorningStatus
    func uploadSummary(_ summary: MorningAppSummary, token: String) async throws -> MorningStatus
}

private final class MorningStatusRedirectDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Login secrets and bearer sessions must never follow a redirect.
        completionHandler(nil)
    }
    nonisolated deinit {}
}

@MainActor
final class MorningStatusAPI: MorningStatusServing {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private let baseURL: URL

    convenience init(transport: Transport? = nil) {
        self.init(baseURL: AppIdentity.mobileAPIURL, transport: transport)
    }

    init(baseURL: URL, transport: Transport? = nil) {
        self.baseURL = baseURL
        self.transport = transport ?? { request in
            try await Self.session.data(for: request)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: MorningStatusRedirectDelegate(), delegateQueue: nil)
    }()

    func requestCode(phone: String) async throws -> MorningPhoneChallenge {
        let result: MorningPhoneChallenge = try await request("phone/start", method: "POST", body: ["phone": phone])
        guard !result.challenge.isEmpty, !result.phoneHint.isEmpty,
              (1...600).contains(result.expiresIn), (1...600).contains(result.retryAfter) else {
            throw MorningStatusError.invalidResponse
        }
        return result
    }

    func verifyCode(challenge: String, code: String) async throws -> String {
        struct Session: Decodable { let accessToken: String; let tokenType: String }
        let result: Session = try await request("phone/verify", method: "POST", body: [
            "challenge": challenge, "code": code, "privacy_version": "app-morning-v1"
        ])
        guard !result.accessToken.isEmpty, result.tokenType == "Bearer" else {
            throw MorningStatusError.invalidResponse
        }
        return result.accessToken
    }

    func fetchStatus(token: String) async throws -> MorningStatus {
        try await request("morning-status", token: token)
    }

    func updateTimezone(_ timezone: String, token: String) async throws -> MorningStatus {
        try await request("morning-status/timezone", method: "PUT", token: token, body: ["timezone": timezone])
    }

    func unsubscribe(token: String) async throws -> MorningStatus {
        try await request("morning-status/unsubscribe", method: "POST", token: token)
    }

    func subscribe(timezone: String, token: String) async throws -> MorningStatus {
        try await request("morning-status/subscribe", method: "POST", token: token,
                          body: ["timezone": timezone, "consent_version": "app-morning-v1"])
    }

    func uploadSummary(_ summary: MorningAppSummary, token: String) async throws -> MorningStatus {
        try await request("morning-status/summary", method: "PUT", token: token, body: summary.payload)
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil,
                                       body: [String: Any]? = nil) async throws -> T {
        guard baseURL.scheme == "https" else { throw MorningStatusError.invalidResponse }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else { throw MorningStatusError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw MorningStatusError.unauthorized
        case 403: throw MorningStatusError.consentRequired
        case 409: throw MorningStatusError.noSubscription
        case 422: throw MorningStatusError.invalidInput
        case 429: throw MorningStatusError.rateLimited
        default: throw MorningStatusError.unavailable
        }
        guard response.mimeType == "application/json" else { throw MorningStatusError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw MorningStatusError.invalidResponse }
    }

    nonisolated deinit {}
}

@MainActor
protocol MorningSessionStoring {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

struct MorningSessionKeychain: MorningSessionStoring {
    func load() throws -> String? {
        do { return try KeychainHelper.retrieve(.morningStatusSession) }
        catch KeychainHelper.KeychainError.itemNotFound { return nil }
        catch { throw MorningStatusError.secureStorage }
    }
    func save(_ token: String) throws {
        do { try KeychainHelper.save(token, forKey: .morningStatusSession) }
        catch { throw MorningStatusError.secureStorage }
    }
    func delete() throws {
        do { try KeychainHelper.delete(.morningStatusSession) }
        catch { throw MorningStatusError.secureStorage }
    }
}
