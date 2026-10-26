//
//  WorkoutAggregator.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit

// MARK: - Protocols for dependency injection (test-friendly)

@MainActor
protocol HealthKitManaging: AnyObject {
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout]
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample]
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample]
    func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures
}

// Existing adapters can still conform, while the production manager overrides
// this method with quantity-series expansion and provenance-aware queries.
extension HealthKitManaging {
    func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        var features = WorkoutFeatures()
        features.end = workout.endDate
        let power = try await fetchPowerSamples(for: workout)
        let heartRate = try await fetchHeartRateSamples(for: workout)
        features.power = power.filter { $0.count == 1 }.map {
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: .watt()))
        }
        features.heartRate = heartRate.filter { $0.count == 1 }.map {
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
        }
        features.provenance = ["Adapter quantities; merged series require a quantity-series capable source"]
        return features
    }
}

@MainActor
protocol StravaAuthManaging: AnyObject {
    func getValidAccessToken() async throws -> String
}

@MainActor
protocol StravaActivityFetching {
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity]
    func activity(accessToken: String, id: Int) async throws -> StravaActivity?
}

@MainActor
struct StravaActivityClient: StravaActivityFetching {
    func activities(accessToken: String, after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivity] {
        try await StravaAPI.getActivities(accessToken: accessToken, after: after, before: before, page: page, perPage: perPage)
    }
    func activity(accessToken: String, id: Int) async throws -> StravaActivity? {
        try await StravaAPI.getActivity(accessToken: accessToken, activityID: id)
    }
}

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

    private let healthKitManager: HealthKitManaging
    private let stravaAuthManager: StravaAuthManaging
    private let dataStore: DataStore
    private let stravaClient: any StravaActivityFetching

    /// All source records, including suppressed aliases, for durable provenance.
    private(set) var latestImportedWorkouts: [Workout] = []
    private(set) var successfulSources: Set<String> = []
    private(set) var warnings: [String] = []
    private(set) var latestDeletedStravaIDs: [String] = []

    // MARK: - Initialization

    init(
        healthKitManager: HealthKitManaging,
        stravaAuthManager: StravaAuthManaging,
        dataStore: DataStore,
        stravaClient: (any StravaActivityFetching)? = nil
    ) {
        self.healthKitManager = healthKitManager
        self.stravaAuthManager = stravaAuthManager
        self.dataStore = dataStore
        self.stravaClient = stravaClient ?? StravaActivityClient()
    }

    // MARK: - Fetch Workouts

    /// Fetch all workouts from both sources (Strava + HealthKit)
    /// Returns deduplicated workouts with Strava priority
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        latestImportedWorkouts = []
        latestDeletedStravaIDs = []
        successfulSources = []
        warnings = []
        var hkWorkouts: [Workout] = []
        var stravaWorkouts: [Workout] = []
        var sourceErrors: [Error] = []
        do {
            hkWorkouts = try await fetchHealthKitWorkouts(from: startDate, to: endDate)
            successfulSources.insert(WorkoutSource.healthKit.rawValue)
        } catch {
            sourceErrors.append(error)
            warnings.append("HealthKit is unavailable or unreadable. Saved history is retained; retry sync.")
        }
        let stravaConnected = try dataStore.fetchStravaAuth()?.isConnected == true
        if stravaConnected {
            do {
                stravaWorkouts = try await fetchStravaWorkouts(from: startDate, to: endDate)
                successfulSources.insert(WorkoutSource.strava.rawValue)
            } catch {
                sourceErrors.append(error)
                warnings.append("Strava could not sync. Saved history is retained; check your connection and retry.")
            }
        }
        if successfulSources.isEmpty, let error = sourceErrors.first { throw error }
        let active = deduplicateWorkouts(healthKit: hkWorkouts, strava: stravaWorkouts)
        latestImportedWorkouts = hkWorkouts + stravaWorkouts
        return active.sorted { $0.startTime < $1.startTime }
    }

    private func fetchHealthKitWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        let source = try await healthKitManager.fetchWorkouts(from: startDate, to: endDate)
        return try await convertHealthKitWorkouts(source)
    }

    /// Also accepts additions from an anchored query, including corrections to
    /// activities older than the normal refresh window.
    func convertHealthKitWorkouts(_ source: [HKWorkout]) async throws -> [Workout] {
        let thresholds = try dataStore.fetchUserThresholds()
        var workouts: [Workout] = []
        for hkWorkout in source {
            var features: WorkoutFeatures
            do { features = try await healthKitManager.fetchWorkoutFeatures(for: hkWorkout) }
            catch {
                features = WorkoutFeatures()
                features.failedChannels = ["heartRate", "power", "cadence", "speed", "terrain"]
                features.provenance = ["Sensor query failed; retry sync"]
            }
            features.end = hkWorkout.endDate
            let window = TimeRange(start: hkWorkout.startDate, end: hkWorkout.endDate)
            let power = SignalProcessing.intervals(samples: features.power, window: window, pauses: features.pauses, validRange: 0...2500)
            let heartRate = SignalProcessing.intervals(samples: features.heartRate, window: window, pauses: features.pauses, validRange: 30...240)
            let np = SignalProcessing.normalizedPower(power)
            let tss: Double
            let method: String
            if hkWorkout.workoutActivityType == .cycling, let ftp = thresholds.cyclingFTP, ftp > 0, let np = np {
                // Partial coverage contributes only its observed duration. It is
                // never extrapolated through pauses or missing sensor intervals.
                tss = SignalProcessing.coveredSeconds(power) / 3600 * pow(np / Double(ftp), 2) * 100
                method = "power-time-v2"
            } else if !heartRate.isEmpty, let maxHR = thresholds.maxHeartRate, maxHR > 60 {
                tss = TSSCalculator.legacyHeartRateTSS(intervals: heartRate, maxHeartRate: maxHR, restingHeartRate: 60)
                method = "hr-time-v2 (resting HR assumed 60)"
            } else {
                tss = max(0, hkWorkout.duration) / 3600 * 60
                method = "duration estimate"
            }
            let workout = Workout(
                id: hkWorkout.uuid.uuidString, date: hkWorkout.startDate.startOfDay,
                startTime: hkWorkout.startDate, duration: hkWorkout.duration,
                workoutType: workoutTypeName(for: hkWorkout.workoutActivityType),
                distance: hkWorkout.totalDistance?.doubleValue(for: .meter()),
                tss: tss.isFinite ? tss : 0, calculationMethod: method, source: .healthKit,
                healthKitUUID: hkWorkout.uuid.uuidString,
                averagePower: SignalProcessing.weightedMean(power), normalizedPower: np,
                averageHeartRate: SignalProcessing.weightedMean(heartRate), maxHeartRate: heartRate.map(\.value).max(),
                deviceName: hkWorkout.device?.name
            )
            workout.features = features
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
            let activities = try await stravaClient.activities(
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

        // Only a completed, paginated listing may nominate missing sources for
        // verification. Day-grouped local fetches are narrowed to the exact API
        // epoch boundaries so adjacent-day or boundary activities are not removed.
        var unavailableSourceIDs: [String] = []
        let returnedIDs = Set(allActivities.map(\.id))
        let after = Date(timeIntervalSince1970: Double(Int(startDate.timeIntervalSince1970)))
        let before = Date(timeIntervalSince1970: Double(Int(endDate.timeIntervalSince1970)))
        let known = try dataStore.fetchWorkouts(from: startDate, to: endDate, includeSupressed: true).filter {
            $0.source == WorkoutSource.strava.rawValue && !$0.isTombstoned &&
            $0.startTime > after && $0.startTime < before &&
            $0.stravaId.map { !returnedIDs.contains($0) } == true
        }
        for source in known {
            guard let id = source.stravaId else { continue }
            do {
                if let corrected = try await stravaClient.activity(accessToken: accessToken, id: id) {
                    // A corrected start date can move an existing activity out
                    // of the queried window. Updating it clears the old day's TSS.
                    allActivities.append(corrected)
                } else {
                    unavailableSourceIDs.append(source.id)
                }
            } catch {
                warnings.append("A missing Strava activity could not be verified. Its saved source and your records are retained; retry sync.")
                // Avoid repeated requests after a rate-limit, connection or
                // authorization failure. Unchecked sources remain untouched.
                break
            }
        }
        if !unavailableSourceIDs.isEmpty {
            warnings.append("Strava returned not found for previously imported sources. Their load contributions are removed; personal logs are retained. This may reflect source deletion or changed visibility.")
        }

        // Get user thresholds
        let thresholds = try dataStore.fetchUserThresholds()

        // Thresholds apply only to their sport. Unknown cycling FTP does not
        // prevent other activities (or cycling history itself) from importing.
        let ftp: Int?
        if thresholds.preferStravaFTP, let value = thresholds.stravaFTP, value > 0 { ftp = value }
        else { ftp = thresholds.cyclingFTP.flatMap { $0 > 0 ? $0 : nil } }

        // Convert to Workout models
        var workouts: [Workout] = []

        for activity in allActivities {
            // Skip malformed activities (e.g., missing id/start time) to avoid decode crashes further downstream
            guard activity.id > 0, let startTime = activity.startDateTime else {
                continue
            }

            // Calculate TSS from Strava data
            let tss = calculateTSSFromStrava(
                activity: activity,
                userFTP: ftp,
                userMaxHR: thresholds.maxHeartRate
            )

            let workout = Workout(
                id: "\(activity.id)", // Strava ID as string
                date: startTime.startOfDay,
                startTime: startTime,
                duration: TimeInterval(max(0, activity.movingTime)),
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

            var features = WorkoutFeatures()
            features.end = startTime.addingTimeInterval(Double(max(activity.elapsedTime, activity.movingTime)))
            features.provenance = ["Strava activity summary; no timestamped HR, power or cadence stream. Cardio Load is unknown until supported samples are available."]
            // Strava summaries cannot supply co-timed power/cadence or a grade
            // distribution. Do not create fake constant time series from means.
            workout.features = features
            workouts.append(workout)
        }

        latestDeletedStravaIDs = unavailableSourceIDs
        return workouts
    }

    // MARK: - Deduplication

    /// Deduplicate workouts with Strava priority
    /// Uses same criteria as HealthKit deduplication: time, duration, type
    func deduplicateWorkouts(healthKit: [Workout], strava: [Workout]) -> [Workout] {
        var result: [Workout] = []
        // Reset incoming snapshots; persistence also reconciles against prior
        // imports and keeps manual associations separate from this heuristic.
        for workout in strava + healthKit { workout.isSuppressed = false }
        for workout in strava + healthKit {
            if result.contains(where: { areDuplicates(workout1: workout, workout2: $0) }) {
                workout.isSuppressed = true
            } else { result.append(workout) }
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
        } else if lowercased.contains("strength") || lowercased.contains("weighttraining") {
            return "strength"
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
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return "Strength"
        default:
            return "Other"
        }
    }

    /// Calculate TSS from Strava activity data
    private func calculateTSSFromStrava(activity: StravaActivity, userFTP: Int?, userMaxHR: Int?) -> (value: Double, method: String) {
        // Prefer power-based if available
        if normalizeWorkoutType(activity.sportType) == "cycling", activity.hasPowerData,
           let np = activity.weightedAverageWatts, np >= 0,
           let userFTP = userFTP, userFTP > 0 {
            // Use Strava's weighted average watts (their NP equivalent)
            let intensityFactor = Double(np) / Double(userFTP)
            let durationHours = Double(max(0, activity.movingTime)) / 3600.0
            let tss = durationHours * Double(np) * intensityFactor / Double(userFTP) * 100

            return (tss, "power")
        }

        // Fall back to HR-based if available
        if activity.hasHeartrate, let avgHR = activity.averageHeartrate, avgHR.isFinite,
           let userMaxHR = userMaxHR, userMaxHR > 60 {
            let hrRatio = min(1, max(0, (avgHR - 60) / (Double(userMaxHR) - 60)))
            let durationMinutes = Double(max(0, activity.movingTime)) / 60.0

            // TRIMP calculation
            let exerciseTRIMP = durationMinutes * hrRatio * exp(1.92 * hrRatio)
            let oneHourFTPTRIMP = 60.0 * 0.85 * exp(1.92 * 0.85)
            let hrTSS = (exerciseTRIMP / oneHourFTPTRIMP) * 100.0

            return (hrTSS, "hr summary estimate")
        }

        // Fall back to duration estimate
        let durationHours = Double(max(0, activity.movingTime)) / 3600.0
        let estimatedTSS = durationHours * 60 // Very rough estimate

        return (max(0, estimatedTSS), "duration estimate")
    }
}

// MARK: - Concrete conformances

extension HealthKitManager: HealthKitManaging {}
extension StravaAuthManager: StravaAuthManaging {}
