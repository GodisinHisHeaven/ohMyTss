//
//  StravaDecodingTests.swift
//  onMyTssTests
//
//  Created by Codex.
//

import XCTest
@testable import onMyTss

final class StravaDecodingTests: XCTestCase {

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
