import BackgroundTasks
import Foundation
import os

@MainActor
final class BackgroundRefreshScheduler {
    nonisolated static let identifier = "mj6.onMyTss.refresh"
    private let sync: @MainActor () async throws -> Void
    private let hasPendingRequest: () async -> Bool
    private let submitRequest: (Date) async throws -> Void
    private var scheduling: Task<Void, Never>?
    private var needsSuccessor = false
    private let logger = Logger(subsystem: "mj6.onMyTss", category: "BackgroundRefresh")

    init(hasPendingRequest: @escaping () async -> Bool = {
        await BGTaskScheduler.shared.pendingTaskRequests().contains { $0.identifier == BackgroundRefreshScheduler.identifier }
    }, submitRequest: @escaping (Date) async throws -> Void = BackgroundRefreshScheduler.submit,
         sync: @escaping @MainActor () async throws -> Void) {
        self.hasPendingRequest = hasPendingRequest
        self.submitRequest = submitRequest
        self.sync = sync
    }

    @discardableResult
    func register() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.schedule(afterDelivery: true)
            let execution = BackgroundRefreshExecution(sync: self.sync) { task.setTaskCompleted(success: $0) }
            task.expirationHandler = { @Sendable in
                Task { @MainActor in execution.expire() }
            }
        }
    }

    /// An existing request keeps its original eligibility date across errors and relaunches.
    @discardableResult
    func schedule(afterDelivery: Bool = false) -> Task<Void, Never> {
        if afterDelivery { needsSuccessor = true }
        if let scheduling { return scheduling }
        let task = Task {
            defer { scheduling = nil }
            if !needsSuccessor, await hasPendingRequest(), !needsSuccessor { return }
            repeat {
                needsSuccessor = false
                do { try await submitRequest(Date(timeIntervalSinceNow: 15 * 60)) }
                catch { logger.error("Could not schedule background refresh") }
            } while needsSuccessor
        }
        scheduling = task
        return task
    }

    @concurrent private static func submit(_ earliest: Date) async throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliest
        if #available(iOS 27.0, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }
}

/// Expiration reports failure immediately, including while a HealthKit query is unwinding.
@MainActor
final class BackgroundRefreshExecution {
    private var completion: ((Bool) -> Void)?
    private var work: Task<Void, Never>?

    init(sync: @escaping @MainActor () async throws -> Void, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        work = Task {
            do {
                try Task.checkCancellation()
                try await sync()
                try Task.checkCancellation()
                finish(true)
            } catch {
                finish(false)
            }
        }
    }

    func expire() {
        work?.cancel()
        finish(false)
    }

    private func finish(_ success: Bool) {
        let callback = completion
        completion = nil
        work = nil
        callback?(success)
    }
}
