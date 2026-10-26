import Foundation
import SwiftData

/// Coordinates local writes with derived estimates. No HealthKit or UI dependencies.
@MainActor
final class V2Store {
    private let context: ModelContext
    private let clock: () -> Date

    // Avoid the older Swift runtime's isolated-deinit crash (swiftlang/swift#88036).
    nonisolated deinit {}

    init(context: ModelContext, clock: @escaping () -> Date = Date.init) {
        self.context = context
        self.clock = clock
    }

    func saveObservation(_ observation: LocalObservation) throws {
        guard Region(rawValue: observation.regionRaw) != nil,
              BodySide(rawValue: observation.sideRaw) != nil,
              observation.observedAt <= clock(),
              observation.severity.map({ (0...4).contains($0) }) ?? true else {
            throw V2StoreError.invalidObservation
        }
        if observation.discomfortRaw == "none" {
            observation.severity = 0
            observation.weakness = false
            observation.tightness = false
            observation.limitedMovement = false
        } else if DiscomfortKind(rawValue: observation.discomfortRaw) == nil {
            throw V2StoreError.invalidObservation
        }
        observation.updatedAt = clock()
        context.insert(observation)
        try context.save()
    }

    func deleteObservation(_ observation: LocalObservation) throws {
        context.delete(observation)
        try context.save()
    }

    func createStrengthSession(start: Date, duration: TimeInterval) throws -> Workout {
        guard start <= clock(), duration.isFinite, duration > 0 else { throw V2StoreError.invalidSession }
        let row = Workout(id: "manual:\(UUID().uuidString)", date: Calendar.current.startOfDay(for: start),
                          startTime: start, duration: duration, workoutType: "Strength", tss: 0,
                          calculationMethod: "unknown", source: .manual)
        context.insert(row)
        try recalculate(row)
        return row
    }

    func saveSet(_ record: StrengthSetRecord) throws {
        try saveSets([record])
    }

    func saveSets(_ records: [StrengthSetRecord]) throws {
        // Validate the entire batch before inserting any row, preventing partial multi-set retries.
        var sessions: [Workout] = []
        for record in records {
            guard (1...500).contains(record.reps),
                  record.weightKG.map({ $0.isFinite && (0...1500).contains($0) }) ?? true,
                  record.rir.map({ (0...10).contains($0) }) ?? true,
                  record.effortRaw.map({ StrengthEffort(rawValue: $0) != nil }) ?? true,
                  record.manualRegionsRaw.allSatisfy({ Region(rawValue: $0) != nil }),
                  ExerciseCatalog.exercises.contains(where: { $0.id == record.exerciseID }) || !record.manualRegionsRaw.isEmpty,
                  let session = try workout(record.sessionID), !session.isTombstoned, !session.isSuppressed else {
                throw V2StoreError.invalidSet
            }
            if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        }
        // The UI's repeated-set operation is one session; refuse a cross-session batch rather than partially commit.
        guard sessions.count <= 1 else { throw V2StoreError.invalidSession }
        do {
            for record in records {
                record.updatedAt = clock()
                context.insert(record)
            }
            for session in sessions { try recalculate(session) }
        } catch {
            context.rollback()
            throw error
        }
    }

    func deleteSet(_ record: StrengthSetRecord) throws {
        let session = try workout(record.sessionID)
        context.delete(record)
        if let session { try recalculate(session) } else { try context.save() }
    }

    /// Explicit user-confirmed merge keeps imported cardio only once and moves independent local records.
    func linkSession(manual: Workout, to target: Workout) throws {
        guard manual.source == WorkoutSource.manual.rawValue, manual.id != target.id,
              !target.isTombstoned, !target.isSuppressed, target.source != WorkoutSource.manual.rawValue,
              manual.linkedSessionID == nil else { throw V2StoreError.invalidSession }
        for row in try context.fetch(FetchDescriptor<StrengthSetRecord>()) where row.sessionID == manual.id {
            row.sessionID = target.id
        }
        for row in try context.fetch(FetchDescriptor<LocalObservation>()) where row.sessionID == manual.id {
            row.sessionID = target.id
        }
        target.userTags = Array(Set(target.userTags + manual.userTags)).sorted()
        manual.userTags = []
        manual.linkedSessionID = target.id
        manual.isSuppressed = true
        try recalculate(target)
        try DataStore(modelContext: context).rebuildLegacyLoadHistory(now: clock())
    }

    func deleteSession(_ session: Workout) async throws {
        // Delete the logical session, retaining source tombstones and all user records for audit.
        let all = try context.fetch(FetchDescriptor<Workout>())
        let ids = relatedIDs(to: session.id, in: all)
        for row in all where ids.contains(row.id) {
            row.isTombstoned = true
            row.deletionOrigin = "user"
            row.isSuppressed = true
        }
        try DataStore(modelContext: context).rebuildLegacyLoadHistory(now: clock())
        try await refreshEstimates()
        try context.save()
    }

    func saveTemplate(name: String, sets: [StrengthSetRecord]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sets.isEmpty else {
            throw V2StoreError.invalidSet
        }
        let data = try encoder.encode(sets.map(input))
        context.insert(StrengthTemplate(name: name, setsData: data))
        try context.save()
    }

