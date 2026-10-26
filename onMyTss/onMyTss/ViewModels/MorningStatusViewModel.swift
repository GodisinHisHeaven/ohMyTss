import Foundation
import Observation

@MainActor
@Observable
final class MorningStatusViewModel {
    private let api: any MorningStatusServing
    private let tokenStore: any MorningSessionStoring
    private var token: String?
    var status: MorningStatus?
    var isBusy = false
    var errorMessage: String?
    var notice: String?
    var isSignedIn: Bool { token != nil }

    convenience init() {
        self.init(api: MorningStatusAPI(), tokenStore: MorningSessionKeychain())
    }

    init(api: any MorningStatusServing, tokenStore: any MorningSessionStoring) {
        self.api = api
        self.tokenStore = tokenStore
    }

    func load() async {
        guard !isBusy else { return }
        do { token = try tokenStore.load() }
        catch { errorMessage = error.localizedDescription; return }
        if token != nil { await refresh() }
        else { status = nil }
    }

    func signIn(email: String, password: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        notice = nil
        defer { isBusy = false }
        do {
            let newToken = try await api.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            try tokenStore.save(newToken)
            token = newToken
        } catch MorningStatusError.unauthorized {
            errorMessage = "Email or password is incorrect. Use your existing morning status account."
            return
        } catch {
            errorMessage = message(for: error)
            return
        }
        do { status = try await api.fetchStatus(token: token!) }
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
