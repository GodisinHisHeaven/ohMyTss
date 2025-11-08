//
//  HealthKitManager.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import HealthKit

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
            HKObjectType.quantityType(forIdentifier: .cyclingCadence)!
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

    /// Fetch workouts within a date range
    func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = samples as? [HKWorkout] ?? []
                continuation.resume(returning: workouts)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch workouts using an anchored query (for incremental syncs)
    func fetchWorkouts(anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor) {
        let workoutType = HKObjectType.workoutType()

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: workoutType,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, addedSamples, deletedSamples, newAnchor, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = addedSamples as? [HKWorkout] ?? []
                continuation.resume(returning: (workouts, newAnchor ?? HKQueryAnchor(fromValue: 0)))
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Fetch Workout Samples

    /// Fetch power samples for a specific workout
    func fetchPowerSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        guard let powerType = HKQuantityType.quantityType(forIdentifier: .cyclingPower) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: powerType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let powerSamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: powerSamples)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch heart rate samples for a specific workout
    func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [HKQuantitySample] {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let heartRateSamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: heartRateSamples)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch statistics for a workout (average heart rate, total energy, etc.)
    func fetchWorkoutStatistics(for workout: HKWorkout, quantityType: HKQuantityType) async throws -> HKStatistics? {
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, statistics, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: statistics)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - HRV and Resting Heart Rate (for future phases)

    /// Fetch HRV samples for a date range
    func fetchHRVSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let hrvSamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: hrvSamples)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch resting heart rate samples for a date range
    func fetchRestingHeartRateSamples(from startDate: Date, to endDate: Date) async throws -> [HKQuantitySample] {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            throw HealthKitError.invalidType
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: rhrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let rhrSamples = samples as? [HKQuantitySample] ?? []
                continuation.resume(returning: rhrSamples)
            }

            healthStore.execute(query)
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
