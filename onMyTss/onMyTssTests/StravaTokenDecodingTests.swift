//
//  StravaTokenDecodingTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
@testable import onMyTss

final class StravaTokenDecodingTests: XCTestCase {

    func testTokenResponseAllowsMissingAthlete() throws {
        let json = """
        {
          "token_type": "Bearer",
          "expires_at": 123456789,
          "expires_in": 21600,
          "refresh_token": "rt",
          "access_token": "at"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let token = try decoder.decode(TokenResponse.self, from: json)
        XCTAssertNil(token.athlete, "Athlete should decode as nil when missing")
        XCTAssertEqual(token.tokenType, "Bearer")
        XCTAssertEqual(token.accessToken, "at")
    }
}
