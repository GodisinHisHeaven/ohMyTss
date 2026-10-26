#if DEBUG
import Foundation

// Used only with the explicit UI-test launch flag. No Keychain, network or SMS.
@MainActor
final class MorningStatusUIFixture: MorningStatusServing {
    var timezone = "UTC"
    var subscribed = true

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
                      hasTodayData: true, inDeliveryWindow: false,
                      wellness: .init(hrv: 50, restingHr: 55, sleepHours: 7.5, tsb: -3),
                      lastActivitySync: nil, wellnessThrough: "2026-10-25", syncFailures: 0)
    }
    func updateTimezone(_ timezone: String, token: String) async throws -> MorningStatus {
        self.timezone = timezone
        return try await fetchStatus(token: token)
    }
    func unsubscribe(token: String) async throws -> MorningStatus {
        subscribed = false
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
