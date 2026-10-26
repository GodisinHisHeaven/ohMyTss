import Foundation
import Observation

@MainActor
@Observable
final class MorningStatusViewModel {
    private let api: any MorningStatusServing
    private let tokenStore: any MorningSessionStoring
    private let now: () -> Date
    private var token: String?
    private var submittedPhone: String?
    private var codeExpiresAt: Date?
    private var resendAvailableAt: Date?
    private(set) var verification: MorningPhoneChallenge?
    var status: MorningStatus?
    var isBusy = false
    var errorMessage: String?
    var notice: String?
    var isSignedIn: Bool { token != nil }

    convenience init() {
        self.init(api: MorningStatusAPI(), tokenStore: MorningSessionKeychain())
    }

    init(api: any MorningStatusServing, tokenStore: any MorningSessionStoring, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.tokenStore = tokenStore
        self.now = now
    }

    func load() async {
        guard !isBusy else { return }
        do { token = try tokenStore.load() }
        catch { errorMessage = error.localizedDescription; return }
        if token != nil { await refresh() }
        else { status = nil }
    }

    func resendSeconds(at date: Date) -> Int {
        max(0, Int(ceil((resendAvailableAt ?? .distantPast).timeIntervalSince(date))))
    }

    func requestCode(phone: String) async {
        guard !isBusy, !isSignedIn, resendSeconds(at: now()) == 0 else { return }
        guard let phone = MorningPhoneInput.normalized(phone) else {
            errorMessage = "Enter a US phone number, including area code."
            return
        }
        isBusy = true
        errorMessage = nil
        notice = nil
        defer { isBusy = false }
        do {
            let result = try await api.requestCode(phone: phone)
            submittedPhone = phone
            verification = result
            codeExpiresAt = now().addingTimeInterval(TimeInterval(result.expiresIn))
            resendAvailableAt = now().addingTimeInterval(TimeInterval(result.retryAfter))
        } catch {
            if case MorningStatusError.rateLimited = error {
                resendAvailableAt = now().addingTimeInterval(60)
            }
            errorMessage = message(for: error)
        }
    }

    func resendCode() async {
        guard let submittedPhone else { return }
        await requestCode(phone: submittedPhone)
    }

    func changePhone() {
        guard !isBusy else { return }
        verification = nil
        submittedPhone = nil
        codeExpiresAt = nil
        errorMessage = nil
    }

    func verifyCode(_ code: String) async {
        guard !isBusy, !isSignedIn, let verification else { return }
        guard MorningPhoneInput.validCode(code) else {
            errorMessage = "Enter the six-digit code from your text."
            return
        }
        guard let codeExpiresAt, now() < codeExpiresAt else {
            errorMessage = "This code has expired. Request a new code."
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let newToken = try await api.verifyCode(challenge: verification.challenge, code: code)
            self.verification = nil
            self.codeExpiresAt = nil
            submittedPhone = nil
            try tokenStore.save(newToken)
            token = newToken
        } catch MorningStatusError.unauthorized {
            errorMessage = "The code is incorrect or expired. Check it or request a new code."
            return
        } catch MorningStatusError.noSubscription {
            self.verification = nil
            self.codeExpiresAt = nil
            submittedPhone = nil
            errorMessage = MorningStatusError.noSubscription.localizedDescription
            return
        } catch {
            errorMessage = message(for: error)
            return
        }
        guard let token else { return }
        do { status = try await api.fetchStatus(token: token) }
        catch { handleAuthenticatedError(error) }
    }

    func refresh() async {
        await perform { try await self.api.fetchStatus(token: $0) }
    }

    func saveTimezone(_ timezone: String) async {
        await perform(notice: "Morning delivery time zone updated.") {
            try await self.api.updateTimezone(timezone, token: $0)
        }
    }

    func unsubscribe() async {
        await perform(notice: "Morning texts are turned off. Reply START to an existing ohMyTss text to resubscribe.") {
            try await self.api.unsubscribe(token: $0)
        }
    }

    func signOut() {
        guard !isBusy else { return }
        do {
            try tokenStore.delete()
            token = nil
            status = nil
            notice = nil
            errorMessage = nil
            verification = nil
            submittedPhone = nil
            codeExpiresAt = nil
        } catch { errorMessage = message(for: error) }
    }

    private func perform(notice successNotice: String? = nil,
                         operation: (String) async throws -> MorningStatus) async {
        guard !isBusy, let token else { return }
        isBusy = true
        errorMessage = nil
        notice = nil
        defer { isBusy = false }
        do {
            status = try await operation(token)
            notice = successNotice
        } catch { handleAuthenticatedError(error) }
    }

    private func handleAuthenticatedError(_ error: Error) {
        if case MorningStatusError.unauthorized = error {
            token = nil
            status = nil
            try? tokenStore.delete()
        }
        errorMessage = message(for: error)
    }

    private func message(for error: Error) -> String {
        if error is MorningStatusError { return error.localizedDescription }
        return "Unable to reach morning status. Check your connection and try again."
    }

    nonisolated deinit {}
}
