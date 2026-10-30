import Foundation

/// Coalesces automatic requests and limits retries while keeping manual sync independent.
@MainActor
final class AutoSyncCoordinator {
    private let sync: () async throws -> Void
    private let clock: () -> Date
    private let calendar: Calendar
    private var isRunning = false
    private var lastSuccess: Date?
    private var lastFailure: Date?
    private var pendingChange = false

    init(calendar: Calendar = .autoupdatingCurrent, clock: @escaping () -> Date = Date.init,
         sync: @escaping () async throws -> Void) {
        self.calendar = calendar
        self.clock = clock
        self.sync = sync
    }

    /// Foreground checks run at most every 15 minutes, except when the local day changes.
    /// A data-change request may run sooner, but is limited to once per minute.
    /// All automatic requests observe the five-minute failure backoff.
    func requestIfNeeded(lastComputation: Date?, force: Bool = false) async {
        if force { pendingChange = true }
        guard !isRunning else { return }
        let now = clock()
        if let lastFailure, lastFailure <= now,
           now.timeIntervalSince(lastFailure) < 5 * 60 { return }

        let reference = [lastSuccess, lastComputation].compactMap { date -> Date? in
            guard let date, date <= now else { return nil }
            return date
        }.max()
        if let reference {
            let elapsed = now.timeIntervalSince(reference)
            if pendingChange {
                guard elapsed >= 60 else { return }
            } else if calendar.isDate(reference, inSameDayAs: now) {
                guard elapsed >= 15 * 60 else { return }
            }
        }

        let includesChange = pendingChange
        pendingChange = false
        isRunning = true
        defer { isRunning = false }
        do {
            try await sync()
            lastSuccess = clock()
            lastFailure = nil
        } catch {
            pendingChange = pendingChange || includesChange
            lastFailure = clock()
        }
    }
}
