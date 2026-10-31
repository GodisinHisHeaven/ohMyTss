import Foundation
import HealthKit
import os

private let observerLog = Logger(subsystem: "mj6.onMyTss", category: "HealthKitObserver")

/// Registers observers at launch, including when HealthKit launches the app in
/// the background. The owner must keep this instance alive for the app lifetime.
@MainActor
final class HealthKitBackgroundObserver {
    private let store = HKHealthStore()
    private let onChange: @MainActor () async throws -> Void
    private var queries: [HKObserverQuery] = []

    init(onChange: @escaping @MainActor () async throws -> Void) {
        self.onChange = onChange
    }

    private var sampleTypes: [HKSampleType] {
        [
            .workoutType(),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis)
        ]
    }

    /// Must run during app launch, before HealthKit delivers queued changes.
    /// The callback must finish processing or durably record a retry before it
    /// returns. This observer acknowledges each delivery only after that point.
    func start() {
        guard HKHealthStore.isHealthDataAvailable(), queries.isEmpty else { return }
        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                let hasError = error != nil
                if hasError { observerLog.error("HealthKit observer reported an error; requesting recovery") }
                Task { @MainActor [weak self] in
                    if hasError { AppBackgroundDelegate.current?.scheduleRefresh() }
                    await Self.processDelivery(onChange: {
                        guard let self else { return }
                        try await self.onChange()
                    }, completion: completion)
                }
            }
            queries.append(query)
            store.execute(query)
        }
    }

    /// Complete every callback once, even on error. Failed work is retried from
    /// its durable marker; if that write fails, the source anchor is unchanged.
    static func processDelivery(onChange: () async throws -> Void, completion: () -> Void) async {
        defer { completion() }
        do { try await onChange() } catch { }
    }

    /// Enables future background deliveries without requesting authorization.
    /// Returns types whose registration failed so the caller can retry/report it.
    func enableDelivery() async -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        var failures: [String] = []
        for type in sampleTypes {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
            } catch {
                failures.append(type.identifier)
            }
        }
        return failures
    }
}
