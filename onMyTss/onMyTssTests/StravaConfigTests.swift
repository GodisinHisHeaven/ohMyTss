//
//  StravaConfigTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
@testable import onMyTss

final class StravaConfigTests: XCTestCase {

    func testResolveValuePrefersEnvironment() {
        let env = ["STRAVA_CLIENT_ID": "1234"]
        let info: [String: Any] = ["STRAVA_CLIENT_ID": "info-id"]

        let value = StravaConfig.resolveValue(for: "STRAVA_CLIENT_ID",
                                              environment: env,
                                              infoDictionary: info)

        XCTAssertEqual(value, "1234")
    }

    func testResolveValueFallsBackToInfoDictionary() {
        let env: [String: String] = [:]
        let info: [String: Any] = ["STRAVA_CLIENT_SECRET": "info-secret"]

        let value = StravaConfig.resolveValue(for: "STRAVA_CLIENT_SECRET",
                                              environment: env,
                                              infoDictionary: info)

        XCTAssertEqual(value, "info-secret")
    }

    func testResolveValueIgnoresBuildPlaceholder() {
        let env: [String: String] = [:]
        let info: [String: Any] = ["STRAVA_CLIENT_ID": "$(STRAVA_CLIENT_ID)"]

        let value = StravaConfig.resolveValue(for: "STRAVA_CLIENT_ID",
                                              environment: env,
                                              infoDictionary: info)

        XCTAssertNil(value)
    }
}
