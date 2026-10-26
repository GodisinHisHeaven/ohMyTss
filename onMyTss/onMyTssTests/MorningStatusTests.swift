import XCTest
@testable import onMyTss

final class MorningStatusTests: XCTestCase {
    @MainActor
    func testAPIUsesPhoneChallengeAndHeaderSessionWithoutCookiesOrURLSecrets() async throws {
        var calls: [URLRequest] = []
        let api = MorningStatusAPI { request in
            calls.append(request)
            let json: String
            switch request.url!.lastPathComponent {
            case "start": json = #"{"challenge":"fixture-challenge","phone_hint":"Ending in 0100","expires_in":600,"retry_after":60}"#
            case "verify": json = #"{"access_token":"fixture-session","token_type":"Bearer"}"#
            default: json = morningFixtureJSON
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let challenge = try await api.requestCode(phone: "+12025550100")
        let token = try await api.verifyCode(challenge: challenge.challenge, code: "123456")
        let status = try await api.fetchStatus(token: token)
        XCTAssertEqual(status.wellness?.sleepHours, 7.5)
        XCTAssertEqual(status.wellness?.restingHr, 55)
        XCTAssertEqual(calls[0].url?.path, "/api/mobile/phone/start")
        XCTAssertEqual(calls[0].httpMethod, "POST")
        XCTAssertEqual(calls[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[0].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["phone": "+12025550100"])
        XCTAssertEqual(calls[1].url?.path, "/api/mobile/phone/verify")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: calls[1].httpBody!) as? [String: String],
                       ["challenge": "fixture-challenge", "code": "123456", "privacy_version": "app-morning-v1"])
        XCTAssertEqual(calls[2].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-session")
        XCTAssertNil(calls[2].httpBody)
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
            _ = try await api.requestCode(phone: "+12025550100")
            XCTFail("Expected HTTPS enforcement")
        } catch { XCTAssertEqual(error as? MorningStatusError, .invalidResponse) }
    }

    @MainActor
    func testStoredSessionLoadsStatusAndPhoneVerificationStoresOnlySession() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.requestCode(phone: " (202) 555-0100 ")
        XCTAssertNil(store.token)
        XCTAssertFalse(model.isSignedIn)
        await model.verifyCode("123456")
        XCTAssertEqual(store.token, "fixture-session")
        XCTAssertEqual(api.requestedPhone, "+12025550100")
        XCTAssertEqual(api.verifiedChallenge, "fixture-challenge")
        XCTAssertNil(model.verification)
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
        await model.requestCode(phone: "+12025550100")
        await model.verifyCode("123456")
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.status)
        XCTAssertEqual(api.fetchCalls, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testCodeCooldownExpiryAndChangeNumberNeverCreateSession() async throws {
        var now = Date(timeIntervalSince1970: 1000)
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        let model = MorningStatusViewModel(api: api, tokenStore: store, now: { now })
        await model.requestCode(phone: "+12025550100")
        await model.resendCode()
        XCTAssertEqual(api.requestCalls, 1)
        XCTAssertEqual(model.resendSeconds(at: now), 60)
        now = now.addingTimeInterval(60)
        await model.resendCode()
        XCTAssertEqual(api.requestCalls, 2)
        now = now.addingTimeInterval(601)
        await model.verifyCode("123456")
        XCTAssertNil(api.verifiedChallenge)
        XCTAssertTrue(model.errorMessage?.contains("expired") == true)
        XCTAssertNil(store.token)
        model.changePhone()
        XCTAssertNil(model.verification)
        await model.verifyCode("123456")
        XCTAssertNil(api.verifiedChallenge)
        await model.requestCode(phone: "+12025550101")
        XCTAssertEqual(api.requestedPhone, "+12025550101")
    }

    @MainActor
    func testInvalidCodeAndNetworkFailureAllowRetryWithoutSavingSession() async throws {
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.requestCode(phone: "+12025550100")
        api.error = MorningStatusError.unauthorized
        await model.verifyCode("000000")
        XCTAssertNotNil(model.verification)
        XCTAssertNil(store.token)
        XCTAssertTrue(model.errorMessage?.contains("code") == true)
        api.error = URLError(.notConnectedToInternet)
        await model.verifyCode("123456")
        XCTAssertNotNil(model.verification)
        XCTAssertFalse(model.isSignedIn)
        api.error = nil
        await model.verifyCode("123456")
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(store.token, "fixture-session")
    }

    @MainActor
    func testPhoneAndCodeValidationRejectsAmbiguousOrUnicodeInput() async {
        for value in ["2025550100", "1 (202) 555-0100", "+1.202.555.0100"] {
            XCTAssertEqual(MorningPhoneInput.normalized(value), "+12025550100")
        }
        for value in ["+442025550100", "2025550100abc", "２０２５５５０１００", "202555010"] {
            XCTAssertNil(MorningPhoneInput.normalized(value))
        }
        for value in ["12345", "1234567", "１２３４５６", "12345a"] {
            XCTAssertFalse(MorningPhoneInput.validCode(value))
        }
        let api = MorningServiceStub()
        let model = MorningStatusViewModel(api: api, tokenStore: MorningSessionStub())
        await model.requestCode(phone: "bad phone")
        XCTAssertEqual(api.requestCalls, 0)
        await model.requestCode(phone: "+12025550100")
        await model.verifyCode("123")
        XCTAssertNil(api.verifiedChallenge)
    }

    @MainActor
    func testMalformedChallengeResponseIsRejected() async {
        for values in [("", 600, 60), ("challenge", 0, 60), ("challenge", 600, -1), ("challenge", 10000, 60)] {
            let api = MorningStatusAPI { request in
                let data = try JSONSerialization.data(withJSONObject: ["challenge": values.0, "phone_hint": "Ending in 0100",
                    "expires_in": values.1, "retry_after": values.2])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"])!)
            }
            do { _ = try await api.requestCode(phone: "+12025550100"); XCTFail("Malformed challenge accepted") }
            catch { XCTAssertEqual(error as? MorningStatusError, .invalidResponse) }
        }
    }

    @MainActor
    func testVerifiedPhoneWithoutSubscriptionDoesNotClaimConnectedOrKeepConsumedCode() async {
        let api = MorningServiceStub()
        let store = MorningSessionStub()
        let model = MorningStatusViewModel(api: api, tokenStore: store)
        await model.requestCode(phone: "+12025550100")
        api.error = MorningStatusError.noSubscription
        await model.verifyCode("123456")
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.verification)
        XCTAssertNil(store.token)
        XCTAssertEqual(model.errorMessage, MorningStatusError.noSubscription.localizedDescription)
        XCTAssertEqual(api.fetchCalls, 0)
    }
}

