//
//  CalculatorTests.swift
//  onMyTssTests
//
//  Created by Claude Code
//

import XCTest
import HealthKit
@testable import onMyTss

final class TSSCalculatorTests: XCTestCase {

    func testPowerBasedTSS() {
        let samples = mockPowerSamples([200, 200, 200])
        let tss = TSSCalculator.calculateTSS(powerSamples: samples, ftp: 200, duration: 3600)
        // NP=200, IF=1.0, TSS = (3600 * 200 * 1.0) / (200 * 3600) * 100 = 100
        XCTAssertEqual(tss, 100.0, accuracy: 1.0)
    }

    func testPowerBasedTSSWithEmptySamplesReturnsZero() {
        let tss = TSSCalculator.calculateTSS(powerSamples: [], ftp: 200, duration: 3600)
        XCTAssertEqual(tss, 0)
    }

    func testEstimateTSSFromDurationCycling() {
        let workout = mockHKWorkout(type: .cycling, duration: 3600)
        let tss = TSSCalculator.estimateTSSFromDuration(workout: workout)
        // 1h * 100 * 0.70^2 = 49
        XCTAssertEqual(tss, 49.0, accuracy: 1.0)
    }

    func testEstimateTSSFromDurationRunning() {
        let workout = mockHKWorkout(type: .running, duration: 3600)
        let tss = TSSCalculator.estimateTSSFromDuration(workout: workout)
        // 1h * 100 * 0.75^2 = 56.25
        XCTAssertEqual(tss, 56.3, accuracy: 1.0)
    }

    func testEstimateTSSFromDurationWalking() {
        let workout = mockHKWorkout(type: .walking, duration: 3600)
        let tss = TSSCalculator.estimateTSSFromDuration(workout: workout)
        // 1h * 100 * 0.45^2 = 20.25
        XCTAssertEqual(tss, 20.3, accuracy: 1.0)
    }
}

final class BodyBatteryCalculatorTests: XCTestCase {

    func testCalculateScoreMapsTSBToRange() {
        XCTAssertEqual(BodyBatteryCalculator.calculateScore(from: -35), 0)
        XCTAssertEqual(BodyBatteryCalculator.calculateScore(from: 0), 50)
        XCTAssertEqual(BodyBatteryCalculator.calculateScore(from: 25), 100)
    }

    func testCalculateScoreClampsExtremes() {
        XCTAssertEqual(BodyBatteryCalculator.calculateScore(from: -100), 0)
        XCTAssertEqual(BodyBatteryCalculator.calculateScore(from: 100), 100)
    }

    func testCalculateScoreWithModifiers() {
        let score = BodyBatteryCalculator.calculateScoreWithModifiers(tsb: 0, hrvModifier: 10, rhrModifier: 5)
        // base = 50, combined modifier weighted = 10*0.7 + 5*0.3 = 8.5 -> 58 or 59
        XCTAssertEqual(score, 58)
    }

    func testGetReadinessLevel() {
        XCTAssertEqual(BodyBatteryCalculator.getReadinessLevel(score: 10), .veryLow)
        XCTAssertEqual(BodyBatteryCalculator.getReadinessLevel(score: 30), .low)
        XCTAssertEqual(BodyBatteryCalculator.getReadinessLevel(score: 50), .medium)
        XCTAssertEqual(BodyBatteryCalculator.getReadinessLevel(score: 70), .good)
        XCTAssertEqual(BodyBatteryCalculator.getReadinessLevel(score: 90), .excellent)
    }

    func testCalculateTrendImproving() {
        let trend = BodyBatteryCalculator.calculateTrend(scores: [50, 51, 52])
        XCTAssertEqual(trend, .improving)
    }

    func testCalculateTrendDecliningFast() {
        let trend = BodyBatteryCalculator.calculateTrend(scores: [80, 60, 40])
        XCTAssertEqual(trend, .decliningFast)
    }

    func testCalculateTrendStable() {
        let trend = BodyBatteryCalculator.calculateTrend(scores: [50, 51, 50])
        XCTAssertEqual(trend, .stable)
    }

    func testCalculateTrendWithFewerThanThreeScoresReturnsStable() {
        let trend = BodyBatteryCalculator.calculateTrend(scores: [50, 60])
        XCTAssertEqual(trend, .stable)
    }
}

final class LoadCalculatorTests: XCTestCase {

    func testCTLCalculation() {
        let ctl = LoadCalculator.calculateCTL(tssHistory: [100], previousCTL: 50)
        // 50 + (1/42)*(100-50) = 51.19
        XCTAssertEqual(ctl, 51.19, accuracy: 0.01)
    }

    func testATLCalculation() {
        let atl = LoadCalculator.calculateATL(tssHistory: [100], previousATL: 50)
        // 50 + (1/7)*(100-50) = 57.14
        XCTAssertEqual(atl, 57.14, accuracy: 0.01)
    }

    func testTSBCalculation() {
        let tsb = LoadCalculator.calculateTSB(ctl: 80, atl: 60)
        XCTAssertEqual(tsb, 20.0)
    }

    func testTimeSeries() {
        let series = LoadCalculator.calculateTimeSeries(tssValues: [100, 100, 100])
        XCTAssertEqual(series.count, 3)
        XCTAssertGreaterThan(series.last!.ctl, series.first!.ctl)
    }

