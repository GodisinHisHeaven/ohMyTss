import BackgroundTasks
import Foundation
import os

/// Requests short, system-scheduled refresh opportunities. iOS decides when
/// these run, and may defer them indefinitely.
@MainActor
final class BackgroundRefreshScheduler {
    static let identifier = "mj6.onMyTss.refresh"
    private let sync: @MainActor () async throws -> Void
    private let logger = Logger(subsystem: "mj6.onMyTss", category: "BackgroundRefresh")

    init(sync: @escaping @MainActor () async throws -> Void) {
        self.sync = sync
    }

    /// Call once during application launch, before launch has finished.
    @discardableResult
    func register() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { [weak self] task in
            let work = Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.schedule()
                let success: Bool
                do {
                    try Task.checkCancellation()
                    try await self.sync()
                    try Task.checkCancellation()
                    success = true
                } catch {
                    success = false
                }
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Resubmitting a pending identifier replaces its existing request.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Could not schedule background refresh")
        }
    }
}
