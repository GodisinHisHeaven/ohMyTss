//
//  HealthKitManager.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit
import CoreLocation

@MainActor
@Observable
class HealthKitManager {
    private let healthStore = HKHealthStore()

    // Published properties for observing state
    var isAuthorized: Bool = false
    var authorizationError: Error?

    // MARK: - Authorization

    /// Check if HealthKit is available on this device
    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request authorization to read HealthKit data
    func requestAuthorization() async throws {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        // Define the data types we want to read
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .cyclingPower)!,
            HKObjectType.quantityType(forIdentifier: .cyclingCadence)!,
            HKObjectType.quantityType(forIdentifier: .runningSpeed)!,
            HKSeriesType.workoutRoute(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
            isAuthorized = true
            authorizationError = nil
        } catch {
            isAuthorized = false
            authorizationError = error
            throw error
        }
    }

    /// Check the authorization status for a specific type
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        healthStore.authorizationStatus(for: type)
    }

    // MARK: - Fetch Workouts

    func fetchWorkouts(ids: [String]) async throws -> [HKWorkout] {
        guard isHealthKitAvailable else { throw HealthKitError.notAvailable }
        let uuids = Set(ids.compactMap(UUID.init(uuidString:)))
        guard !uuids.isEmpty else { return [] }
        return try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: HKQuery.predicateForObjects(with: uuids),
                                      limit: uuids.count, sortDescriptors: nil) { _, samples, error in
                if let error { finish(.failure(error)) }
                else { finish(.success(samples as? [HKWorkout] ?? [])) }
            }
            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    /// Fetch workouts within a date range
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        guard isHealthKitAvailable else { throw HealthKitError.notAvailable }
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    finish(.failure(error))
                    return
                }

                let workouts = samples as? [HKWorkout] ?? []

                // Keep every source UUID. Canonicalization belongs to persistence.
                finish(.success(workouts))
            }

            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    /// Explicit HealthKit tombstones are the only authority for deletion. An empty
    /// query can also mean unreadable data; it must never erase local history.
    func fetchWorkoutChanges(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], deletedIDs: [String], newAnchor: HKQueryAnchor) {
        guard isHealthKitAvailable else { throw HealthKitError.notAvailable }
        return try await HealthQueryExecution.run { finish in
            let query = HKAnchoredObjectQuery(type: .workoutType(), predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) {
                _, samples, deleted, newAnchor, error in
                if let error = error { finish(.failure(error)); return }
                guard let newAnchor = newAnchor else { finish(.failure(HealthKitError.noData)); return }
                finish(.success((samples as? [HKWorkout] ?? [], deleted?.map { $0.uuid.uuidString } ?? [], newAnchor)))
            }
            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    /// Compatibility API. New synchronization consumes fetchWorkoutChanges so
    /// deletions are applied before committing the returned anchor.
    func fetchWorkouts(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor) {
        let changes = try await fetchWorkoutChanges(anchor: anchor)
        return (changes.workouts, changes.newAnchor)
    }

    // MARK: - Workout-associated quantities

    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        try await associatedSamples(.cyclingPower, workout: workout)
    }

    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        try await associatedSamples(.heartRate, workout: workout)
    }

    private func associatedSamples(_ identifier: HKQuantityTypeIdentifier, workout: HKWorkout) async throws -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { throw HealthKitError.invalidType }
        let associated = try await quantitySamples(type, predicate: HKQuery.predicateForObjects(from: workout))
        if !associated.isEmpty { return associated }
        return try await quantitySamples(type, predicate: fallbackPredicate(workout))
    }

    private func quantitySamples(_ type: HKQuantityType, predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error = error { finish(.failure(error)); return }
                finish(.success(samples as? [HKQuantitySample] ?? []))
            }
            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    private func fallbackPredicate(_ workout: HKWorkout) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
            HKQuery.predicateForObjects(from: workout.sourceRevision.source)
        ])
    }

    /// Query individual measurements, including measurements inside merged
    /// HKQuantitySample series. A parent sample's aggregate is never treated as
    /// a continuous reading across its full date range.
    private func series(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, workout: HKWorkout) async throws -> (values: [TimedValue], provenance: String) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { throw HealthKitError.invalidType }
        let associated = try await quantitySeries(type, unit: unit, predicate: HKQuery.predicateForObjects(from: workout))
        if !associated.isEmpty { return (associated, "\(identifier.rawValue): workout-associated quantity series") }
        let fallback = try await quantitySeries(type, unit: unit, predicate: fallbackPredicate(workout))
        return (fallback, fallback.isEmpty
                ? "\(identifier.rawValue): no readable samples; absence is not zero"
                : "\(identifier.rawValue): source-restricted time fallback; association uncertain")
    }

    private func quantitySeries(_ type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async throws -> [TimedValue] {
        try await HealthQueryExecution.run { finish in
            let buffer = HealthQueryBuffer<TimedValue>()
            let query = HKQuantitySeriesSampleQuery(quantityType: type, predicate: predicate) { _, quantity, interval, _, done, error in
                if let error = error {
                    if buffer.finish() != nil { finish(.failure(error)) }
                    return
                }
                if let quantity = quantity, let interval = interval {
                    buffer.append([TimedValue(start: interval.start, end: interval.end, value: quantity.doubleValue(for: unit))])
                }
                if done, let values = buffer.finish() { finish(.success(values)) }
            }
            healthStore.execute(query)
            return {
                _ = buffer.finish()
                Task { @MainActor in self.healthStore.stop(query) }
            }
        }
    }

    func fetchWorkoutFeatures(for workout: HKWorkout) async throws -> WorkoutFeatures {
        var features = WorkoutFeatures()
        features.provenance = ["HealthKit source: \(workout.sourceRevision.source.bundleIdentifier); workout: \(workout.uuid.uuidString)"]
        features.pauses = Self.pauseIntervals(workout)
        features.end = workout.endDate
        // Sensor failures stay local to a channel: a failed power read must not
        // discard a run, a swim, or a successfully read heart-rate stream.
        let channels: [(HKQuantityTypeIdentifier, HKUnit)] = [
            (.heartRate, .count().unitDivided(by: .minute())),
            (.cyclingPower, .watt()), (.cyclingCadence, .count().unitDivided(by: .minute())),
            (.runningSpeed, .meter().unitDivided(by: .second()))
        ]
        for (identifier, unit) in channels {
            try Task.checkCancellation()
            let channel: String
            switch identifier {
            case .heartRate: channel = "heartRate"
            case .cyclingPower: channel = "power"
            case .cyclingCadence: channel = "cadence"
            default: channel = "speed"
            }
            if (identifier == .cyclingPower || identifier == .cyclingCadence), workout.workoutActivityType != .cycling { continue }
            if identifier == .runningSpeed, workout.workoutActivityType != .running { continue }
            do {
                let result = try await series(identifier, unit: unit, workout: workout)
                switch identifier {
                case .heartRate: features.heartRate = result.values
                case .cyclingPower: features.power = result.values
                case .cyclingCadence: features.cadence = result.values
                case .runningSpeed: features.speed = result.values
                default: break
                }
                features.provenance.append(result.provenance)
                if result.values.isEmpty { features.unavailableChannels.append(channel) }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                features.failedChannels.append(channel)
                features.provenance.append("\(identifier.rawValue): sensor query failed; retry sync")
            }
        }
        if workout.workoutActivityType == .running {
            do {
                let locations = try await routeLocations(workout)
                let calculation = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return Self.terrainFeatures(locations)
                }
                let terrain = try await withTaskCancellationHandler {
                    try await calculation.value
                } onCancel: { calculation.cancel() }
                features.elevation = terrain.elevation
                features.grade = terrain.grade
                if locations.isEmpty { features.unavailableChannels.append("terrain") }
                features.provenance.append(locations.isEmpty ? "No readable route; slope unknown" : "Workout-associated route; accuracy filter, median5 altitude and 15 m grade baseline")
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                features.failedChannels.append("terrain")
                features.provenance.append("Route query failed; slope unknown")
            }
        }
        if workout.workoutActivityType == .swimming {
            features.swimSegments = Self.swimSegments(workout)
            features.provenance.append(features.swimSegments.isEmpty ? "Swim stroke and equipment unknown" : "Swim stroke metadata; equipment unknown")
        }
        try Task.checkCancellation()
        return features
    }

    private func routeLocations(_ workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { finish(.failure(error)); return }
                finish(.success(samples as? [HKWorkoutRoute] ?? []))
            }
            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
        var locations: [CLLocation] = []
        for route in routes {
            try Task.checkCancellation()
            let batch: [CLLocation] = try await HealthQueryExecution.run { finish in
                let buffer = HealthQueryBuffer<CLLocation>()
                let query = HKWorkoutRouteQuery(route: route) { _, values, done, error in
                    if let error = error {
                        if buffer.finish() != nil { finish(.failure(error)) }
                        return
                    }
                    buffer.append(values ?? [])
                    if done, let result = buffer.finish() { finish(.success(result)) }
                }
                healthStore.execute(query)
                return {
                    _ = buffer.finish()
                    Task { @MainActor in self.healthStore.stop(query) }
                }
            }
            locations.append(contentsOf: batch)
        }
        return locations
    }

    /// Keep only altitude and grade, never retain location coordinates. Slope
    /// requires a valid accuracy estimate, a >=15 m baseline and <=30 s support.
    nonisolated private static func terrainFeatures(_ locations: [CLLocation]) -> (elevation: [TimedValue], grade: [TimedValue]) {
        let points = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 20 &&
            $0.verticalAccuracy >= 0 && $0.verticalAccuracy <= 10 && $0.altitude.isFinite
        }.sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 5 else { return ([], []) }
        let heights = points.indices.map { i -> Double in
            let start = max(0, i - 2), end = min(points.count - 1, i + 2)
            let values = points[start...end].map(\.altitude).sorted()
            return values[values.count / 2]
        }
        let elevation = points.map { TimedValue(start: $0.timestamp, end: $0.timestamp, value: $0.altitude) }
        var grade: [TimedValue] = []
        var anchor = 0
        for index in 1..<points.count {
            let seconds = points[index].timestamp.timeIntervalSince(points[anchor].timestamp)
            if seconds <= 0 { continue }
            if seconds > 30 { anchor = index; continue }
            let distance = points[index].distance(from: points[anchor])
            guard distance >= 15 else { continue }
            let slope = (heights[index] - heights[anchor]) / distance
            if distance / seconds <= 15, abs(slope) <= 0.5 {
                grade.append(TimedValue(start: points[anchor].timestamp, end: points[index].timestamp, value: slope))
            }
            anchor = index
        }
        return (elevation, grade)
    }

    private static func pauseIntervals(_ workout: HKWorkout) -> [TimeRange] {
        var result: [TimeRange] = []
        var pausedAt: Date?
        for event in (workout.workoutEvents ?? []).sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            switch event.type {
            case .pause, .motionPaused:
                if pausedAt == nil { pausedAt = event.dateInterval.start }
            case .resume, .motionResumed:
                if let start = pausedAt { result.append(TimeRange(start: start, end: event.dateInterval.start)) }
                pausedAt = nil
            default: break
            }
        }
        if let start = pausedAt { result.append(TimeRange(start: start, end: workout.endDate)) }
        return result
    }

    private static func swimSegments(_ workout: HKWorkout) -> [SwimSegment] {
        func stroke(_ metadata: [String: Any]?) -> String? {
            guard let value = metadata?[HKMetadataKeySwimmingStrokeStyle] as? NSNumber else { return nil }
            switch HKSwimmingStrokeStyle(rawValue: value.intValue) ?? .unknown {
            case .freestyle: return "freestyle"
            case .backstroke: return "backstroke"
            case .breaststroke: return "breaststroke"
            case .butterfly: return "butterfly"
            case .mixed: return "mixed"
            case .kickboard: return "kickboard"
            default: return "unknown"
            }
        }
        let segments = (workout.workoutEvents ?? []).compactMap { event -> SwimSegment? in
            guard (event.type == .lap || event.type == .segment), event.dateInterval.duration > 0,
                  let name = stroke(event.metadata) else { return nil }
            return SwimSegment(start: event.dateInterval.start, end: event.dateInterval.end, stroke: name)
        }
        if !segments.isEmpty { return segments }
        if let name = stroke(workout.metadata) { return [SwimSegment(start: workout.startDate, end: workout.endDate, stroke: name)] }
        return []
    }

    func fetchWorkoutStatistics(for workout: HKWorkout, quantityType: HKQuantityType) async throws -> HKStatistics? {
        try await HealthQueryExecution.run { finish in
            let query = HKStatisticsQuery(quantityType: quantityType,
                quantitySamplePredicate: HKQuery.predicateForObjects(from: workout),
                options: [.discreteAverage, .discreteMin, .discreteMax]) { _, statistics, error in
                if let error = error { finish(.failure(error)); return }
                finish(.success(statistics))
            }
            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    // MARK: - HRV and Resting Heart Rate (for future phases)

    /// Fetch HRV samples for a date range
    func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)


        return try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    finish(.failure(error))
                    return
                }

                let hrvSamples = samples as? [HKQuantitySample] ?? []
                finish(.success(hrvSamples))
            }

            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    /// Fetch resting heart rate samples for a date range
    func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)


        return try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(
                sampleType: rhrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    finish(.failure(error))
                    return
                }

                let rhrSamples = samples as? [HKQuantitySample] ?? []
                finish(.success(rhrSamples))
            }

            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    // MARK: - Sleep Analysis

    /// Fetch sleep analysis samples for a date range
    func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await HealthQueryExecution.run { finish in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    finish(.failure(error))
                    return
                }

                let sleepSamples = samples as? [HKCategorySample] ?? []
                finish(.success(sleepSamples))
            }

            healthStore.execute(query)
            return { Task { @MainActor in self.healthStore.stop(query) } }
        }
    }

    // MARK: - Helper Methods

    /// Convert HKQueryAnchor to Data for persistence
    func encodeAnchor(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    /// Convert Data back to HKQueryAnchor
    func decodeAnchor(from data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }


}

// MARK: - HealthKit Errors

enum HealthKitError: LocalizedError {
    case notAvailable
    case notAuthorized
    case invalidType
    case noData

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        case .notAuthorized:
            return "HealthKit access has not been authorized."
        case .invalidType:
            return "Invalid HealthKit data type."
        case .noData:
            return "No data available."
        }
    }
}

/// HealthKit series callbacks may arrive on a background queue. Finish once,
/// even when an error and a terminal callback race.
private final class HealthQueryBuffer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var values: [Value] = []
    nonisolated(unsafe) private var finished = false

    nonisolated init() {}

    nonisolated func append(_ batch: [Value]) {
        lock.lock(); defer { lock.unlock() }
        if !finished { values.append(contentsOf: batch) }
    }

    nonisolated func finish() -> [Value]? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return values
    }
}
