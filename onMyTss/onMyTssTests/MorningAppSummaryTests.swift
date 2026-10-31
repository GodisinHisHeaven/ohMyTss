import XCTest
import SwiftData
@testable import onMyTss

final class MorningAppSummaryTests: XCTestCase {
    @MainActor
    private func store() throws -> onMyTss.DataStore {
        let container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return DataStore(modelContainer: container)
    }

    @MainActor
    func testSummaryUsesOnlyCurrentComputedRecoveryAndActiveSevenDayWorkouts() throws {
        let store = try store()
        let now = Date()
        let day = DayAggregate(date: Calendar.current.startOfDay(for: now), totalTSS: 60, bodyBatteryScore: 72, sleepDuration: 7.5)
        try store.saveDayAggregate(day)
        let state = try store.fetchAppState()
        state.lastComputationDate = now
        for (id, age, duration) in [("recent", 3600.0, 1800.0), ("old", 8*86400.0, 1800.0),
                                    ("suppressed", 3600.0, 1800.0), ("future", -3600.0, 1800.0)] {
            let date = now.addingTimeInterval(-age)
            let workout = Workout(id: id, date: date, startTime: date, duration: duration,
                                  workoutType: "Run", tss: 30, calculationMethod: "duration",
                                  source: id == "recent" ? .strava : .healthKit)
            try store.saveWorkouts([workout])
        }
        XCTAssertTrue(try XCTUnwrap(store.fetchWorkout(byId: "suppressed")).isSuppressed)
        let summary = try XCTUnwrap(MorningAppSummary.make(store: store, timezone: TimeZone.current.identifier, now: now))
        XCTAssertEqual(summary.readinessScore, 72)
        XCTAssertEqual(summary.sleepHours, 7.5)
        XCTAssertEqual(summary.trainingMinutes7d, 30)
        XCTAssertEqual(Set(summary.payload.keys), ["summary_date", "timezone", "generated_at", "readiness_score", "sleep_hours", "training_minutes_7d"])
    }

    @MainActor
    func testMissingOrUncomputedRecoveryNeverUploadsDefaultScore() throws {
        let store = try store()
        XCTAssertNil(try MorningAppSummary.make(store: store, timezone: TimeZone.current.identifier))
        try store.saveDayAggregate(DayAggregate(date: Date().startOfDay, bodyBatteryScore: 50, sleepDuration: 8))
        XCTAssertNil(try MorningAppSummary.make(store: store, timezone: TimeZone.current.identifier))
        XCTAssertNil(try MorningAppSummary.make(store: store, timezone: "Invalid/Zone"))
    }

    @MainActor
    func testSummaryResponseDecodesAndUploadRequiresExplicitConsent() async throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(morningFixtureJSON.utf8)) as? [String: Any])
        raw["data_source"] = "app"
        raw["app_summary_consent"] = true
        raw["requires_sms_restart"] = false
        raw["app_summary"] = ["readiness_score": 72, "sleep_hours": 7.5, "training_minutes_7d": 210]
        let data = try JSONSerialization.data(withJSONObject: raw)
        var calls: [URLRequest] = []
        let api = MorningStatusAPI { request in
            calls.append(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
        }
        let status = try await api.subscribe(timezone: "America/Chicago", token: "fixture")
        XCTAssertTrue(status.canUploadSummary)
        XCTAssertEqual(status.appSummary?.trainingMinutes7d, 210)
        let summary = MorningAppSummary(summaryDate: "2026-10-26", timezone: "America/Chicago", generatedAt: Date(),
                                        readinessScore: 72, sleepHours: 7.5, trainingMinutes7d: 210)
        _ = try await api.uploadSummary(summary, token: "fixture")
        XCTAssertEqual(calls[0].url?.lastPathComponent, "subscribe")
        XCTAssertEqual(calls[1].url?.lastPathComponent, "summary")
        XCTAssertEqual(calls[1].httpMethod, "PUT")
        XCTAssertEqual(calls[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: calls[1].httpBody!) as? NSDictionary, summary.payload as NSDictionary)
    }

    @MainActor
    func testPhoneVerificationAndStatusRefreshNeverOptInOrUpload() async {
        let api = MorningServiceStub()
        let model = MorningStatusViewModel(api: api, tokenStore: MorningSessionStub())
        await model.requestCode(phone: "2025550100")
        await model.verifyCode("123456")
        await model.refresh()
        XCTAssertEqual(api.subscribeCalls, 0)
        XCTAssertTrue(api.uploadedSummaries.isEmpty)
    }

    @MainActor
    func testForegroundSyncSkipsMissingSessionAndUnconsentedOrStoppedAccounts() async throws {
        let store = try store()
        let api = MorningServiceStub()
        await MorningSummarySync(api: api, tokenStore: MorningSessionStub()).sync(store: store)
        XCTAssertEqual(api.fetchCalls, 0)
        for changes in [["data_source": "intervals"], ["data_source": "app", "app_summary_consent": false],
                        ["data_source": "app", "app_summary_consent": true, "sms_enabled": false]] as [[String: Any]] {
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(morningFixtureJSON.utf8)) as? [String: Any])
            raw.merge(changes) { _, new in new }
            api.json = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
            await MorningSummarySync(api: api, tokenStore: MorningSessionStub(token: "fixture")).sync(store: store)
        }
        XCTAssertTrue(api.uploadedSummaries.isEmpty)
        XCTAssertEqual(api.subscribeCalls, 0)
    }

    @MainActor
    func testFailedEnableRetainsServerStatusAndDoesNotClaimConsent() async throws {
        let api = MorningServiceStub()
        let model = MorningStatusViewModel(api: api, tokenStore: MorningSessionStub(token: "fixture"))
        await model.load()
        let before = model.status
        api.error = MorningStatusError.consentRequired
        await model.enableAppMorning(timezone: "UTC")
        XCTAssertEqual(model.status, before)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.notice)
        XCTAssertTrue(api.uploadedSummaries.isEmpty)
    }
}
