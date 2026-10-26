#if DEBUG
import Foundation

// Used only with the explicit UI-test launch flag. No Keychain, network or SMS.
@MainActor
final class MorningStatusUIFixture: MorningStatusServing {
    var timezone = "UTC"
    var subscribed = true
    var summary: MorningStatus.AppSummary?

    init() {
        if ProcessInfo.processInfo.arguments.contains("--morning-new-user-fixture") {
            subscribed = false
        } else {
            summary = .init(readinessScore: 72, sleepHours: 7.5, trainingMinutes7d: 210)
        }
    }

    func requestCode(phone: String) async throws -> MorningPhoneChallenge {
        guard phone == "+12025550100" else { throw MorningStatusError.invalidInput }
        return MorningPhoneChallenge(challenge: "ui-fixture-challenge", phoneHint: "Ending in 0100", expiresIn: 600, retryAfter: 60)
    }
    func verifyCode(challenge: String, code: String) async throws -> String {
        guard challenge == "ui-fixture-challenge", code == "123456" else {
            throw MorningStatusError.unauthorized
        }
        return "ui-fixture-session"
    }
    func fetchStatus(token: String) async throws -> MorningStatus {
        MorningStatus(displayName: "Sample Athlete", email: "athlete@example.invalid", phoneHint: "Ending in 0100",
                      timezone: timezone, localDate: "2026-10-25", windowStart: "06:00", windowEnd: "10:30",
                      smsState: subscribed ? "active" : "not_subscribed", smsEnabled: subscribed, sentToday: false,
                      hasTodayData: summary != nil, inDeliveryWindow: false,
                      wellness: nil,
                      lastActivitySync: nil, wellnessThrough: "2026-10-25", syncFailures: 0,
                      dataSource: "app", appSummaryConsent: subscribed,
                      requiresSmsRestart: false, appSummary: summary)
    }
    func updateTimezone(_ timezone: String, token: String) async throws -> MorningStatus {
        self.timezone = timezone
        return try await fetchStatus(token: token)
    }
    func unsubscribe(token: String) async throws -> MorningStatus {
        subscribed = false
        return try await fetchStatus(token: token)
    }
    func subscribe(timezone: String, token: String) async throws -> MorningStatus {
        subscribed = true
        self.timezone = timezone
        return try await fetchStatus(token: token)
    }
    func uploadSummary(_ summary: MorningAppSummary, token: String) async throws -> MorningStatus {
        self.summary = .init(readinessScore: summary.readinessScore, sleepHours: summary.sleepHours,
                             trainingMinutes7d: summary.trainingMinutes7d)
        return try await fetchStatus(token: token)
    }
    nonisolated deinit {}
}

@MainActor
final class MorningSessionUIFixture: MorningSessionStoring {
    private var token: String?
    func load() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func delete() throws { token = nil }
    nonisolated deinit {}
}
#endif
