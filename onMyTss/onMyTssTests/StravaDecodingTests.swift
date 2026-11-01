//
//  StravaDecodingTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
@testable import onMyTss

final class StravaDecodingTests: XCTestCase {

    func testReportedElapsedTimeDistinguishesUnknownAndRoundTrips() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        for (fragment, reported) in [("", nil), (",\"elapsed_time\":null", nil),
                                     (",\"elapsed_time\":720", 720),
                                     (",\"elapsed_time\":500", 500)] as [(String, Int?)] {
            let json = "{\"id\":12,\"moving_time\":600\(fragment)}".data(using: .utf8)!
            let activity = try decoder.decode(StravaActivity.self, from: json)
            XCTAssertEqual(activity.reportedElapsedTime, reported)
            XCTAssertEqual(activity.elapsedTime, reported ?? 600)
            let roundTrip = try decoder.decode(StravaActivity.self, from: encoder.encode(activity))
            XCTAssertEqual(roundTrip.reportedElapsedTime, reported)
            XCTAssertEqual(roundTrip.elapsedTime, activity.elapsedTime)
        }
    }

    func testActivityDecodesWithMissingFields() throws {
        let json = """
        [
          {
            "id": 12345,
            "type": "Ride"
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let activities = try decoder.decode([StravaActivity].self, from: json)
        let activity = try XCTUnwrap(activities.first)

        XCTAssertEqual(activity.id, 12345)
        XCTAssertEqual(activity.name, "Activity") // default fallback
        XCTAssertEqual(activity.distance, 0)
        XCTAssertEqual(activity.movingTime, 0)
        XCTAssertEqual(activity.elapsedTime, 0)
        XCTAssertEqual(activity.totalElevationGain, 0)
        XCTAssertEqual(activity.type, "Ride")
        XCTAssertEqual(activity.sportType, "Ride") // falls back to type
    }

    func testActivityDecodesWhenIdMissing() throws {
        let json = """
        [
          {
            "name": "Morning Ride",
            "type": "Ride"
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let activities = try decoder.decode([StravaActivity].self, from: json)
        let activity = try XCTUnwrap(activities.first)

        XCTAssertEqual(activity.id, -1)
        XCTAssertEqual(activity.name, "Morning Ride")
    }

    func testActivityDecodesWithNulls() throws {
        let json = """
        [
          {
            "id": 67890,
            "name": null,
            "distance": null,
            "moving_time": null,
            "elapsed_time": null,
            "total_elevation_gain": null,
            "sport_type": null,
            "start_date": null,
            "start_date_local": null,
            "timezone": null,
            "average_speed": null,
            "max_speed": null,
            "average_cadence": null,
            "average_watts": null,
            "weighted_average_watts": null,
            "kilojoules": null,
            "device_watts": null,
            "has_heartrate": null,
            "average_heartrate": null,
            "max_heartrate": null,
            "device_name": null
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let activities = try decoder.decode([StravaActivity].self, from: json)
        let activity = try XCTUnwrap(activities.first)

        XCTAssertEqual(activity.id, 67890)
        XCTAssertEqual(activity.name, "Activity")
        XCTAssertEqual(activity.distance, 0)
        XCTAssertEqual(activity.movingTime, 0)
        XCTAssertEqual(activity.elapsedTime, 0)
        XCTAssertEqual(activity.totalElevationGain, 0)
        XCTAssertEqual(activity.sportType, "Workout") // falls back to default type when sportType missing
        XCTAssertEqual(activity.timezone, "UTC")
        XCTAssertFalse(activity.hasHeartrate) // default fallback
    }
}
