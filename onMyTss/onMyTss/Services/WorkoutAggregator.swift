//
//  WorkoutAggregator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit

/// TSS calculation method
enum TSSMethod: String {
    case power
    case hr
    case duration
}

/// Aggregates workouts from Strava and HealthKit
/// Handles deduplication with Strava priority
@MainActor
final class WorkoutAggregator {

    // MARK: - Dependencies

    private let healthKitManager: HealthKitManager
    private let stravaAuthManager: StravaAuthManager
    private let dataStore: DataStore

    // MARK: - Initialization

    init(
        healthKitManager: HealthKitManager,
        stravaAuthManager: StravaAuthManager,
        dataStore: DataStore
    ) {
        self.healthKitManager = healthKitManager
        self.stravaAuthManager = stravaAuthManager
        self.dataStore = dataStore
    }

    // MARK: - Fetch Workouts

    /// Fetch all workouts from both sources (Strava + HealthKit)
    /// Returns deduplicated workouts with Strava priority
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        // Fetch from both sources in parallel
        // Note: Strava errors are silently caught to avoid breaking the entire sync
        async let healthKitWorkouts = fetchHealthKitWorkouts(from: startDate, to: endDate)
        async let stravaWorkouts = fetchStravaWorkoutsSafely(from: startDate, to: endDate)

        let (hkWorkouts, stWorkouts) = try await (healthKitWorkouts, stravaWorkouts)

