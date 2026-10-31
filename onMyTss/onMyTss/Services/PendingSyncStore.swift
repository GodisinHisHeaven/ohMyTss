import Foundation

/// Durable change revisions. Acknowledgement only covers events observed by a sync.
/// Use one shared instance on the main actor for foreground and background work.
@MainActor
final class PendingSyncStore {
    private struct State: Codable {
        var epoch: UUID? = nil
        var revision: UInt64 = 0
        var acknowledged: UInt64 = 0
    }

    struct Revision: Equatable {
        let epoch: UUID
        let value: UInt64
    }

    enum StoreError: Error {
        case invalidState
        case revisionExhausted
        case unknownRevision
    }

    private let url: URL
    private let moveForRecovery: (URL, URL) throws -> Void
    private let removeRecoveryIntent: (URL) throws -> Void
    private var intentURL: URL { url.appendingPathExtension("recovery") }

    init(url: URL,
         moveForRecovery: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         removeRecoveryIntent: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.url = url
        self.moveForRecovery = moveForRecovery
        self.removeRecoveryIntent = removeRecoveryIntent
    }

    @discardableResult
    func markPending() throws -> Revision {
        var state = try read()
        guard state.revision < UInt64.max else { throw StoreError.revisionExhausted }
        state.revision += 1
        try write(state)
        return Revision(epoch: state.epoch!, value: state.revision)
    }

    func pendingRevision() throws -> Revision? {
        let state = try read()
        return state.revision > state.acknowledged ? Revision(epoch: state.epoch!, value: state.revision) : nil
    }

    func isAcknowledged(_ revision: Revision) throws -> Bool {
        let state = try read()
        return state.epoch == revision.epoch && revision.value <= state.acknowledged
    }

    func acknowledge(through revision: Revision) throws {
        var state = try read()
        // A pass from a quarantined generation cannot acknowledge recovered work.
        guard revision.epoch == state.epoch else { return }
        guard revision.value <= state.revision else { throw StoreError.unknownRevision }
        guard revision.value > state.acknowledged else { return }
        state.acknowledged = revision.value
        try write(state)
    }

    private func read() throws -> State {
        var state: State
        if try hasRecoveryIntent() {
            state = try completeRecovery()
        } else {
            do {
                guard let existing = try readExisting() else { return State(epoch: UUID()) }
                state = existing
            } catch is DecodingError {
                try writeRecoveryIntent()
                state = try completeRecovery()
            } catch StoreError.invalidState {
                try writeRecoveryIntent()
                state = try completeRecovery()
            }
        }
        // Legacy JSON has no epoch. Persist before issuing any token so every
        // subsequent reader refers to the same generation.
        if state.epoch == nil {
            state.epoch = UUID()
            try write(state)
        }
        return state
    }

    private func readExisting() throws -> State? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.acknowledged <= state.revision else { throw StoreError.invalidState }
        return state
    }

    private func hasRecoveryIntent() throws -> Bool {
        do {
            _ = try Data(contentsOf: intentURL)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private func writeRecoveryIntent() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pending recovery".utf8).write(to: intentURL, options: .atomic)
    }

    /// Intent is written before moving the corrupt file. If interrupted at any
    /// step, the next read resumes and guarantees a pending revision.
    private func completeRecovery() throws -> State {
        var state = State()
        do {
            if var existing = try readExisting() {
                if existing.revision == existing.acknowledged {
                    guard existing.revision < UInt64.max else { throw StoreError.revisionExhausted }
                    existing.revision += 1
                    try write(existing)
                }
                state = existing
            } else {
                state = State(epoch: UUID(), revision: 1, acknowledged: 0)
                try write(state)
            }
        } catch is DecodingError {
            state = try quarantineAndRebuild()
        } catch StoreError.invalidState {
            state = try quarantineAndRebuild()
        }
        // Failure leaves the intent in place, so a later read repeats recovery.
        try removeRecoveryIntent(intentURL)
        return state
    }

    private func quarantineAndRebuild() throws -> State {
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt.\(UUID().uuidString)"
        )
        // Never replace the original unless it was successfully preserved first.
        try moveForRecovery(url, backup)
        let state = State(epoch: UUID(), revision: 1, acknowledged: 0)
        try write(state)
        return state
    }

    private func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
