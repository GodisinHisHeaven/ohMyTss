//
//  UserThresholds.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

enum Sport: String, Codable {
    case cycling
    case running
    case swimming
    // Future: Add more sports in v1.0
}

enum UnitSystem: String, Codable {
    case metric
    case imperial
}

@Model
final class UserThresholds {
    @Attribute(.unique) var id: String

    // Cycling thresholds
    var cyclingFTP: Int? // Functional Threshold Power (watts)

    // Strava integration
    var stravaFTP: Int? // FTP from Strava athlete profile
    var preferStravaFTP: Bool // Whether to use Strava FTP over manual FTP

    // Heart rate
    var maxHeartRate: Int? // Maximum heart rate (bpm)

    // Running thresholds (future v1.0)
    var runningLTPace: Int? // Lactate Threshold Pace (seconds per km)
    var runningLTHeartRate: Int? // LT Heart Rate (bpm)

    // Swimming thresholds (future v1.0)
    var swimmingLTPace: Int? // Lactate Threshold Pace (seconds per 100m)

    // User preferences
    var preferredUnitSystem: UnitSystem
    var preferredSports: [Sport]

    // App settings
    var hasCompletedOnboarding: Bool
    var lastModified: Date

    init(
        id: String = "user_thresholds",
        cyclingFTP: Int? = nil,
        stravaFTP: Int? = nil,
        preferStravaFTP: Bool = false,
        maxHeartRate: Int? = 190,
        runningLTPace: Int? = nil,
        runningLTHeartRate: Int? = nil,
        swimmingLTPace: Int? = nil,
        preferredUnitSystem: UnitSystem = .metric,
        preferredSports: [Sport] = [.cycling],
        hasCompletedOnboarding: Bool = false,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.cyclingFTP = cyclingFTP
        self.stravaFTP = stravaFTP
        self.preferStravaFTP = preferStravaFTP
        self.maxHeartRate = maxHeartRate
        self.runningLTPace = runningLTPace
        self.runningLTHeartRate = runningLTHeartRate
        self.swimmingLTPace = swimmingLTPace
        self.preferredUnitSystem = preferredUnitSystem
        self.preferredSports = preferredSports
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastModified = lastModified
    }
}