    func testRampRateStatus() {
        XCTAssertEqual(LoadCalculator.getRampRateStatus(rampRate: -1), .detraining)
        XCTAssertEqual(LoadCalculator.getRampRateStatus(rampRate: 2), .safe)
        XCTAssertEqual(LoadCalculator.getRampRateStatus(rampRate: 4), .aggressive)
        XCTAssertEqual(LoadCalculator.getRampRateStatus(rampRate: 6), .dangerous)
    }
}

final class PhysiologyModifierTests: XCTestCase {

    func testHRVModifierPositive() {
        let mod = PhysiologyModifier.calculateHRVModifier(currentHRV: 65, baselineHRV: 50)
        // +30% -> +20
        XCTAssertEqual(mod, 20.0, accuracy: 0.1)
    }

    func testHRVModifierNegative() {
        let mod = PhysiologyModifier.calculateHRVModifier(currentHRV: 35, baselineHRV: 50)
        // -30% -> -20
        XCTAssertEqual(mod, -20.0, accuracy: 0.1)
    }

    func testRHRModifierPositive() {
        let mod = PhysiologyModifier.calculateRHRModifier(currentRHR: 45, baselineRHR: 50)
        // -5 bpm -> +20
        XCTAssertEqual(mod, 20.0, accuracy: 0.1)
    }

    func testRHRModifierNegative() {
        let mod = PhysiologyModifier.calculateRHRModifier(currentRHR: 55, baselineRHR: 50)
        // +5 bpm -> -20
        XCTAssertEqual(mod, -20.0, accuracy: 0.1)
    }

    func testCombinedModifierWeighted() {
        let combined = PhysiologyModifier.calculateCombinedModifier(hrvModifier: 10, rhrModifier: 20)
        // 10*0.7 + 20*0.3 = 13
        XCTAssertEqual(combined, 13.0, accuracy: 0.1)
    }

    func testCombinedModifierMissingHRV() {
        let combined = PhysiologyModifier.calculateCombinedModifier(hrvModifier: nil, rhrModifier: 10)
        XCTAssertEqual(combined, 10.0, accuracy: 0.1)
    }

    func testDetectIllness() {
        XCTAssertEqual(PhysiologyModifier.detectIllness(hrvModifier: -15, rhrModifier: -15), 1.0)
        XCTAssertEqual(PhysiologyModifier.detectIllness(hrvModifier: -10, rhrModifier: -10), 0.7)
        XCTAssertEqual(PhysiologyModifier.detectIllness(hrvModifier: -5, rhrModifier: 0), 0.3)
        XCTAssertEqual(PhysiologyModifier.detectIllness(hrvModifier: 0, rhrModifier: 0), 0.0)
    }
}

final class GuidanceEngineTests: XCTestCase {

    func testGetReadinessZone() {
        XCTAssertEqual(GuidanceEngine.getReadinessZone(tsb: -20), .overreaching)
        XCTAssertEqual(GuidanceEngine.getReadinessZone(tsb: -10), .deload)
        XCTAssertEqual(GuidanceEngine.getReadinessZone(tsb: 0), .maintain)
        XCTAssertEqual(GuidanceEngine.getReadinessZone(tsb: 10), .buildBase)
        XCTAssertEqual(GuidanceEngine.getReadinessZone(tsb: 20), .buildIntensity)
    }

    func testRecommendedTSSRangeOverreaching() {
        let rec = GuidanceEngine.getRecommendedTSSRange(bodyBatteryScore: 10, tsb: -20, ctl: 100)
        XCTAssertEqual(rec.intensity, .recovery)
        XCTAssertEqual(rec.max, 30)
    }

    func testRecommendedTSSRangeBuildIntensity() {
        let rec = GuidanceEngine.getRecommendedTSSRange(bodyBatteryScore: 90, tsb: 20, ctl: 100)
        XCTAssertEqual(rec.intensity, .threshold)
        XCTAssertEqual(rec.max, 150)
    }

    func testTrainingSuggestionsIncludesRampRateWarning() {
        let suggestions = GuidanceEngine.getTrainingSuggestions(bodyBatteryScore: 50, tsb: 0, ctl: 100, atl: 100, rampRate: 6, recentTSS: [100, 100, 100, 100, 100, 100, 100])
        XCTAssertTrue(suggestions.contains { $0.contains("CTL increasing too fast") })
    }

    func testWeeklyPlanRestDays() {
        let plan = GuidanceEngine.getWeeklyPlan(ctl: 100, atl: 100, tsb: 0, targetWeeklyTSS: nil)
        XCTAssertEqual(plan.restDays, 1)
        XCTAssertGreaterThan(plan.totalTSS, 0)
    }
}

// MARK: - Helpers

private func mockPowerSamples(_ values: [Double]) -> [HKQuantitySample] {
    let type = HKQuantityType.quantityType(forIdentifier: .cyclingPower)!
    let unit = HKUnit.watt()
    let now = Date()
    return values.map {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: $0), start: now, end: now)
    }
}

private func mockHKWorkout(type: HKWorkoutActivityType, duration: TimeInterval) -> HKWorkout {
    return HKWorkout(
        activityType: type,
        start: Date(),
        end: Date().addingTimeInterval(duration)
    )
}
