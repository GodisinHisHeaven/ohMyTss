//
//  Workout.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

/// Individual workout model for deduplication tracking and audit trail
/// Tracks workouts from both Strava and HealthKit sources
@Model
final class Workout {
    /// Unique identifier (stravaId for Strava workouts, healthKitUUID string for HealthKit)
    @Attribute(.unique) var id: String

    /// Date of the workout (start of day for grouping)
    var date: Date

    /// Workout start time
    var startTime: Date

    /// Duration in seconds
    var duration: TimeInterval

    /// Workout type (e.g., "Ride", "Run", "Swim")
    var workoutType: String

    /// Distance in meters (optional)
    var distance: Double?

    /// Calculated Training Stress Score
    var tss: Double

    /// How TSS was calculated ("power", "hr", "duration")
    var calculationMethod: String

    // MARK: - Source Tracking (Critical for Deduplication)

    /// Source of the workout data
    var source: String // "strava" or "healthKit"

    /// Strava activity ID (if from Strava)
    var stravaId: Int?

    /// HealthKit UUID (if from HealthKit)
    var healthKitUUID: String?

    /// Whether this workout is suppressed (duplicate)
    var isSuppressed: Bool

    // MARK: - Metadata

    /// Average power in watts (for cycling)
    var averagePower: Double?

    /// Normalized power in watts (for cycling)
    var normalizedPower: Double?

    /// Average heart rate in bpm
    var averageHeartRate: Double?

    /// Maximum heart rate in bpm
    var maxHeartRate: Double?

    /// Device name that recorded the workout
    var deviceName: String?

    // MARK: - Relationships

    /// Parent day aggregate
    @Relationship var dayAggregate: DayAggregate?

    // MARK: - Initialization

    init(
        id: String,
        date: Date,
        startTime: Date,
        duration: TimeInterval,
        workoutType: String,
        distance: Double? = nil,
        tss: Double,
        calculationMethod: String,
        source: WorkoutSource,
        stravaId: Int? = nil,
        healthKitUUID: String? = nil,
        isSuppressed: Bool = false,
        averagePower: Double? = nil,
        normalizedPower: Double? = nil,
        averageHeartRate: Double? = nil,
        maxHeartRate: Double? = nil,
        deviceName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.duration = duration
        self.workoutType = workoutType
        self.distance = distance
        self.tss = tss
        self.calculationMethod = calculationMethod
        self.source = source.rawValue
        self.stravaId = stravaId
        self.healthKitUUID = healthKitUUID
        self.isSuppressed = isSuppressed
        self.averagePower = averagePower
        self.normalizedPower = normalizedPower
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.deviceName = deviceName
    }
}

// MARK: - Workout Source

enum WorkoutSource: String, Codable {
    case strava
    case healthKit
}
