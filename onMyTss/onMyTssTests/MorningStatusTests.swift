import XCTest
@testable import onMyTss

final class MorningStatusTests: XCTestCase {
    @MainActor
    func testAPIUsesJSONLoginAndHeaderSessionWithoutCookiesOrURLSecrets() async throws {
        var calls: [URLRequest] = []
        let api = MorningStatusAPI { request in
            calls.append(request)
            let json = request.url!.lastPathComponent == "session"
                ? #"{"access_token":"fixture-session","token_type":"Bearer"}"# : morningFixtureJSON
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let token = try await api.signIn(email: "athlete@example.invalid", password: "fixture-password")
        let status = try await api.fetchStatus(token: token)
        XCTAssertEqual(status.wellness?.sleepHours, 7.5)
        XCTAssertEqual(status.wellness?.restingHr, 55)
        XCTAssertEqual(calls[0].url?.path, "/api/mobile/session")
        XCTAssertEqual(calls[0].httpMethod, "POST")
        XCTAssertEqual(calls[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[0].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["email": "athlete@example.invalid", "password": "fixture-password"])
        XCTAssertEqual(calls[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-session")
        XCTAssertNil(calls[1].httpBody)
        for request in calls {
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        }
    }

    @MainActor
    func testAPIRejectsRedirectsHTMLAndHTTPFailures() async throws {
        let cases: [(Int, String, MorningStatusError)] = [
            (302, "application/json", .unavailable), (401, "application/json", .unauthorized),
            (422, "application/json", .invalidInput), (429, "application/json", .rateLimited),
            (503, "application/json", .unavailable), (200, "text/html", .invalidResponse)
        ]
        for (code, type, expected) in cases {
            let api = MorningStatusAPI { request in
                (Data(morningFixtureJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                    headerFields: ["Content-Type": type, "Location": "https://example.invalid/login"])!)
            }
            do {
                _ = try await api.fetchStatus(token: "fixture-session")
                XCTFail("Expected status \(code) / \(type) to fail")
            } catch { XCTAssertEqual(error as? MorningStatusError, expected) }
        }
    }

    @MainActor
    func testAPIChangesOnlyTimezoneAndUnsubscribesThroughAuthenticatedRoute() async throws {
        var calls: [URLRequest] = []
        let api = MorningStatusAPI { request in
            calls.append(request)
            return (Data(morningFixtureJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
        }
        _ = try await api.updateTimezone("Asia/Shanghai", token: "fixture-session")
        _ = try await api.unsubscribe(token: "fixture-session")
        XCTAssertEqual(calls[0].url?.path, "/api/mobile/morning-status/timezone")
        XCTAssertEqual(calls[0].httpMethod, "PUT")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: calls[0].httpBody!) as? [String: String], ["timezone": "Asia/Shanghai"])
        XCTAssertEqual(calls[1].url?.path, "/api/mobile/morning-status/unsubscribe")
        XCTAssertEqual(calls[1].httpMethod, "POST")
        XCTAssertNil(calls[1].httpBody)
        XCTAssertTrue(calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-session" })
    }

    @MainActor
    func testInsecureURLIsRejectedBeforeSendingCredentials() async throws {
        let api = MorningStatusAPI(baseURL: URL(string: "http://example.invalid")!) { _ in
            XCTFail("Must not transmit credentials over HTTP")
            throw MorningStatusError.unavailable
        }
        do {
            _ = try await api.signIn(email: "athlete@example.invalid", password: "fixture-password")
            XCTFail("Expected HTTPS enforcement")
        } catch { XCTAssertEqual(error as? MorningStatusError, .invalidResponse) }
    }

    @MainActor
    func testStoredSessionLoadsStatusAndSignInStoresOnlySession() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.signIn(email: " athlete@example.invalid ", password: "fixture-password")
        XCTAssertEqual(store.token, "fixture-session")
        XCTAssertEqual(api.loginEmail, "athlete@example.invalid")
        XCTAssertEqual(model.status?.displayName, "Fixture Athlete")
        let reopened = MorningStatusViewModel(api: api, tokenStore: store)
        await reopened.load()
        XCTAssertTrue(reopened.isSignedIn)
        XCTAssertEqual(reopened.status?.timezone, "America/Chicago")
    }

    @MainActor
    func testNetworkFailurePreservesSessionAndLastLoadedStatus() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub(token: "fixture-session")
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.load()
        let previous = model.status
        api.error = URLError(.notConnectedToInternet)
        await model.refresh()
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(model.status, previous)
        XCTAssertEqual(store.token, "fixture-session")
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testExpiredSessionClearsAccountDataAndRequiresSignIn() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub(token: "fixture-session")
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.load()
        api.error = MorningStatusError.unauthorized
        await model.refresh()
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.status)
        XCTAssertNil(store.token)
    }

    @MainActor
    func testSignOutDoesNotUnsubscribeOrChangeRemoteSettings() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub(token: "fixture-session")
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.load()
        model.signOut()
        XCTAssertNil(store.token)
        XCTAssertNil(model.status)
        XCTAssertEqual(api.unsubscribeCalls, 0)
        XCTAssertNil(api.updatedTimezone)
    }

    @MainActor
    func testFailedUnsubscribePreservesStatusAndSuccessShowsServerResult() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub(token: "fixture-session")
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.load()
        api.error = MorningStatusError.unavailable
        await model.unsubscribe()
        XCTAssertEqual(model.status?.smsEnabled, true)
        XCTAssertNil(model.notice)
        api.error = nil
        api.json = morningFixtureJSON.replacingOccurrences(of: #""sms_enabled":true"#, with: #""sms_enabled":false"#)
            .replacingOccurrences(of: #""sms_state":"active""#, with: #""sms_state":"not_subscribed""#)
        await model.unsubscribe()
        XCTAssertEqual(model.status?.smsEnabled, false)
        XCTAssertEqual(model.status?.subscriptionLabel, "Not subscribed")
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testTimezoneSaveUsesServerAcknowledgement() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub(token: "fixture-session")
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.load()
        api.json = morningFixtureJSON.replacingOccurrences(of: "America/Chicago", with: "Asia/Shanghai")
        await model.saveTimezone("Asia/Shanghai")
        XCTAssertEqual(api.updatedTimezone, "Asia/Shanghai")
        XCTAssertEqual(model.status?.timezone, "Asia/Shanghai")
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testKeychainWriteFailureDoesNotReportSignedIn() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        store.failWrites = true
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.signIn(email: "athlete@example.invalid", password: "fixture-password")
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.status)
        XCTAssertEqual(api.fetchCalls, 0)
        XCTAssertNotNil(model.errorMessage)
    }
}

@MainActor
private final class MorningServiceStub: MorningStatusServing {
    var error: Error?
    var json = morningFixtureJSON
    var loginEmail: String?
    var updatedTimezone: String?
    var unsubscribeCalls = 0
    var fetchCalls = 0
    func signIn(email: String, password: String) async throws -> String {
        if let error { throw error }
        loginEmail = email
        return "fixture-session"
    }
    func fetchStatus(token: String) async throws -> MorningStatus {
        fetchCalls += 1
        if let error { throw error }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MorningStatus.self, from: Data(json.utf8))
    }
    func updateTimezone(_ timezone: String, token: String) async throws -> MorningStatus {
        updatedTimezone = timezone
        return try await fetchStatus(token: token)
    }
    func unsubscribe(token: String) async throws -> MorningStatus {
        unsubscribeCalls += 1
        return try await fetchStatus(token: token)
    }
    nonisolated deinit {}
}

@MainActor
private final class MorningSessionStub: MorningSessionStoring {
    var token: String?
    var failWrites = false
    init(token: String? = nil) { self.token = token }
    func load() throws -> String? { token }
    func save(_ token: String) throws {
        if failWrites { throw MorningStatusError.secureStorage }
        self.token = token
    }
    func delete() throws { token = nil }
    nonisolated deinit {}
}

private let morningFixtureJSON = #"""
{"display_name":"Fixture Athlete","email":"athlete@example.invalid","phone_hint":"Ending in 0100",
 "timezone":"America/Chicago","local_date":"2026-10-25","window_start":"06:00","window_end":"10:30",
 "sms_state":"active","sms_enabled":true,"sent_today":false,"has_today_data":true,"in_delivery_window":false,
 "wellness":{"hrv":50,"resting_hr":55,"sleep_hours":7.5,"tsb":-3},"last_activity_sync":null,
 "wellness_through":"2026-10-25","sync_failures":0}
"""#
