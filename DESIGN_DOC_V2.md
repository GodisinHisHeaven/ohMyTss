# Body Battery iOS App — Concrete Design & Implementation Doc

**Version:** 2.0 (Scoped & Actionable)
**Author:** Claude + Mingjun
**Target Platform:** iOS 18+
**Timeline:** 12 weeks to v1.0 launch
**Last Updated:** 2025-01-07

---

## Executive Summary

**What:** iOS app that calculates a daily "Body Battery" score (0-100) from training load (TSS), HRV, and resting heart rate to tell endurance athletes when to train hard vs. recover.

**Why:** Existing apps (Training Peaks, Garmin) either require expensive subscriptions, proprietary hardware, or lack Apple Health integration.

**How:** On-device computation using Banister CTL/ATL/TSB model + HRV/RHR modifiers, powered by HealthKit data.

**MVP Scope (8 weeks):** Single sport (cycling), manual threshold input, daily score with 7-day history, no Watch app.

**v1.0 Scope (12 weeks):** Multi-sport, HRV/RHR modifiers, 90-day history, notifications, Watch app.

---

## Table of Contents

1. [Product Phases & Timeline](#1-product-phases--timeline)
2. [Core Algorithm Specification](#2-core-algorithm-specification)
3. [Data Model (SwiftData Schema)](#3-data-model-swiftdata-schema)
4. [HealthKit Integration Layer](#4-healthkit-integration-layer)
5. [App Architecture](#5-app-architecture)
6. [UI Specification](#6-ui-specification)
7. [Background Processing](#7-background-processing)
8. [Watch App (v1.0)](#8-watch-app-v10)
9. [Testing Strategy](#9-testing-strategy)
10. [Implementation Plan](#10-implementation-plan)

---

## 1. Product Phases & Timeline

### Phase 0: MVP (Weeks 1-8) — Single Sport, Core Engine

**Goal:** Validate algorithm and UX with cycling-only users.

**Features:**
- HealthKit permission flow
- Cycling workout ingestion (power-based TSS calculation)
- Manual FTP input
- CTL/ATL/TSB calculation (no HRV/RHR)
- Today screen with BB gauge and 7-day mini chart
- Settings screen (FTP, units, theme)

**Out of Scope:**
- Multi-sport
- HRV/RHR modifiers
- Watch app
- Background tasks (manual refresh only)
- Notifications
- iCloud sync

**Acceptance:**
- 20 beta testers use daily for 2 weeks
- CTL/ATL/TSB matches Training Peaks within ±2%
- App opens in <0.5s, refresh completes in <1s

---

### Phase 1: v1.0 Launch (Weeks 9-12) — Physiology & Multi-Sport

**Additions:**
- HRV/RHR data ingestion
- Body Battery modifiers (illness detection)
- Multi-sport support (running via pace, swimming via time)
- Watch app with complication
- Morning notification with BB + TSS target
- BGAppRefreshTask for auto-refresh
- 90-day history chart (CTL/ATL/TSB curves)

**Acceptance:**
- 100 beta testers across cycling/running/swimming
- Background refresh works 80% of mornings (iOS limitations)
- Watch sync latency <5s after workout

---

### Phase 2: v1.1+ (Future)

- iCloud sync
- Widgets (Today/Lock Screen)
- FIT/TCX file import
- Training plan suggestions
- Strava webhook integration
- VO2max and aerobic decoupling insights

---

## 2. Core Algorithm Specification

### 2.1 Training Stress Score (TSS) Calculation

#### Cycling (Power-based)
```swift
func calculateCyclingTSS(workout: HKWorkout, ftp: Double) -> Double? {
    guard let powerSamples = fetchPowerSamples(workout) else { return nil }

    // Calculate Normalized Power (NP)
    let np = calculateNormalizedPower(powerSamples)
    let duration = workout.duration / 3600.0 // hours
    let intensityFactor = np / ftp

    return (duration * np * intensityFactor) / (ftp * 3600.0) * 100.0
}

private func calculateNormalizedPower(_ samples: [Double]) -> Double {
    // 30-second rolling average, then 4th power, then 4th root
    let rollingAvg = samples.chunked(into: 30).map { $0.average() }
    let fourthPowers = rollingAvg.map { pow($0, 4) }
    return pow(fourthPowers.average(), 0.25)
}
```

**Fallback:** If no power data, use HR-based TRIMP scaled to TSS:
```swift
func estimateTSSFromHR(workout: HKWorkout, thresholdHR: Double, restingHR: Double) -> Double {
    let avgHR = fetchAverageHeartRate(workout)
    let hrReserve = (avgHR - restingHR) / (thresholdHR - restingHR)
    let trimp = workout.duration * hrReserve * exp(1.92 * hrReserve)
    return trimp * 0.1 // Scale TRIMP to TSS range
}
```

#### Running (Pace-based)
```swift
func calculateRunningTSS(workout: HKWorkout, thresholdPace: Double) -> Double {
    let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
    let duration = workout.duration
    let pace = duration / (distance / 1000.0) // min/km

    let intensityFactor = thresholdPace / pace
    let hours = duration / 3600.0

    return hours * intensityFactor * intensityFactor * 100.0
}
```

#### Swimming (Time-based)
```swift
func calculateSwimmingTSS(workout: HKWorkout, cssPerKm: Double) -> Double {
    // CSS = Critical Swim Speed (min/km)
    let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
    let duration = workout.duration
    let pace = duration / (distance / 1000.0) // min/km

    let intensityFactor = cssPerKm / pace
    let hours = duration / 3600.0

    return hours * intensityFactor * intensityFactor * 100.0
}
```

---

### 2.2 CTL/ATL/TSB Model (Banister EWMA)

```swift
struct LoadCalculator {
    static let CTL_DECAY: Double = 1.0 - exp(-1.0/42.0) // 0.0235283133
    static let ATL_DECAY: Double = 1.0 - exp(-1.0/7.0)  // 0.1331221002

    struct DayState {
        var ctl: Double
        var atl: Double
        var tsb: Double { ctl - atl }
    }

    static func updateLoad(previous: DayState, dailyTSS: Double) -> DayState {
        let newCTL = previous.ctl + CTL_DECAY * (dailyTSS - previous.ctl)
        let newATL = previous.atl + ATL_DECAY * (dailyTSS - previous.atl)

        return DayState(ctl: newCTL, atl: newATL)
    }

    static func initializeLoad(recentWorkouts: [(date: Date, tss: Double)]) -> DayState {
        // Seed CTL with 7-day average TSS
        let avgTSS = recentWorkouts.suffix(7).map(\.tss).average()
        return DayState(ctl: avgTSS, atl: avgTSS)
    }
}
```

---

### 2.3 Body Battery Score (TSB → 0-100)

```swift
struct BodyBatteryCalculator {
    private static let TSB_MIN: Double = -30.0
    private static let TSB_MAX: Double = 30.0

    static func rawScore(tsb: Double) -> Int {
        let normalized = (tsb - TSB_MIN) / (TSB_MAX - TSB_MIN)
        let score = normalized * 100.0
        return Int(score.clamped(to: 0...100))
    }

    static func finalScore(tsb: Double, hrvAdjustment: Double = 0, rhrAdjustment: Double = 0) -> Int {
        let raw = Double(rawScore(tsb: tsb))
        let combined = raw + hrvAdjustment + rhrAdjustment
        return Int(combined.clamped(to: 0...100))
    }
}
```

---

### 2.4 HRV/RHR Modifiers (v1.0+)

```swift
struct PhysiologyModifier {
    struct Baseline {
        let median: Double
        let mad: Double // Median Absolute Deviation
    }

    static func calculateBaseline(samples: [Double], excludeLast: Int = 2) -> Baseline {
        let valid = samples.dropLast(excludeLast)
        let median = valid.sorted()[valid.count / 2]
        let deviations = valid.map { abs($0 - median) }
        let mad = deviations.sorted()[deviations.count / 2]
        return Baseline(median: median, mad: mad)
    }

    static func robustZScore(value: Double, baseline: Baseline) -> Double {
        guard baseline.mad > 0 else { return 0 }
        return 0.6745 * (value - baseline.median) / baseline.mad
    }

    static func calculateAdjustment(
        hrvZ: Double,
        rhrZ: Double,
        previousAdjustment: Double
    ) -> Double {
        // Normalize (higher HRV = better, lower RHR = better)
        let hrvContrib = (hrvZ / 1.5).clamped(to: -1...1)
        let rhrContrib = (-rhrZ / 1.5).clamped(to: -1...1)

        let combined = 0.6 * hrvContrib + 0.4 * rhrContrib
        let rawAdjustment = (10.0 * combined).clamped(to: -12...12)

        // EWMA smoothing
        return 0.3 * rawAdjustment + 0.7 * previousAdjustment
    }

    static func detectIllness(hrvZ: Double, rhrZ: Double) -> Bool {
        return hrvZ <= -2.0 && rhrZ >= 2.0
    }
}
```

---

### 2.5 TSS Guidance Ranges

```swift
struct GuidanceEngine {
    enum ReadinessZone {
        case recovery      // BB 0-20
        case easy          // BB 20-40
        case moderate      // BB 40-60
        case hard          // BB 60-80
        case peak          // BB 80-100

        init(bodyBattery: Int) {
            switch bodyBattery {
            case 0..<20: self = .recovery
            case 20..<40: self = .easy
            case 40..<60: self = .moderate
            case 60..<80: self = .hard
            default: self = .peak
            }
        }

        var name: String {
            switch self {
            case .recovery: return "Recovery"
            case .easy: return "Easy Endurance"
            case .moderate: return "Tempo/Sweetspot"
            case .hard: return "Threshold/VO2max"
            case .peak: return "Race/Peak"
            }
        }

        var color: String {
            switch self {
            case .recovery: return "#E53E3E"      // Red
            case .easy: return "#DD6B20"          // Orange
            case .moderate: return "#D69E2E"      // Yellow
            case .hard: return "#38A169"          // Green
            case .peak: return "#3182CE"          // Blue
            }
        }
    }

    static func suggestedTSSRange(bodyBattery: Int, ctl: Double, adjustment: Double) -> ClosedRange<Double> {
        let zone = ReadinessZone(bodyBattery: bodyBattery)

        var (lowerMultiplier, upperMultiplier): (Double, Double) = {
            switch zone {
            case .recovery: return (0.0, 0.5)
            case .easy: return (0.5, 0.8)
            case .moderate: return (0.8, 1.1)
            case .hard: return (1.1, 1.4)
            case .peak: return (1.4, 1.8)
            }
        }()

        // Apply HRV/RHR modifier
        if adjustment >= 6 {
            upperMultiplier *= 1.1  // Feeling great, can push harder
        } else if adjustment <= -6 {
            lowerMultiplier *= 0.8
            upperMultiplier *= 0.8  // Stressed, reduce load
        }

        let lower = max(0, ctl * lowerMultiplier)
        let upper = ctl * upperMultiplier

        return lower...upper
    }
}
```

---

## 3. Data Model (SwiftData Schema)

```swift
import SwiftData
import Foundation

@Model
final class DayAggregate {
    @Attribute(.unique) var date: Date  // Normalized to local midnight

    // Training Load
    var dailyTSS: Double = 0
    var ctl: Double = 0
    var atl: Double = 0
    var tsb: Double { ctl - atl }

    // Body Battery
    var bodyBatteryRaw: Int = 50
    var bodyBatteryFinal: Int = 50

    // Physiology (v1.0+)
    var hrvMedian: Double?
    var restingHR: Double?
    var hrvAdjustment: Double = 0
    var rhrAdjustment: Double = 0
    var isIllnessDetected: Bool = false

    // Quality Flags
    var hasWorkoutData: Bool = false
    var hasHRVData: Bool = false
    var hasRHRData: Bool = false
    var sleepDuration: TimeInterval?

    // Metadata
    var lastUpdated: Date
    var workoutCount: Int = 0

    init(date: Date) {
        self.date = date.startOfDay
        self.lastUpdated = Date()
    }
}

@Model
final class UserThresholds {
    @Attribute(.unique) var id: String = "primary"

    // Cycling
    var ftp: Double?  // Watts

    // Running
    var thresholdPace: Double?  // min/km
    var thresholdHR: Double?    // bpm

    // Swimming
    var criticalSwimSpeed: Double?  // min/100m

    // General
    var restingHR: Double?
    var maxHR: Double?

    // Preferences
    var preferredUnits: UnitSystem = .metric
    var enabledSports: Set<Sport> = [.cycling]

    var lastModified: Date

    init() {
        self.lastModified = Date()
    }
}

enum Sport: String, Codable {
    case cycling
    case running
    case swimming
    case other
}

enum UnitSystem: String, Codable {
    case metric
    case imperial
}

@Model
final class AppState {
    @Attribute(.unique) var id: String = "singleton"

    var lastRecomputeDate: Date?
    var healthKitAuthorized: Bool = false
    var onboardingCompleted: Bool = false

    // HealthKit Anchors (stored as Data)
    var workoutQueryAnchor: Data?
    var hrvQueryAnchor: Data?
    var rhrQueryAnchor: Data?

    // HRV/RHR baseline tracking
    var hrvSamples: [Double] = []  // Last 28 nights
    var rhrSamples: [Double] = []  // Last 28 days

    var previousAdjustment: Double = 0  // For EWMA smoothing

    init() {}
}
```

---

## 4. HealthKit Integration Layer

### 4.1 Permission Request

```swift
import HealthKit

class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()
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

    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
    }

    func isAuthorized() -> Bool {
        let status = healthStore.authorizationStatus(for: HKObjectType.workoutType())
        return status == .sharingAuthorized
    }
}
```

---

### 4.2 Workout Fetching (Anchored Query)

```swift
extension HealthKitManager {
    func fetchNewWorkouts(since anchor: HKQueryAnchor?) async throws -> (workouts: [HKWorkout], newAnchor: HKQueryAnchor) {
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

    func fetchPowerSamples(for workout: HKWorkout) async throws -> [Double] {
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
}
```

---

### 4.3 HRV Fetching (Nightly)

```swift
extension HealthKitManager {
    func fetchNightlyHRV(for date: Date) async throws -> Double? {
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

    private func fetchMainSleepWindow(for date: Date) async throws -> (start: Date, end: Date)? {
        let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!

        // Look at previous night (e.g., for Jan 7 morning, check Jan 6 10pm - Jan 7 10am)
        let searchStart = Calendar.current.date(byAdding: .hour, value: -10, to: date.startOfDay)!
        let searchEnd = Calendar.current.date(byAdding: .hour, value: 10, to: date.startOfDay)!

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

                let longest = sleepSamples.max { $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate) }

                if let sleep = longest {
                    continuation.resume(returning: (sleep.startDate, sleep.endDate))
                } else {
                    continuation.resume(returning: nil)
                }
            }

            healthStore.execute(query)
        }
    }
}
```

---

### 4.4 Resting Heart Rate

```swift
extension HealthKitManager {
    func fetchRestingHeartRate(for date: Date) async throws -> Double? {
        let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
        let predicate = HKQuery.predicateForSamples(
            withStart: date.startOfDay,
            end: date.endOfDay,
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

                let rhr = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: rhr)
            }

            healthStore.execute(query)
        }
    }
}
```

---

## 5. App Architecture

### 5.1 Module Structure

```
BodyBatteryApp/
├── App/
│   ├── BodyBatteryApp.swift          // App entry point
│   └── AppEnvironment.swift           // DI container
├── Models/
│   ├── DayAggregate.swift             // SwiftData models
│   ├── UserThresholds.swift
│   └── AppState.swift
├── Services/
│   ├── HealthKitManager.swift         // HealthKit queries
│   ├── TSSCalculator.swift            // TSS per sport
│   ├── LoadEngine.swift               // CTL/ATL/TSB
│   ├── BodyBatteryEngine.swift        // BB score + guidance
│   └── DataStore.swift                // SwiftData persistence
├── ViewModels/
│   ├── TodayViewModel.swift
│   ├── HistoryViewModel.swift
│   └── SettingsViewModel.swift
├── Views/
│   ├── Onboarding/
│   │   ├── WelcomeView.swift
│   │   ├── HealthPermissionView.swift
│   │   └── ThresholdInputView.swift
│   ├── Today/
│   │   ├── TodayView.swift
│   │   ├── BodyBatteryGauge.swift
│   │   └── TSSGuidanceCard.swift
│   ├── History/
│   │   └── HistoryChartView.swift
│   └── Settings/
│       └── SettingsView.swift
└── Utilities/
    ├── Extensions.swift
    └── Constants.swift
```

---

### 5.2 Core Engine Service

```swift
@Observable
class BodyBatteryEngine {
    private let healthKit = HealthKitManager.shared
    private let dataStore: DataStore
    private let tssCalculator: TSSCalculator

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        self.tssCalculator = TSSCalculator(dataStore: dataStore)
    }

    func recomputeAll() async throws {
        // 1. Fetch all workouts since earliest data
        let workouts = try await healthKit.fetchAllWorkouts()

        // 2. Group by day, calculate TSS per day
        let dailyTSS = try await tssCalculator.calculateDailyTSS(from: workouts)

        // 3. Compute CTL/ATL/TSB time series
        var state = initializeLoadState(from: dailyTSS)
        var aggregates: [DayAggregate] = []

        for (date, tss) in dailyTSS.sorted(by: { $0.key < $1.key }) {
            state = LoadCalculator.updateLoad(previous: state, dailyTSS: tss)

            var aggregate = DayAggregate(date: date)
            aggregate.dailyTSS = tss
            aggregate.ctl = state.ctl
            aggregate.atl = state.atl
            aggregate.bodyBatteryRaw = BodyBatteryCalculator.rawScore(tsb: state.tsb)
            aggregate.bodyBatteryFinal = aggregate.bodyBatteryRaw  // No modifiers in MVP
            aggregate.hasWorkoutData = tss > 0

            aggregates.append(aggregate)
        }

        // 4. Fetch HRV/RHR and apply modifiers (v1.0+)
        if await shouldApplyPhysiologyModifiers() {
            try await applyPhysiologyModifiers(to: &aggregates)
        }

        // 5. Save to SwiftData
        try await dataStore.saveAggregates(aggregates)
    }

    private func initializeLoadState(from dailyTSS: [Date: Double]) -> LoadCalculator.DayState {
        // Use first 7 days average as seed
        let firstWeek = dailyTSS.sorted(by: { $0.key < $1.key }).prefix(7)
        let avgTSS = firstWeek.map(\.value).reduce(0, +) / Double(max(firstWeek.count, 1))
        return LoadCalculator.DayState(ctl: avgTSS, atl: avgTSS)
    }

    private func shouldApplyPhysiologyModifiers() async -> Bool {
        // Only if user has at least 28 days of HRV data
        let hrvCount = try? await healthKit.countHRVSamples(last: 28)
        return (hrvCount ?? 0) >= 14  // At least 50% coverage
    }

    private func applyPhysiologyModifiers(to aggregates: inout [DayAggregate]) async throws {
        // Fetch HRV/RHR for each day
        for i in aggregates.indices {
            let date = aggregates[i].date

            if let hrv = try await healthKit.fetchNightlyHRV(for: date) {
                aggregates[i].hrvMedian = hrv
                aggregates[i].hasHRVData = true
            }

            if let rhr = try await healthKit.fetchRestingHeartRate(for: date) {
                aggregates[i].restingHR = rhr
                aggregates[i].hasRHRData = true
            }
        }

        // Calculate baselines (rolling 28-day)
        for i in 28..<aggregates.count {
            let window = aggregates[(i-28)..<i]
            let hrvSamples = window.compactMap(\.hrvMedian)
            let rhrSamples = window.compactMap(\.restingHR)

            guard !hrvSamples.isEmpty, !rhrSamples.isEmpty else { continue }

            let hrvBaseline = PhysiologyModifier.calculateBaseline(samples: hrvSamples)
            let rhrBaseline = PhysiologyModifier.calculateBaseline(samples: rhrSamples)

            if let hrv = aggregates[i].hrvMedian, let rhr = aggregates[i].restingHR {
                let hrvZ = PhysiologyModifier.robustZScore(value: hrv, baseline: hrvBaseline)
                let rhrZ = PhysiologyModifier.robustZScore(value: rhr, baseline: rhrBaseline)

                let previousAdj = i > 0 ? aggregates[i-1].hrvAdjustment : 0
                let adjustment = PhysiologyModifier.calculateAdjustment(
                    hrvZ: hrvZ,
                    rhrZ: rhrZ,
                    previousAdjustment: previousAdj
                )

                aggregates[i].hrvAdjustment = adjustment
                aggregates[i].isIllnessDetected = PhysiologyModifier.detectIllness(hrvZ: hrvZ, rhrZ: rhrZ)

                // Apply to BB
                aggregates[i].bodyBatteryFinal = BodyBatteryCalculator.finalScore(
                    tsb: aggregates[i].tsb,
                    hrvAdjustment: adjustment,
                    rhrAdjustment: 0  // Already included in adjustment
                )
            }
        }
    }
}
```

---

### 5.3 Data Store (SwiftData)

```swift
import SwiftData

@Observable
class DataStore {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init() {
        let schema = Schema([
            DayAggregate.self,
            UserThresholds.self,
            AppState.self
        ])

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.yourdomain.bodybattery")
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            modelContext = ModelContext(modelContainer)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    func fetchAggregates(from startDate: Date, to endDate: Date) throws -> [DayAggregate] {
        let predicate = #Predicate<DayAggregate> { aggregate in
            aggregate.date >= startDate && aggregate.date <= endDate
        }

        let descriptor = FetchDescriptor<DayAggregate>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date)]
        )

        return try modelContext.fetch(descriptor)
    }

    func saveAggregates(_ aggregates: [DayAggregate]) throws {
        for aggregate in aggregates {
            // Upsert: delete existing, insert new
            let existing = try fetchAggregate(for: aggregate.date)
            if let existing = existing {
                modelContext.delete(existing)
            }
            modelContext.insert(aggregate)
        }

        try modelContext.save()
    }

    func fetchAggregate(for date: Date) throws -> DayAggregate? {
        let predicate = #Predicate<DayAggregate> { $0.date == date }
        let descriptor = FetchDescriptor<DayAggregate>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    func fetchThresholds() throws -> UserThresholds {
        let descriptor = FetchDescriptor<UserThresholds>()
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        } else {
            let new = UserThresholds()
            modelContext.insert(new)
            try modelContext.save()
            return new
        }
    }

    func fetchAppState() throws -> AppState {
        let descriptor = FetchDescriptor<AppState>()
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        } else {
            let new = AppState()
            modelContext.insert(new)
            try modelContext.save()
            return new
        }
    }
}
```

---

## 6. UI Specification

### 6.1 Today Screen

**Layout:**
```
┌─────────────────────────────┐
│   Body Battery               │ <- Navigation title
│                              │
│     ┌───────────────┐        │
│     │               │        │
│     │      78       │        │ <- Circular gauge (0-100)
│     │               │        │    Color gradient based on zone
│     └───────────────┘        │
│                              │
│   Peak Readiness             │ <- Zone name
│   Freshness (TSB): +12       │ <- TSB value
│                              │
│  ┌──────────────────────┐   │
│  │ Suggested Training   │   │ <- Card
│  │ 140-180 TSS          │   │
│  │ Hard intervals OK    │   │
│  └──────────────────────┘   │
│                              │
│  ┌──────────────────────┐   │
│  │ Last 7 Days          │   │ <- Mini sparkline
│  │ ▁▂▃▅▇▆▅ 45→78        │   │
│  └──────────────────────┘   │
│                              │
│  [View History] [Refresh]   │ <- Buttons
└─────────────────────────────┘
```

**Code:**
```swift
struct TodayView: View {
    @State private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Gauge
                    BodyBatteryGauge(
                        score: viewModel.todayScore,
                        zone: viewModel.readinessZone
                    )
                    .frame(width: 200, height: 200)

                    // Zone name and TSB
                    VStack(spacing: 8) {
                        Text(viewModel.readinessZone.name)
                            .font(.title2.bold())

                        Text("Freshness (TSB): \(viewModel.tsbFormatted)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Guidance card
                    TSSGuidanceCard(
                        range: viewModel.suggestedTSSRange,
                        description: viewModel.guidanceText
                    )

                    // 7-day trend
                    WeekTrendView(scores: viewModel.last7Days)

                    // Actions
                    HStack {
                        NavigationLink("View History") {
                            HistoryView()
                        }
                        .buttonStyle(.bordered)

                        Button("Refresh") {
                            Task {
                                await viewModel.refresh()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle("Body Battery")
            .task {
                await viewModel.load()
            }
        }
    }
}
```

---

### 6.2 Body Battery Gauge Component

```swift
struct BodyBatteryGauge: View {
    let score: Int
    let zone: GuidanceEngine.ReadinessZone

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 20)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: score)

            // Score text
            VStack {
                Text("\(score)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gradient: AngularGradient {
        AngularGradient(
            colors: [
                Color(hex: "#E53E3E"),  // Red
                Color(hex: "#DD6B20"),  // Orange
                Color(hex: "#D69E2E"),  // Yellow
                Color(hex: "#38A169"),  // Green
                Color(hex: "#3182CE")   // Blue
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }
}
```

---

### 6.3 Settings Screen

```swift
struct SettingsView: View {
    @State private var thresholds: UserThresholds
    @State private var showingSportPicker = false

    var body: some View {
        Form {
            Section("Thresholds") {
                if thresholds.enabledSports.contains(.cycling) {
                    HStack {
                        Text("FTP (Cycling)")
                        Spacer()
                        TextField("Watts", value: $thresholds.ftp, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                if thresholds.enabledSports.contains(.running) {
                    HStack {
                        Text("Threshold Pace")
                        Spacer()
                        TextField("min/km", value: $thresholds.thresholdPace, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }
            }

            Section("Enabled Sports") {
                Button("Manage Sports") {
                    showingSportPicker = true
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
            }

            Section {
                Button("Export Data", action: exportData)
                Button("Reset All Data", role: .destructive, action: resetData)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingSportPicker) {
            SportPickerView(selection: $thresholds.enabledSports)
        }
    }

    func exportData() {
        // TODO: Export JSON
    }

    func resetData() {
        // TODO: Confirm + delete all
    }
}
```

---

## 7. Background Processing

### 7.1 BGTaskScheduler Setup (v1.0+)

**Info.plist:**
```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.yourdomain.bodybattery.refresh</string>
</array>
```

**AppDelegate:**
```swift
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.yourdomain.bodybattery.refresh",
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        scheduleAppRefresh()
        return true
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.yourdomain.bodybattery.refresh")
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: Date())

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }

    func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()  // Schedule next refresh

        let engine = BodyBatteryEngine(dataStore: DataStore())

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            do {
                try await engine.recomputeAll()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
    }
}
```

---

### 7.2 HealthKit Observer (Live Updates)

```swift
extension HealthKitManager {
    func setupWorkoutObserver(onChange: @escaping () -> Void) {
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
            print("Background delivery enabled: \(success)")
        }
    }
}
```

**In App:**
```swift
@main
struct BodyBatteryApp: App {
    @State private var dataStore = DataStore()
    @State private var engine: BodyBatteryEngine?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    engine = BodyBatteryEngine(dataStore: dataStore)

                    HealthKitManager.shared.setupWorkoutObserver {
                        Task {
                            try? await engine?.recomputeAll()
                        }
                    }
                }
        }
    }
}
```

---

## 8. Watch App (v1.0)

### 8.1 Watch UI

```swift
// WatchApp/TodayView.swift
import SwiftUI

struct WatchTodayView: View {
    @State private var score: Int = 0
    @State private var zone: GuidanceEngine.ReadinessZone = .moderate

    var body: some View {
        VStack {
            // Large score
            Text("\(score)")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: zone.color))

            Text("Battery")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Zone name
            Text(zone.name)
                .font(.caption)
                .padding(.top, 4)
        }
        .task {
            await loadData()
        }
    }

    func loadData() async {
        // Fetch from Watch Connectivity or local SwiftData
        if let today = try? await WatchDataStore.shared.fetchToday() {
            score = today.bodyBatteryFinal
            zone = GuidanceEngine.ReadinessZone(bodyBattery: score)
        }
    }
}
```

---

### 8.2 Complication

```swift
import ClockKit

struct BodyBatteryComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "BodyBatteryComplication",
            provider: Provider()
        ) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Body Battery")
        .description("Your daily readiness score")
        .supportedFamilies([
            .modularSmall,
            .modularLarge,
            .circularSmall,
            .graphicCircular,
            .graphicCorner
        ])
    }
}

struct Provider: TimelineProvider {
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let entry = Entry(date: Date(), score: 75)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let today = try? await WatchDataStore.shared.fetchToday()
            let entry = Entry(date: Date(), score: today?.bodyBatteryFinal ?? 50)

            // Update daily
            let nextUpdate = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let score: Int
}

struct ComplicationView: View {
    let entry: Entry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .modularSmall:
            VStack {
                Text("\(entry.score)")
                    .font(.title.bold())
                Text("BB")
                    .font(.caption2)
            }
        case .graphicCircular:
            Gauge(value: Double(entry.score), in: 0...100) {
                Text("BB")
            } currentValueLabel: {
                Text("\(entry.score)")
            }
            .gaugeStyle(.accessoryCircular)
        default:
            Text("\(entry.score)")
        }
    }
}
```

---

### 8.3 Watch Connectivity

```swift
import WatchConnectivity

class WatchSyncManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private let session = WCSession.default

    override init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    // Phone → Watch
    func sendTodayData(_ aggregate: DayAggregate) {
        guard session.isReachable else { return }

        let message: [String: Any] = [
            "score": aggregate.bodyBatteryFinal,
            "tsb": aggregate.tsb,
            "tss": aggregate.dailyTSS,
            "date": aggregate.date.timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil)
    }

    // Watch: Receive
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let score = message["score"] as? Int,
           let timestamp = message["date"] as? TimeInterval {
            // Update local SwiftData
            Task {
                await WatchDataStore.shared.updateToday(score: score, date: Date(timeIntervalSince1970: timestamp))
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
```

---

## 9. Testing Strategy

### 9.1 Unit Tests

```swift
import XCTest
@testable import BodyBattery

final class LoadCalculatorTests: XCTestCase {
    func testCTLATLProgression() {
        var state = LoadCalculator.DayState(ctl: 50, atl: 50)

        // Day 1: 100 TSS
        state = LoadCalculator.updateLoad(previous: state, dailyTSS: 100)

        XCTAssertEqual(state.ctl, 50 + 0.0235 * (100 - 50), accuracy: 0.01)
        XCTAssertEqual(state.atl, 50 + 0.1331 * (100 - 50), accuracy: 0.01)
        XCTAssertLessThan(state.tsb, 0)  // Fatigued after hard day
    }

    func testBodyBatteryMapping() {
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 0), 50)
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 30), 100)
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: -30), 0)
        XCTAssertEqual(BodyBatteryCalculator.rawScore(tsb: 15), 75)
    }

    func testIllnessDetection() {
        // Normal
        XCTAssertFalse(PhysiologyModifier.detectIllness(hrvZ: 0.5, rhrZ: -0.3))

        // Illness: low HRV + high RHR
        XCTAssertTrue(PhysiologyModifier.detectIllness(hrvZ: -2.5, rhrZ: 2.1))
    }
}
```

---

### 9.2 Integration Tests (Mock HealthKit)

```swift
final class EngineIntegrationTests: XCTestCase {
    var dataStore: DataStore!
    var engine: BodyBatteryEngine!

    override func setUp() async throws {
        dataStore = DataStore()
        engine = BodyBatteryEngine(dataStore: dataStore)
    }

    func testFullRecompute() async throws {
        // Given: 30 days of synthetic workouts
        let workouts = generateSyntheticWorkouts(days: 30, avgTSS: 80)

        // When: Recompute
        try await engine.recomputeAll()

        // Then: Last day should have reasonable CTL
        let today = try dataStore.fetchAggregate(for: Date())
        XCTAssertNotNil(today)
        XCTAssertGreaterThan(today!.ctl, 60)
        XCTAssertLessThan(today!.ctl, 100)
    }

    private func generateSyntheticWorkouts(days: Int, avgTSS: Double) -> [HKWorkout] {
        // Mock workout generation
        []
    }
}
```

---

### 9.3 Snapshot Tests (UI)

```swift
import SnapshotTesting

final class TodayViewSnapshotTests: XCTestCase {
    func testGaugeRendering() {
        let view = BodyBatteryGauge(score: 75, zone: .hard)
            .frame(width: 200, height: 200)

        assertSnapshot(matching: view, as: .image)
    }

    func testTodayViewAllZones() {
        for score in [10, 30, 50, 70, 90] {
            let viewModel = TodayViewModel.mock(score: score)
            let view = TodayView(viewModel: viewModel)

            assertSnapshot(matching: view, as: .image, named: "score_\(score)")
        }
    }
}
```

---

## 10. Implementation Plan

### Week 1-2: Foundation
- [ ] Project setup (Xcode, SwiftData, HealthKit entitlements)
- [ ] Data models (DayAggregate, UserThresholds, AppState)
- [ ] HealthKit permission flow
- [ ] Basic UI shell (TabView: Today, History, Settings)

### Week 3-4: Core Engine
- [ ] TSS calculator (cycling power-based)
- [ ] CTL/ATL/TSB engine
- [ ] Body Battery mapping
- [ ] Unit tests for all algorithms
- [ ] Mock data generator for testing

### Week 5-6: UI & Data Flow
- [ ] Today screen with gauge
- [ ] 7-day mini chart
- [ ] Settings screen (FTP input)
- [ ] Pull-to-refresh functionality
- [ ] Onboarding flow

### Week 7-8: Polish & Beta
- [ ] Error handling (no data, missing permissions)
- [ ] Loading states
- [ ] Integration tests
- [ ] TestFlight build
- [ ] 20 beta testers for 2 weeks

### Week 9-10: Multi-Sport & Physiology (v1.0)
- [ ] Running TSS (pace-based)
- [ ] Swimming TSS (time-based)
- [ ] HRV/RHR fetching
- [ ] Physiology modifiers
- [ ] Illness detection
- [ ] 90-day history chart

### Week 11-12: Watch App & Notifications
- [ ] Watch app UI
- [ ] Watch Connectivity sync
- [ ] Complication
- [ ] BGTaskScheduler setup
- [ ] Morning notification
- [ ] Final beta testing (100 users)
- [ ] App Store submission

---

## Appendix A: Utilities & Extensions

```swift
extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Array where Element == Double {
    func average() -> Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}
```

---

## Appendix B: Open Questions & Decisions Needed

| Question | Options | Decision | Date |
|----------|---------|----------|------|
| Should MVP include running? | Yes / No | **No** - cycling only for speed | 2025-01-07 |
| Use Core Data or SwiftData? | Core Data / SwiftData | **SwiftData** - modern, less boilerplate | 2025-01-07 |
| Paid or freemium? | Paid ($4.99) / Free + IAP | **TBD** - decide after beta feedback | - |
| Export format? | JSON / CSV / FIT | **JSON** for MVP, FIT in v1.1 | 2025-01-07 |
| HRV smoothing aggressiveness? | 0.3/0.7 / 0.5/0.5 | **0.3/0.7** - prefer stability | 2025-01-07 |

---

## Appendix C: Success Metrics Dashboard

**Week 4 (MVP Feature Complete):**
- [ ] All unit tests pass (>95% coverage on engine)
- [ ] Sample 7-day dataset produces expected CTL/ATL
- [ ] App builds and runs on iOS 18 simulator

**Week 8 (MVP Beta):**
- [ ] 20 beta testers recruited
- [ ] ≥80% complete onboarding
- [ ] ≥60% open app daily
- [ ] Zero P0 crashes

**Week 12 (v1.0 Launch):**
- [ ] 100 beta testers
- [ ] Crash-free rate >99%
- [ ] Background refresh success >80%
- [ ] Average App Store rating ≥4.5 (predicted from beta feedback)

---

**End of Document**

**Questions? Email:** mingjun@example.com
**Figma Mockups:** [Link TBD]
**GitHub Repo:** [Private during development]