@MainActor
final class MorningServiceStub: MorningStatusServing {
    var error: Error?
    var json = morningFixtureJSON
    var requestedPhone: String?
    var verifiedChallenge: String?
    var requestCalls = 0
    var updatedTimezone: String?
    var unsubscribeCalls = 0
    var fetchCalls = 0
    var subscribeCalls = 0
    var uploadedSummaries: [MorningAppSummary] = []
    func requestCode(phone: String) async throws -> MorningPhoneChallenge {
        if let error { throw error }
        requestCalls += 1
        requestedPhone = phone
        return MorningPhoneChallenge(challenge: "fixture-challenge", phoneHint: "Ending in 0100", expiresIn: 600, retryAfter: 60)
    }
    func verifyCode(challenge: String, code: String) async throws -> String {
        if let error { throw error }
        verifiedChallenge = challenge
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
    func subscribe(timezone: String, token: String) async throws -> MorningStatus {
        subscribeCalls += 1
        return try await fetchStatus(token: token)
    }
    func uploadSummary(_ summary: MorningAppSummary, token: String) async throws -> MorningStatus {
        if let error { throw error }
        uploadedSummaries.append(summary)
        return try await fetchStatus(token: token)
    }
    nonisolated deinit {}
}

@MainActor
final class MorningSessionStub: MorningSessionStoring {
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

let morningFixtureJSON = #"""
{"display_name":"Fixture Athlete","email":"athlete@example.invalid","phone_hint":"Ending in 0100",
 "timezone":"America/Chicago","local_date":"2026-10-25","window_start":"06:00","window_end":"10:30",
 "sms_state":"active","sms_enabled":true,"sent_today":false,"has_today_data":true,"in_delivery_window":false,
 "wellness":{"hrv":50,"resting_hr":55,"sleep_hours":7.5,"tsb":-3},"last_activity_sync":null,
 "wellness_through":"2026-10-25","sync_failures":0}
"""#
