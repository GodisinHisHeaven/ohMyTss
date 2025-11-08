import Foundation
import HealthKit

/// Manages HealthKit authorization and data queries
@Observable
public class HealthKitManager {
    public static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()

    private let typesToRead: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
        HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
        HKObjectType.quantityType(forIdentifier: .cyclingPower)!,
        HKObjectType.quantityType(forIdentifier: .runningSpeed)!,
        HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
        HKObjectType.quantityType(forIdentifier: .distanceSwimming)!,
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    ]

    private init() {}

    // MARK: - Authorization

    /// Requests HealthKit authorization
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }

        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
    }

    /// Checks if HealthKit is authorized
    public func isAuthorized() -> Bool {
        let status = healthStore.authorizationStatus(for: HKObjectType.workoutType())
        return status == .sharingAuthorized
    }

    // MARK: - Workouts

    /// Fetches new workouts since a given anchor
    public func fetchNewWorkouts(since anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor) {
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { query, newSamples, deletedSamples, newAnchor, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (newSamples as? [HKWorkout]) ?? []
                continuation.resume(returning: (workouts, newAnchor!))
            }

            healthStore.execute(query)
        }
    }

    /// Fetches all workouts within a date range
    public func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { query, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Power Data

    /// Fetches cycling power samples for a workout
    public func fetchPowerSamples(for workout: HKWorkout) async throws -> [Double] {
        let powerType = HKQuantityType.quantityType(forIdentifier: .cyclingPower)!
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: powerType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { query, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let powers = (samples as? [HKQuantitySample])?.map {
                    $0.quantity.doubleValue(for: HKUnit.watt())
                } ?? []

                continuation.resume(returning: powers)
            }

            healthStore.execute(query)
        }
    }

    /// Fetches average heart rate for a workout
    public func fetchAverageHeartRate(for workout: HKWorkout) async throws -> Double? {
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { query, statistics, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let avgHR = statistics?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: avgHR)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - HRV

    /// Fetches nightly HRV median for a given date
    public func fetchNightlyHRV(for date: Date) async throws -> Double? {
        // Get main sleep window
        guard let sleepWindow = try await fetchMainSleepWindow(for: date) else {
            return nil
        }

        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let predicate = HKQuery.predicateForSamples(
            withStart: sleepWindow.start,
            end: sleepWindow.end,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { query, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let hrvSamples = (samples as? [HKQuantitySample])?.map {
                    $0.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                } ?? []

                // Return median of nightly samples (robust to outliers)
                let median = hrvSamples.isEmpty ? nil : hrvSamples.sorted()[hrvSamples.count / 2]
                continuation.resume(returning: median)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Resting Heart Rate

    /// Fetches resting heart rate for a given date
    public func fetchRestingHeartRate(for date: Date) async throws -> Double? {
        let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
        let startOfDay = Calendar.current.startOfDay(for: date)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: rhrType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { query, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let rhr = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(
                    for: HKUnit.count().unitDivided(by: .minute())
                )
                continuation.resume(returning: rhr)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Sleep

    /// Fetches main sleep window for a given date
    private func fetchMainSleepWindow(for date: Date) async throws -> (start: Date, end: Date)? {
        let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!

        // Look at previous night (e.g., for Jan 7 morning, check Jan 6 10pm - Jan 7 10am)
        let searchStart = Calendar.current.date(byAdding: .hour, value: -10, to: Calendar.current.startOfDay(for: date))!
        let searchEnd = Calendar.current.date(byAdding: .hour, value: 10, to: Calendar.current.startOfDay(for: date))!

        let predicate = HKQuery.predicateForSamples(withStart: searchStart, end: searchEnd)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { query, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                // Find longest .asleep block
                let sleepSamples = (samples as? [HKCategorySample])?.filter {
                    $0.value == HKCategoryValueSleepAnalysis.asleep.rawValue
                } ?? []

                let longest = sleepSamples.max {
                    $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate)
                }

                if let sleep = longest {
                    continuation.resume(returning: (sleep.startDate, sleep.endDate))
                } else {
                    continuation.resume(returning: nil)
                }
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Background Observers

    /// Sets up background observer for new workouts
    public func setupWorkoutObserver(onChange: @escaping () -> Void) {
        let workoutType = HKObjectType.workoutType()

        let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { query, completionHandler, error in
            if error != nil {
                completionHandler()
                return
            }

            // New workout detected
            onChange()
            completionHandler()
        }

        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
            // Background delivery enabled
        }
    }
}

// MARK: - Errors

public enum HealthKitError: Error {
    case notAvailable
    case unauthorized
    case queryFailed
}
