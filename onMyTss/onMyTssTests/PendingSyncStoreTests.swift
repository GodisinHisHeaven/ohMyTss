import Foundation
import XCTest
@testable import onMyTss

@MainActor
final class PendingSyncStoreTests: XCTestCase {
    func testPendingSurvivesRecreationAndAcknowledgementSurvivesRecreation() throws {
        try withStoreURL { url in
            let first = PendingSyncStore(url: url)
            XCTAssertNil(try first.pendingRevision())
            let revision = try first.markPending()
            XCTAssertEqual(try PendingSyncStore(url: url).pendingRevision(), revision)
            try PendingSyncStore(url: url).acknowledge(through: revision)
            XCTAssertNil(try PendingSyncStore(url: url).pendingRevision())
            let later = try PendingSyncStore(url: url).markPending()
            XCTAssertEqual(later.epoch, revision.epoch)
            XCTAssertGreaterThan(later.value, revision.value)
        }
    }

    func testAcknowledgementDoesNotLoseAnEventDuringSync() throws {
        try withStoreURL { url in
            let store = PendingSyncStore(url: url)
            let captured = try store.markPending()
            let later = try store.markPending()
            try store.acknowledge(through: captured)
            XCTAssertEqual(try PendingSyncStore(url: url).pendingRevision(), later)
            try store.acknowledge(through: later)
            XCTAssertNil(try store.pendingRevision())
            try store.acknowledge(through: captured)
            XCTAssertNil(try store.pendingRevision())
        }
    }

    func testUnknownRevisionCannotAcknowledgePendingChange() throws {
        try withStoreURL { url in
            let store = PendingSyncStore(url: url)
            let revision = try store.markPending()
            let unknown = PendingSyncStore.Revision(epoch: revision.epoch, value: revision.value + 1)
            XCTAssertThrowsError(try store.acknowledge(through: unknown))
            XCTAssertEqual(try store.pendingRevision(), revision)
        }
    }

    func testLegacyStateGetsStablePersistedEpoch() throws {
        try withStoreURL { url in
            try Data(#"{"revision":4,"acknowledged":2}"#.utf8).write(to: url)
            let token = try XCTUnwrap(PendingSyncStore(url: url).pendingRevision())
            XCTAssertEqual(token.value, 4)
            XCTAssertEqual(try PendingSyncStore(url: url).pendingRevision(), token)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(json["epoch"] as? String, token.epoch.uuidString)
        }
    }

    func testRecoveredGenerationCannotBeAcknowledgedByOldToken() throws {
        try withStoreURL { url in
            let store = PendingSyncStore(url: url)
            let old = try store.markPending()
            try Data("corrupt".utf8).write(to: url)
            let recovered = try XCTUnwrap(store.pendingRevision())
            XCTAssertEqual(old.value, recovered.value)
            XCTAssertNotEqual(old.epoch, recovered.epoch)
            try store.acknowledge(through: old)
            XCTAssertEqual(try store.pendingRevision(), recovered)
        }
    }

    func testCorruptStateIsBackedUpAndRestoredAsPending() throws {
        try withStoreURL { url in
            let corrupt = Data("not valid json".utf8)
            try corrupt.write(to: url)
            let store = PendingSyncStore(url: url)
            let revision = try XCTUnwrap(store.pendingRevision())
            XCTAssertEqual(try PendingSyncStore(url: url).pendingRevision(), revision)
            let backups = try recoveryBackups(at: url)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path))
        }
    }

    func testInvalidRevisionOrderIsBackedUp() throws {
        try withStoreURL { url in
            let corrupt = Data(#"{"revision":1,"acknowledged":2}"#.utf8)
            try corrupt.write(to: url)
            XCTAssertNotNil(try PendingSyncStore(url: url).pendingRevision())
            let backups = try recoveryBackups(at: url)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
        }
    }

    func testBackupFailurePreservesOriginalAndRetryCompletesRecovery() throws {
        try withStoreURL { url in
            let corrupt = Data("damaged marker".utf8)
            try corrupt.write(to: url)
            let failing = PendingSyncStore(url: url, moveForRecovery: { _, _ in throw ProbeError.backup })
            XCTAssertThrowsError(try failing.pendingRevision())
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path))
            XCTAssertNotNil(try PendingSyncStore(url: url).pendingRevision())
            let backups = try recoveryBackups(at: url)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
        }
    }

    func testRecoveryResumesAfterMoveAndKeepsBackup() throws {
        try withStoreURL { url in
            let corrupt = Data("interrupted recovery".utf8)
            try corrupt.write(to: url)
            try Data("pending recovery".utf8).write(to: url.appendingPathExtension("recovery"))
            let backup = url.deletingLastPathComponent().appendingPathComponent("state.json.corrupt.saved")
            try FileManager.default.moveItem(at: url, to: backup)
            XCTAssertNotNil(try PendingSyncStore(url: url).pendingRevision())
            XCTAssertEqual(try Data(contentsOf: backup), corrupt)
            XCTAssertNotNil(try PendingSyncStore(url: url).pendingRevision())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path))
        }
    }

    func testFailedIntentRemovalKeepsPendingAcrossRestart() throws {
        try withStoreURL { url in
            let corrupt = Data("invalid".utf8)
            try corrupt.write(to: url)
            let failing = PendingSyncStore(url: url, removeRecoveryIntent: { _ in throw ProbeError.cleanup })
            XCTAssertThrowsError(try failing.pendingRevision())
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path))
            XCTAssertNotNil(try PendingSyncStore(url: url).pendingRevision())
            let backups = try recoveryBackups(at: url)
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
        }
    }

    func testReadIOErrorDoesNotStartRecovery() throws {
        try withStoreURL { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertThrowsError(try PendingSyncStore(url: url).pendingRevision())
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path))
            XCTAssertTrue(try recoveryBackups(at: url).isEmpty)
        }
    }

    func testFailedAcknowledgementRetainsPendingState() throws {
        try withStoreURL { url in
            let store = PendingSyncStore(url: url)
            let revision = try store.markPending()
            let directory = url.deletingLastPathComponent()
            let moved = directory.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: directory, to: moved)
            try Data().write(to: directory)
            XCTAssertThrowsError(try store.acknowledge(through: revision))
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.moveItem(at: moved, to: directory)
            XCTAssertEqual(try PendingSyncStore(url: url).pendingRevision(), revision)
        }
    }

    private func withStoreURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathExtension("saved"))
        }
        try body(directory.appendingPathComponent("state.json"))
    }

    private func recoveryBackups(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                     includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt.") }
    }

    private enum ProbeError: Error { case backup, cleanup }
}
