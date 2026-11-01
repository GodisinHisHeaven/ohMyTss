import Foundation
import SwiftData
import UIKit
import os

/// One container and engine are shared by foreground and system background work.
@MainActor
final class AppSyncRuntime: BodyBatteryEngineProtocol {
    static let shared = AppSyncRuntime()
    private var container: ModelContainer?
    private(set) var dataStore: DataStore?
    private var engine: BodyBatteryEngine?
    var isProcessing: Bool { engine?.isProcessing == true }
    private let pending: PendingSyncStore
    private var volatilePending = false
    private let logger = Logger(subsystem: "mj6.onMyTss", category: "BackgroundSync")
    private lazy var runner = PendingSyncRunner(store: pending, onDrained: { [unowned self] in
        let fixture = !WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments)
        guard !fixture else { return true }
        guard !self.volatilePending && WeeklyWorkoutSync.finishSourceSync(success: true) else {
            if let store = self.dataStore { Self.noteWidgetUpdatePending(store: store) }
            self.markUntrackedChange()
            return false
        }
        return true
    }) { [unowned self] in
        try await self.performSync()
    }

    private init() {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--v2-ui-tests") {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        }
        #endif
        pending = PendingSyncStore(url: directory.appendingPathComponent("ohmytss/pending-sync.json"))
    }

    #if DEBUG
    /// Isolated injection for tests; never opens or mutates the shared app store.
    init(testEngine: BodyBatteryEngine, pendingURL: URL) {
        engine = testEngine
        pending = PendingSyncStore(url: pendingURL)
    }
    #endif

    func open() throws -> ModelContainer {
        if let container { return container }
        if WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments),
           !WeeklyWorkoutSync.recoverInterruptedSourceSync() {
            volatilePending = true
            logger.error("Could not recover widget source status")
        }
        if WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments) {
            let hasPending: Bool
            do { hasPending = try pending.pendingRevision() != nil } catch { hasPending = true }
            if hasPending && !WeeklyWorkoutSync.invalidateSource() {
                volatilePending = true
                logger.error("Could not invalidate pending widget data")
            }
        }
        let newContainer = try ohMyTssApp.makeModelContainer()
        let store = DataStore(modelContext: newContainer.mainContext)
        let state = try store.fetchAppState()
        if LocalWorkoutHistoryRepair.isRequired(state),
           WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments),
           !WeeklyWorkoutSync.invalidateSource() {
            volatilePending = true
            logger.error("Could not invalidate widget data for local history repair")
        }
        var health = HealthKitManager()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--v2-ui-tests") && arguments.contains("--v2-sync-fixture") {
            health = ActivitySyncUIFixture()
        }
        #endif
        let newEngine = BodyBatteryEngine(healthKitManager: health, dataStore: store)
        container = newContainer
        dataStore = store
        engine = newEngine
        return newContainer
    }

    var hasPendingChange: Bool {
        // Treat an unreadable retry file as pending, never as an empty queue.
        if volatilePending { return true }
        do { return try pending.pendingRevision() != nil } catch { return true }
    }

    /// Uses the same engine gate as foreground and background source sync.
    func repairLocalWorkoutHistoryIfNeeded() async throws {
        guard let engine else { throw BackgroundSyncError.incomplete }
        try await engine.repairLocalWorkoutHistoryIfNeeded()
    }

    func recomputeAll() async throws {
        // Manual work must still run after any in-flight pass, and its failure
        // needs a durable retry even if there was no HealthKit event.
        let requested: PendingSyncStore.Revision?
        do {
            requested = try pending.markPending()
            volatilePending = false
        } catch {
            volatilePending = true
            logger.error("Could not save sync retry marker; manual sync will proceed")
            requested = nil
        }
        do {
            if let requested { try await runner.run(through: requested) }
            else { try await runner.runWithoutStore() }
        }
        catch PendingSyncRunner.RunnerError.incomplete { /* Show source warnings from the engine. */ }
    }
    func incrementalUpdate() async throws {
        do { try pending.markPending() }
        catch {
            markUntrackedChange()
            throw error
        }
        volatilePending = false
        try await runner.run()
    }

    /// Persist first: if the process is killed or data is locked, the next run retries.
    func healthKitChanged() {
        // Invalidate before recording: a crash between these writes can only
        // leave freshness unknown, never leave a queued change appearing fresh.
        let fixture = !WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments)
        let invalidated = fixture || WeeklyWorkoutSync.invalidateSource()
        if !invalidated { markUntrackedChange() }
        do {
            let change = try runner.recordChange()
            if invalidated { volatilePending = false }
            guard change.shouldRun else { return }
            let lease = BackgroundSyncLease()
            guard lease.start(work: { [weak self] in
                guard let self else { return }
                do { try await self.runner.run(through: change.revision) } catch { }
            }) else {
                logger.error("No background time available; sync remains pending")
                AppBackgroundDelegate.current?.scheduleRefresh()
                return
            }
        } catch {
            // No durable guarantee until a marker can be written. The source
            // anchor is unchanged, so a later incremental sync can recover it.
            markUntrackedChange()
            logger.error("Could not save HealthKit retry marker; scheduling recovery")
        }
    }

    func backgroundRefresh() async throws {
        do { try pending.markPending() }
        catch {
            markUntrackedChange()
            throw error
        }
        volatilePending = false
        try await runner.run()
    }

    private func markUntrackedChange() {
        volatilePending = true
        if WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments) {
            _ = WeeklyWorkoutSync.finishSourceSync(success: false)
        }
        AppBackgroundDelegate.current?.scheduleRefresh()
    }

    /// Preserve the source result while making a delayed widget update visible.
    @discardableResult
    static func noteWidgetUpdatePending(store: DataStore) -> Bool {
        do {
            let state = try store.fetchAppState()
            let note = "Widget may not be up to date yet."
            let previous = state.lastSyncMessage ?? "Workouts updated."
            if !previous.contains(note) {
                state.lastSyncMessage = previous + "\n" + note
                try store.saveAppState(state)
            }
            return true
        } catch {
            return false
        }
    }

    private func performSync() async throws -> Bool {
        let fixture = !WeeklyWorkoutSync.allowsPublishing(arguments: ProcessInfo.processInfo.arguments)
        do {
            _ = try open()
        } catch {
            if !fixture { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
            throw error
        }
        guard let engine, let dataStore else {
            if !fixture { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
            throw BackgroundSyncError.incomplete
        }
        let tracking = fixture || WeeklyWorkoutSync.beginSourceSync()
        if !tracking { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
        do {
            try await engine.incrementalUpdate()
            try Task.checkCancellation()
            // Failed sources invalidate freshness, while successfully saved
            // activities remain visible and can still be published.
            let complete = tracking && !volatilePending && !engine.lastSyncRequiresRetry
            if !complete && !fixture { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
            let published = fixture || WeeklyWorkoutSync.publish(store: dataStore)
            guard complete && published else {
                if !fixture { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
                if !fixture { Self.noteWidgetUpdatePending(store: dataStore) }
                return false
            }
            // The runner clears invalidation only after this revision and all
            // changes that arrived during the pass have been acknowledged.
            return true
        } catch {
            if !fixture { _ = WeeklyWorkoutSync.finishSourceSync(success: false) }
            throw error
        }
    }

    private enum BackgroundSyncError: Error { case incomplete }
}

/// The HealthKit callback can return after recording its revision. This lease
/// gives the resulting work background time; expiration cancels the pass, whose
/// revision remains pending until another launch or system refresh.
@MainActor
final class BackgroundSyncLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var task: Task<Void, Never>?

    func start(work: @escaping @MainActor () async -> Void) -> Bool {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Workout sync") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        guard identifier != .invalid else { return false }
        task = Task { @MainActor in
            await work()
            self.finish()
        }
        return true
    }

    private func expire() {
        task?.cancel()
        finish()
    }

    private func finish() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
        task = nil
    }
}

/// Registers system handlers before the app finishes launching, even with no UI.
@MainActor
final class AppBackgroundDelegate: NSObject, UIApplicationDelegate {
    static weak var current: AppBackgroundDelegate?
    private var observer: HealthKitBackgroundObserver?
    private var scheduler: BackgroundRefreshScheduler?
    private var enablingDelivery = false
    private let logger = Logger(subsystem: "mj6.onMyTss", category: "BackgroundSync")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--v2-ui-tests") { return true }
        #endif
        Self.current = self
        let observer = HealthKitBackgroundObserver { AppSyncRuntime.shared.healthKitChanged() }
        self.observer = observer
        observer.start()
        let scheduler = BackgroundRefreshScheduler { try await AppSyncRuntime.shared.backgroundRefresh() }
        self.scheduler = scheduler
        if scheduler.register() { scheduler.schedule() }
        else { logger.error("Background refresh registration failed") }
        enableHealthDelivery()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        enableHealthDelivery()
    }

    func scheduleRefresh() { scheduler?.schedule() }

    func enableHealthDelivery() {
        guard let observer, !enablingDelivery else { return }
        enablingDelivery = true
        Task {
            defer { enablingDelivery = false }
            let failures = await observer.enableDelivery()
            if !failures.isEmpty { logger.error("HealthKit background registration failed for \(failures.count) data types") }
        }
    }
}