    func applyTemplate(_ template: StrengthTemplate, to session: Workout) throws {
        guard !session.isTombstoned && !session.isSuppressed else { throw V2StoreError.invalidSession }
        let sets = try JSONDecoder().decode([StrengthSetInput].self, from: template.setsData)
        for set in sets {
            context.insert(StrengthSetRecord(sessionID: session.id, exerciseID: set.exerciseID,
                                            reps: set.reps, weightKG: set.weightKG, rir: set.rir,
                                            effortRaw: set.effort?.rawValue, manualRegionsRaw: set.manualRegions.map(\.rawValue)))
        }
        try recalculate(session)
    }

    /// Recompute immutable inputs off the UI actor and persist bounded batches.
    func refreshEstimates() async throws {
        try await updateEstimates(onlyMissing: false)
    }

    func backfillEstimates() async throws {
        try await updateEstimates(onlyMissing: true)
    }

    private func updateEstimates(onlyMissing: Bool) async throws {
        processing: while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
            if !onlyMissing { try resolveAliases() }
            let snapshot = try V2EstimateBatch(context: context)
            let now = clock()
            let calculation = Task.detached(priority: .utility) {
                try await V2EstimateCalculator.shared.calculate(snapshot, now: now, onlyMissing: onlyMissing)
            }
            let pending = try await withTaskCancellationHandler {
                try await calculation.value
            } onCancel: { calculation.cancel() }
            try Task.checkCancellation()
            let afterCalculation = try V2EstimateBatch(context: context, includePrevious: false)
            guard snapshot.hasSameInputs(as: afterCalculation) else { continue processing }
            guard !pending.isEmpty else { return }
            for offset in stride(from: 0, to: pending.count, by: 50) {
                try Task.checkCancellation()
                let current = try V2EstimateBatch(context: context, includePrevious: false)
                // An edit, deletion or newer threshold made this calculation stale.
                // Recompute from the new values before appending any more snapshots.
                guard snapshot.hasSameInputs(as: current) else { continue processing }
                let batch = pending[offset..<min(offset + 50, pending.count)]
                let latest = try V2EstimateBatch.latestEstimates(context: context, sessionIDs: batch.map(\.sessionID))
                for row in batch {
                    // Another caller may have completed this same refresh while we
                    // were suspended. Keep append-only history without duplicates.
                    if latest[row.sessionID]?.inputData == row.inputData
                        && latest[row.sessionID]?.version == row.value.version { continue }
                    insert(row)
                }
                try context.save()
                try await Task.sleep(for: .milliseconds(10))
            }
            return
        }
    }

    private func resolveAliases() throws {
        let all = try context.fetch(FetchDescriptor<Workout>())
        let children = Dictionary(grouping: all.filter { $0.linkedSessionID != nil }, by: { $0.linkedSessionID! })
        let sets = Dictionary(grouping: try context.fetch(FetchDescriptor<StrengthSetRecord>()), by: \.sessionID)
        let observations = Dictionary(grouping: try context.fetch(FetchDescriptor<LocalObservation>()), by: \.sessionID)
        for canonical in all where !canonical.isTombstoned && !canonical.isSuppressed {
            var ids: Set<String> = [canonical.id]
            var pending = [canonical.id]
            while let id = pending.popLast() {
                for child in children[id] ?? [] where ids.insert(child.id).inserted { pending.append(child.id) }
            }
            for id in ids where id != canonical.id {
                for row in sets[id] ?? [] { row.sessionID = canonical.id }
                for row in observations[id] ?? [] { row.sessionID = canonical.id }
            }
        }
        if context.hasChanges { try context.save() }
    }

    func recalculate(_ session: Workout) throws {
        guard !session.isTombstoned, !session.isSuppressed else { try context.save(); return }
        let batch = try V2EstimateBatch(context: context)
        for row in try batch.calculate(now: clock(), sessionID: session.id) { insert(row) }
        try context.save()
    }

    private func insert(_ row: V2EstimateBatch.Pending) {
        context.insert(LoadEstimateRecord(sessionID: row.sessionID, version: row.value.version,
                                         inputCutoff: row.value.inputCutoff, computedAt: row.value.computedAt,
                                         payloadData: row.payloadData, inputData: row.inputData))
    }

    private func workout(_ id: String) throws -> Workout? {
        try DataStore(modelContext: context).fetchWorkout(byId: id)
    }

    private func relatedIDs(to id: String, in rows: [Workout]) -> Set<String> {
        var ids: Set<String> = [id]
        var changed = true
        while changed {
            let old = ids.count
            for row in rows {
                if let link = row.linkedSessionID, ids.contains(link) { ids.insert(row.id) }
            }
            changed = old != ids.count
        }
        return ids
    }

    private func input(_ record: StrengthSetRecord) -> StrengthSetInput {
        StrengthSetInput(id: record.id, exerciseID: record.exerciseID, reps: record.reps, weightKG: record.weightKG,
                         rir: record.rir, effort: record.effortRaw.flatMap(StrengthEffort.init(rawValue:)),
                         manualRegions: record.manualRegionsRaw.compactMap(Region.init(rawValue:)))
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum V2StoreError: LocalizedError {
    case invalidObservation, invalidSet, invalidSession
    var errorDescription: String? {
        switch self {
        case .invalidObservation: return "Choose a region, side and a valid observation time and severity."
        case .invalidSet: return "Enter valid repetitions, optional weight and RIR (0–10), and an exercise or region."
        case .invalidSession: return "Choose an active session and a valid start time and duration."
        }
    }
}
