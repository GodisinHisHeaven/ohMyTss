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
    func fetchWorkouts(ids: [String]) async throws -> [HKWorkout]
    func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor)
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
/// Handles deduplication with Garmin priority
@MainActor
final class WorkoutAggregator {

    // Avoid the older Swift runtime's isolated-deinit crash (swiftlang/swift#88036).
    nonisolated deinit {}

    // MARK: - Dependencies

    private let healthKitManager: HealthKitManaging
    private let stravaAuthManager: StravaAuthManaging
    private let dataStore: DataStore
    private let stravaClient: any StravaActivityFetching

    /// All source records, including suppressed aliases, for durable provenance.
    private(set) var latestImportedWorkouts: [Workout] = []
    private(set) var successfulSources: Set<String> = []
    private(set) var warnings: [String] = []
    private(set) var hasRetryableFailures = false
    /// Sources whose workout inventory could not be fully verified this pass.
    private(set) var incompleteWorkoutSources: Set<String> = []
    private(set) var latestDeletedStravaIDs: [String] = []
    private(set) var latestDeletedHealthKitIDs: [String] = []
    private(set) var latestHealthKitAnchor: HKQueryAnchor?
    private(set) var refreshedHealthKitSamples = false
    private(set) var latestHealthKitRetryIDs: Set<String> = []

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
    /// Returns deduplicated workouts with Garmin priority
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [Workout] {
        try await fetchSources(from: startDate, to: endDate) {
            try await self.fetchHealthKitWorkouts(from: startDate, to: endDate)
        }
    }

    func fetchChanges(plan: ActivitySyncPlan, anchor: HKQueryAnchor?, now: Date) async throws {
        latestHealthKitRetryIDs = Set(plan.healthKitRetryIDs)
        _ = try await fetchSources(from: plan.stravaStart, to: now) {
            let changes = try await self.healthKitManager.fetchWorkoutChanges(anchor: anchor)
            var sources = changes.workouts
            if !plan.healthKitRetryIDs.isEmpty {
                do {
                    let retry = try await self.healthKitManager.fetchWorkouts(ids: Array(plan.healthKitRetryIDs.prefix(20)))
                    let changed = Set(sources.map(\.uuid))
                    sources += retry.filter { !changed.contains($0.uuid) }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    self.recordRetryableWarning("HealthKit sample retry unavailable. Saved samples retained.")
                }
            }
            self.refreshedHealthKitSamples = anchor == nil
            if anchor != nil && plan.refreshHealthKitSamples {
                do {
                    // Some devices append sensor samples after saving the workout.
                    // Refresh only two recent days, at most once every six hours.
                    let recent = try await self.healthKitManager.fetchWorkouts(from: now.addingDays(-2), to: now)
                    let changed = Set(sources.map(\.uuid))
                    sources += recent.filter { !changed.contains($0.uuid) }
                    self.refreshedHealthKitSamples = true
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    self.incompleteWorkoutSources.insert(WorkoutSource.healthKit.rawValue)
                    self.recordRetryableWarning("Recent HealthKit samples could not refresh. Saved samples retained; retry sync.")
                }
            }
            let rows = try await self.convertHealthKitWorkouts(sources)
            self.latestDeletedHealthKitIDs = changes.deletedIDs
            self.latestHealthKitRetryIDs.subtract(changes.deletedIDs)
            if !self.latestHealthKitRetryIDs.isEmpty { self.hasRetryableFailures = true }
            self.latestHealthKitAnchor = changes.newAnchor
            return rows
        }
    }

    private func recordRetryableWarning(_ message: String) {
        warnings.append(message)
        hasRetryableFailures = true
    }