        // Combine and deduplicate
        return deduplicateWorkouts(healthKit: hkWorkouts, strava: stWorkouts)
    }

    /// Safely fetch Strava workouts without throwing errors
    /// Returns empty array if Strava is not configured or fails
    private func fetchStravaWorkoutsSafely(from startDate: Date, to endDate: Date) async -> [Workout] {
        do {
            return try await fetchStravaWorkouts(from: startDate, to: endDate)
        } catch {
            // Silently fail - Strava is optional
            // Log error for debugging but don't propagate to UI
            print("⚠️ Strava sync failed (this is OK if Strava is not configured): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private Fetch Methods

    /// Fetch workouts from HealthKit and convert to Workout models
    private func fetchHealthKitWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        let hkWorkouts = try await healthKitManager.fetchWorkouts(from: startDate, to: endDate)

        // Get user thresholds for TSS calculation
        let thresholds = try dataStore.fetchUserThresholds()

        // Need FTP to calculate TSS
        guard let ftp = thresholds.cyclingFTP, ftp > 0 else {
            return []
        }

        var workouts: [Workout] = []

        for hkWorkout in hkWorkouts {
            // Fetch power and heart rate samples
            let powerSamples = try await healthKitManager.fetchPowerSamples(for: hkWorkout)
            let heartRateSamples = try await healthKitManager.fetchHeartRateSamples(for: hkWorkout)

            // Calculate TSS (power-based preferred, fall back to HR-based)
            let tssResult: (tss: Double, method: TSSMethod)

            if !powerSamples.isEmpty {
                let tss = TSSCalculator.calculateTSS(
                    powerSamples: powerSamples,
                    ftp: ftp,
                    duration: hkWorkout.duration
                )
                tssResult = (tss, .power)
            } else if !heartRateSamples.isEmpty {
                let tss = TSSCalculator.calculateTSSFromHeartRate(
                    heartRateSamples: heartRateSamples,
                    duration: hkWorkout.duration,
                    maxHeartRate: thresholds.maxHeartRate,
                    restingHeartRate: nil
                )
                tssResult = (tss, .hr)
            } else {
                // Fall back to duration estimate
                let durationHours = hkWorkout.duration / 3600.0
                let estimatedTSS = durationHours * 60
                tssResult = (estimatedTSS, .duration)
            }

            // Convert to Workout model
            let workout = Workout(
                id: hkWorkout.uuid.uuidString,
                date: hkWorkout.startDate.startOfDay,
                startTime: hkWorkout.startDate,
                duration: hkWorkout.duration,
                workoutType: workoutTypeName(for: hkWorkout.workoutActivityType),
                distance: hkWorkout.totalDistance?.doubleValue(for: .meter()),
                tss: tssResult.tss,
                calculationMethod: tssResult.method.rawValue,
                source: .healthKit,
                stravaId: nil,
                healthKitUUID: hkWorkout.uuid.uuidString,
                isSuppressed: false,
                averagePower: extractPower(from: powerSamples),
                normalizedPower: nil, // HealthKit doesn't store NP
                averageHeartRate: averageHeartRate(from: heartRateSamples),
                maxHeartRate: maxHeartRate(from: heartRateSamples),
                deviceName: hkWorkout.device?.name
            )

            workouts.append(workout)
        }

        return workouts
    }

    /// Fetch workouts from Strava and convert to Workout models
    private func fetchStravaWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        // Check if Strava is connected
        guard let auth = try dataStore.fetchStravaAuth(),
              auth.isConnected else {
            return [] // Strava not connected, return empty
        }

        // Get valid access token
        let accessToken = try await stravaAuthManager.getValidAccessToken()

        // Fetch activities from Strava API
        var allActivities: [StravaActivity] = []
        var page = 1
        let perPage = 200

        // Paginate through activities
        while true {
            let activities = try await StravaAPI.getActivities(
                accessToken: accessToken,
                after: startDate,
                before: endDate,
                page: page,
                perPage: perPage
            )

            if activities.isEmpty {
                break
            }

            allActivities.append(contentsOf: activities)

            if activities.count < perPage {
                break // Last page
            }

            page += 1
        }

        // Get user thresholds
        let thresholds = try dataStore.fetchUserThresholds()

        // Determine which FTP to use
        let ftp: Int
        if thresholds.preferStravaFTP, let stravaFTP = thresholds.stravaFTP, stravaFTP > 0 {
            ftp = stravaFTP
        } else if let cyclingFTP = thresholds.cyclingFTP, cyclingFTP > 0 {
            ftp = cyclingFTP
        } else {
            return [] // No valid FTP
        }

        // Convert to Workout models
        var workouts: [Workout] = []

        for activity in allActivities {
            guard let startTime = activity.startDateTime else {
                continue
            }

            // Calculate TSS from Strava data
            let tss = calculateTSSFromStrava(
                activity: activity,
                userFTP: ftp,
                userMaxHR: thresholds.maxHeartRate ?? 190
            )

            let workout = Workout(
                id: "\(activity.id)", // Strava ID as string
                date: startTime.startOfDay,
                startTime: startTime,
                duration: TimeInterval(activity.movingTime),
                workoutType: activity.sportType,
                distance: activity.distance,
                tss: tss.value,
                calculationMethod: tss.method,
                source: .strava,
                stravaId: activity.id,
                healthKitUUID: nil,
                isSuppressed: false,
                averagePower: activity.averageWatts,
                normalizedPower: activity.weightedAverageWatts != nil ? Double(activity.weightedAverageWatts!) : nil,
                averageHeartRate: activity.averageHeartrate,
                maxHeartRate: activity.maxHeartrate,
                deviceName: activity.deviceName
            )

            workouts.append(workout)
        }

        return workouts
    }

    // MARK: - Deduplication

    /// Deduplicate workouts with Strava priority
    /// Uses same criteria as HealthKit deduplication: time, duration, type
    private func deduplicateWorkouts(healthKit: [Workout], strava: [Workout]) -> [Workout] {
        var result: [Workout] = []

        // Add all Strava workouts first (they have priority)
        result.append(contentsOf: strava)

        // Add HealthKit workouts only if not duplicates
        for hkWorkout in healthKit {
            let isDuplicate = strava.contains { stravaWorkout in
                areDuplicates(workout1: hkWorkout, workout2: stravaWorkout)
            }

            if !isDuplicate {
                result.append(hkWorkout)
            }
            // Note: Suppressed duplicates are not included in results
            // They're filtered out to avoid confusion in UI
        }

        return result
    }

    /// Check if two workouts are duplicates
    /// Same criteria as HealthKit deduplication:
    /// - Same workout type
    /// - Start times within 60 seconds
    /// - Durations within 5 seconds
    private func areDuplicates(workout1: Workout, workout2: Workout) -> Bool {
        // Check workout type match
        guard normalizeWorkoutType(workout1.workoutType) == normalizeWorkoutType(workout2.workoutType) else {
            return false
        }

        // Check start time (within 60 seconds)
        let timeDiff = abs(workout1.startTime.timeIntervalSince(workout2.startTime))
        guard timeDiff < 60 else {
            return false
        }

        // Check duration (within 5 seconds)
        let durationDiff = abs(workout1.duration - workout2.duration)
        guard durationDiff < 5 else {
            return false
        }

        return true
    }

    /// Normalize workout type for comparison
    /// Maps similar types to same value (e.g., "Ride" and "Cycling" both become "cycling")
    private func normalizeWorkoutType(_ type: String) -> String {
        let lowercased = type.lowercased()

        if lowercased.contains("cycl") || lowercased.contains("bike") || lowercased.contains("ride") {
            return "cycling"
        } else if lowercased.contains("run") {
            return "running"
        } else if lowercased.contains("swim") {
            return "swimming"
        } else if lowercased.contains("walk") {
            return "walking"
        }

        return lowercased
    }

    // MARK: - Helper Methods

    /// Get workout type name from HKWorkoutActivityType
    private func workoutTypeName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .swimming:
            return "Swimming"
        case .walking:
            return "Walking"
        default:
            return "Other"
        }
    }

    /// Extract average power from power samples
    private func extractPower(from powerSamples: [HKQuantitySample]) -> Double? {
        guard !powerSamples.isEmpty else { return nil }

        let sum = powerSamples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .watt()) }
        return sum / Double(powerSamples.count)
    }

    /// Calculate average heart rate from samples
    private func averageHeartRate(from samples: [HKQuantitySample]) -> Double? {
        guard !samples.isEmpty else { return nil }

        let sum = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }
        return sum / Double(samples.count)
    }

    /// Calculate max heart rate from samples
    private func maxHeartRate(from samples: [HKQuantitySample]) -> Double? {
        return samples.map { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }.max()
    }

    /// Calculate TSS from Strava activity data
    private func calculateTSSFromStrava(activity: StravaActivity, userFTP: Int, userMaxHR: Int) -> (value: Double, method: String) {
        // Prefer power-based if available
        if activity.hasPowerData,
           let np = activity.weightedAverageWatts {
            // Use Strava's weighted average watts (their NP equivalent)
            let intensityFactor = Double(np) / Double(userFTP)
            let durationHours = Double(activity.movingTime) / 3600.0
            let tss = durationHours * Double(np) * intensityFactor / Double(userFTP) * 100

            return (tss, "power")
        }

        // Fall back to HR-based if available
        if activity.hasHeartrate, let avgHR = activity.averageHeartrate {
            let hrRatio = (avgHR - 60) / (Double(userMaxHR) - 60)
            let durationMinutes = Double(activity.movingTime) / 60.0

            // TRIMP calculation
            let exerciseTRIMP = durationMinutes * hrRatio * exp(1.92 * hrRatio)
            let oneHourFTPTRIMP = 60.0 * 0.85 * exp(1.92 * 0.85)
            let hrTSS = (exerciseTRIMP / oneHourFTPTRIMP) * 100.0

            return (hrTSS, "hr")
        }

        // Fall back to duration estimate
        let durationHours = Double(activity.movingTime) / 3600.0
        let estimatedTSS = durationHours * 60 // Very rough estimate

        return (estimatedTSS, "duration")
    }
}
