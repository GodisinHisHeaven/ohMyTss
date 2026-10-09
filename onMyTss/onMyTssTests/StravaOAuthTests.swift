import XCTest
@testable import onMyTss

@MainActor
final class StravaOAuthTests: XCTestCase {
    func testAuthorizationUsesMobileEndpointAndRoundTripsState() throws {
        let url = try StravaOAuth.authorizationURL(clientID: "123456", state: "request-state")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.host, "www.strava.com")
        XCTAssertEqual(components.path, "/oauth/mobile/authorize")
        XCTAssertEqual(query["client_id"], "123456")
        XCTAssertEqual(query["redirect_uri"], "onmytss://onmytss.com")
        XCTAssertEqual(query["state"], "request-state")
        XCTAssertNil(query["client_secret"])
    }

    func testCallbackAcceptsBothDocumentedScopeSeparators() throws {
        for scope in ["read,activity:read_all", "read activity:read_all"] {
            let code = try StravaOAuth.authorizationCode(from: callback(scope: scope), expectedState: "request-state")
            XCTAssertEqual(code, "authorization-code")
        }
    }

    func testCallbackRejectsWrongStateOrDestination() throws {
        let invalidURLs = [
            callback(state: "different-request"),
            URL(string: "otherapp://onmytss.com?state=request-state&code=code&scope=activity:read_all")!,
            URL(string: "onmytss://wrong.example?state=request-state&code=code&scope=activity:read_all")!,
            URL(string: "onmytss://onmytss.com/unexpected?state=request-state&code=code&scope=activity:read_all")!
        ]
        for url in invalidURLs {
            XCTAssertThrowsError(try StravaOAuth.authorizationCode(from: url, expectedState: "request-state")) {
                guard case StravaOAuth.AuthorizationError.invalidCallback = $0 else {
                    return XCTFail("Expected callback validation to fail")
                }
            }
        }
    }

    func testCallbackRejectsMissingOrDuplicateCodeAndState() throws {
        for query in [
            "state=request-state&code=&scope=activity:read_all",
            "state=request-state&scope=activity:read_all",
            "code=code&scope=activity:read_all",
            "state=request-state&state=request-state&code=code&scope=activity:read_all",
            "state=request-state&code=one&code=two&scope=activity:read_all"
        ] {
            let url = try XCTUnwrap(URL(string: "onmytss://onmytss.com?" + query))
            XCTAssertThrowsError(try StravaOAuth.authorizationCode(from: url, expectedState: "request-state"))
        }
    }

    func testDeniedAuthorizationHasAnActionableError() throws {
        let url = try XCTUnwrap(URL(string: "onmytss://onmytss.com?state=request-state&error=access_denied"))
        XCTAssertThrowsError(try StravaOAuth.authorizationCode(from: url, expectedState: "request-state")) {
            guard case StravaOAuth.AuthorizationError.accessDenied = $0 else {
                return XCTFail("Expected cancellation instead of a missing-token error")
            }
        }
    }

    func testCallbackRequiresActivityPermissionBeforeTokenExchange() throws {
        XCTAssertThrowsError(try StravaOAuth.authorizationCode(from: callback(scope: "read"), expectedState: "request-state")) {
            guard case StravaOAuth.AuthorizationError.missingActivityPermission = $0 else {
                return XCTFail("Expected activity permission error")
            }
        }
    }

    private func callback(state: String = "request-state", scope: String = "read,activity:read_all") -> URL {
        var components = URLComponents(string: "onmytss://onmytss.com")!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "scope", value: scope)
        ]
        return components.url!
    }
}