    private func fetchSources(from startDate: Date, to endDate: Date,
                              healthKit: () async throws -> [Workout]) async throws -> [Workout] {
        latestImportedWorkouts = []
        latestDeletedStravaIDs = []
        latestDeletedHealthKitIDs = []
        latestHealthKitAnchor = nil
        refreshedHealthKitSamples = false
        successfulSources = []
        warnings = []
        hasRetryableFailures = false
        incompleteWorkoutSources = []
        var hkWorkouts: [Workout] = []
        var stravaWorkouts: [Workout] = []
        var sourceErrors: [Error] = []
        do {
            hkWorkouts = try await healthKit()
            successfulSources.insert(WorkoutSource.healthKit.rawValue)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            sourceErrors.append(error)
            recordRetryableWarning("HealthKit is unavailable or unreadable. Saved history is retained; retry sync.")
        }
        let stravaConnected = try dataStore.fetchStravaAuth()?.isConnected == true
        if stravaConnected {
            do {
                stravaWorkouts = try await fetchStravaWorkouts(from: startDate, to: endDate)
                successfulSources.insert(WorkoutSource.strava.rawValue)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                sourceErrors.append(error)
                recordRetryableWarning("Strava could not sync. Saved history is retained; check your connection and retry.")
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
            try Task.checkCancellation()
            var features: WorkoutFeatures
            do { features = try await healthKitManager.fetchWorkoutFeatures(for: hkWorkout) }
            catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                features = WorkoutFeatures()
                features.failedChannels = ["heartRate", "power", "cadence", "speed", "terrain"]
                features.provenance = ["Sensor query failed; retry sync"]
            }
            features.end = hkWorkout.endDate
            if features.failedChannels.isEmpty { latestHealthKitRetryIDs.remove(hkWorkout.uuid.uuidString) }
            else { latestHealthKitRetryIDs.insert(hkWorkout.uuid.uuidString) }
            let input = features
            let start = hkWorkout.startDate, end = hkWorkout.endDate, duration = hkWorkout.duration
            let cycling = hkWorkout.workoutActivityType == .cycling
            let ftp = thresholds.cyclingFTP, maxHR = thresholds.maxHeartRate
            let calculation = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try WorkoutImportCalculation(features: input, start: start, end: end, duration: duration,
                                                    cycling: cycling, ftp: ftp, maxHR: maxHR)
            }
            let value = try await withTaskCancellationHandler {
                try await calculation.value
            } onCancel: { calculation.cancel() }
            try Task.checkCancellation()
            let workout = Workout(
                id: hkWorkout.uuid.uuidString, date: hkWorkout.startDate.startOfDay,
                startTime: hkWorkout.startDate, duration: hkWorkout.duration,
                workoutType: Self.workoutTypeName(for: hkWorkout.workoutActivityType),
                distance: hkWorkout.totalDistance?.doubleValue(for: .meter()),
                tss: value.tss.isFinite ? value.tss : 0, calculationMethod: value.method, source: .healthKit,
                healthKitUUID: hkWorkout.uuid.uuidString,
                averagePower: value.averagePower, normalizedPower: value.normalizedPower,
                averageHeartRate: value.averageHeartRate, maxHeartRate: value.maxHeartRate,
                deviceName: hkWorkout.device?.name
            )
            workout.sourceBundleIdentifier = hkWorkout.sourceRevision.source.bundleIdentifier
            workout.deviceManufacturer = hkWorkout.device?.manufacturer
            workout.featuresData = value.featuresData
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
            try Task.checkCancellation()
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
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                incompleteWorkoutSources.insert(WorkoutSource.strava.rawValue)
                recordRetryableWarning("A missing Strava activity could not be verified. Its saved source and your records are retained; retry sync.")
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
            try Task.checkCancellation()
            if workouts.count % 25 == 0 { try await Task.sleep(for: .milliseconds(1)) }
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

    /// Classify only explicit Garmin identity; missing metadata is unknown.
    static func isGarminSource(_ workout: Workout) -> Bool {
        isGarminSource(source: workout.source, bundleIdentifier: workout.sourceBundleIdentifier,
                       manufacturer: workout.deviceManufacturer, deviceName: workout.deviceName)
    }

    nonisolated static func isGarminSource(source: String, bundleIdentifier: String?, manufacturer: String?, deviceName: String?) -> Bool {
        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let maker = manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if source == WorkoutSource.healthKit.rawValue {
            return bundle.hasPrefix("com.garmin.") || maker == "garmin"
        }
        if source == WorkoutSource.strava.rawValue {
            let device = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return device == "garmin" || device.hasPrefix("garmin ") || device.hasPrefix("garmin-")
        }
        return false
    }

    /// Prefer Garmin HealthKit data, then Garmin Strava, then other Strava data.
    static func sourcePriority(_ workout: Workout) -> Int {
        if isGarminSource(workout) { return workout.source == WorkoutSource.healthKit.rawValue ? 3 : 2 }
        return workout.source == WorkoutSource.strava.rawValue ? 1 : 0
    }

    /// Use the same groups and source priority as persistent reconciliation.
    func deduplicateWorkouts(healthKit: [Workout], strava: [Workout]) -> [Workout] {
        let incoming = strava + healthKit
        for row in incoming { row.isSuppressed = false }
        for members in DataStore.matchingWorkoutGroups(incoming) {
            let canonical = members.sorted {
                let left = Self.sourcePriority($0), right = Self.sourcePriority($1)
                return left == right ? $0.id < $1.id : left > right
            }.first
            for row in members where row.id != canonical?.id { row.isSuppressed = true }
        }
        return incoming.filter { !$0.isSuppressed }
    }

    /// Match only across external sources. Source IDs handle repeat imports;
    /// similar workouts from the same source are not proof of duplication.
    static func areDuplicates(_ first: Workout, _ second: Workout) -> Bool {
        let sources = Set([first.source, second.source])
        guard sources == Set([WorkoutSource.healthKit.rawValue, WorkoutSource.strava.rawValue]) else { return false }
        let type = normalizeWorkoutType(first.workoutType)
        guard !type.isEmpty, type != "other", type == normalizeWorkoutType(second.workoutType) else { return false }
        return hasMatchingTiming(first, second)
    }

    /// Used for both definite matches and unknown-type ambiguity checks.
    static func hasMatchingTiming(_ first: Workout, _ second: Workout) -> Bool {
        guard abs(first.startTime.timeIntervalSince(second.startTime)) < 60,
              first.duration.isFinite, second.duration.isFinite,
              first.duration > 0, second.duration > 0 else { return false }
        // Strava records moving time as duration; HealthKit can include pauses.
        // Where both ends are present they must agree, even when moving times match.
        if let firstEnd = first.features.end, let secondEnd = second.features.end {
            let firstElapsed = firstEnd.timeIntervalSince(first.startTime)
            let secondElapsed = secondEnd.timeIntervalSince(second.startTime)
            return firstElapsed.isFinite && secondElapsed.isFinite && firstElapsed > 0 && secondElapsed > 0
                && abs(firstElapsed - secondElapsed) < 5
        }
        return abs(first.duration - second.duration) < 5
    }

    /// Normalize workout type for comparison
    /// Maps similar types to same value (e.g., "Ride" and "Cycling" both become "cycling")
    static func normalizeWorkoutType(_ type: String) -> String {
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
        } else if lowercased == "hike" || lowercased == "hiking" {
            return "hiking"
        }

        return lowercased
    }

    // MARK: - Helper Methods

    /// Get workout type name from HKWorkoutActivityType
    static func workoutTypeName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .swimming:
            return "Swimming"
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .yoga:
            return "Yoga"
        case .pilates:
            return "Pilates"
        case .elliptical:
            return "Elliptical"
        case .rowing:
            return "Rowing"
        case .stairClimbing:
            return "StairClimbing"
        case .crossTraining:
            return "CrossTraining"
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return "Strength"
        default:
            return "Other"
        }
    }

    /// Calculate TSS from Strava activity data
    private func calculateTSSFromStrava(activity: StravaActivity, userFTP: Int?, userMaxHR: Int?) -> (value: Double, method: String) {
        // Prefer power-based if available
        if Self.normalizeWorkoutType(activity.sportType) == "cycling", activity.hasPowerData,
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
