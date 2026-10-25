import Foundation
import SwiftData

/// Coordinates local writes with derived estimates. No HealthKit or UI dependencies.
@MainActor
final class V2Store {
    private let context: ModelContext
    private let clock: () -> Date
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
                  let session = try workout(record.sessionID), !session.isDeleted, !session.isSuppressed else {
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
              !target.isDeleted, !target.isSuppressed, target.source != WorkoutSource.manual.rawValue,
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

    func deleteSession(_ session: Workout) throws {
        // Delete the logical session, retaining source tombstones and all user records for audit.
        let all = try context.fetch(FetchDescriptor<Workout>())
        let ids = relatedIDs(to: session.id, in: all)
        for row in all where ids.contains(row.id) {
            row.isDeleted = true
            row.deletionOrigin = "user"
            row.isSuppressed = true
        }
        try DataStore(modelContext: context).rebuildLegacyLoadHistory(now: clock())
        try refreshEstimates()
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
        guard !session.isDeleted && !session.isSuppressed else { throw V2StoreError.invalidSession }
        let sets = try JSONDecoder().decode([StrengthSetInput].self, from: template.setsData)
        for set in sets {
            context.insert(StrengthSetRecord(sessionID: session.id, exerciseID: set.exerciseID,
                                            reps: set.reps, weightKG: set.weightKG, rir: set.rir,
                                            effortRaw: set.effort?.rawValue, manualRegionsRaw: set.manualRegions.map(\.rawValue)))
        }
        try recalculate(session)
    }

    /// Recompute all active sessions after import. Historical snapshots are never overwritten.
    func refreshEstimates() throws {
        let all = try context.fetch(FetchDescriptor<Workout>())
        // Resolve aliases after a later source arrives; retain old estimate snapshots under original IDs.
        for canonical in all where !canonical.isDeleted && !canonical.isSuppressed {
            let ids = relatedIDs(to: canonical.id, in: all)
            for row in try context.fetch(FetchDescriptor<StrengthSetRecord>()) where ids.contains(row.sessionID) {
                row.sessionID = canonical.id
            }
            for row in try context.fetch(FetchDescriptor<LocalObservation>()) {
                if let id = row.sessionID, ids.contains(id) { row.sessionID = canonical.id }
            }
            try recalculate(canonical)
        }
    }

    func recalculate(_ session: Workout) throws {
        guard !session.isDeleted, !session.isSuppressed else { try context.save(); return }
        let all = try context.fetch(FetchDescriptor<Workout>())
        let ids = relatedIDs(to: session.id, in: all)
        let sources = all.filter { ids.contains($0.id) && !$0.isDeleted }
        var features = session.features
        // Prefer valid time coverage, never sample count; sources can have radically different cadence.
        let window = TimeRange(start: session.startTime, end: features.end ?? session.startTime.addingTimeInterval(session.duration))
        func supported(_ values: [TimedValue], pauses: [TimeRange], range: ClosedRange<Double>) -> Double {
            SignalProcessing.coveredSeconds(SignalProcessing.intervals(samples: values, window: window, pauses: pauses, validRange: range))
        }
        for source in sources where source.id != session.id {
            let other = source.features
            if supported(other.heartRate, pauses: other.pauses, range: 30...240) > supported(features.heartRate, pauses: features.pauses, range: 30...240) { features.heartRate = other.heartRate }
            if supported(other.power, pauses: other.pauses, range: 0...2500) > supported(features.power, pauses: features.pauses, range: 0...2500) { features.power = other.power }
            if supported(other.cadence, pauses: other.pauses, range: 0...250) > supported(features.cadence, pauses: features.pauses, range: 0...250) { features.cadence = other.cadence }
            if supported(other.speed, pauses: other.pauses, range: 0...15) > supported(features.speed, pauses: features.pauses, range: 0...15) { features.speed = other.speed }
            if supported(other.elevation, pauses: other.pauses, range: -500...9000) > supported(features.elevation, pauses: features.pauses, range: -500...9000) { features.elevation = other.elevation }
            if supported(other.grade, pauses: other.pauses, range: -0.5...0.5) > supported(features.grade, pauses: features.pauses, range: -0.5...0.5) { features.grade = other.grade }
            if features.ascentMeters == nil { features.ascentMeters = other.ascentMeters }
            if features.descentMeters == nil { features.descentMeters = other.descentMeters }
            if other.swimSegments.count > features.swimSegments.count { features.swimSegments = other.swimSegments }
            if features.pauses.isEmpty { features.pauses = other.pauses }
            if features.end == nil { features.end = other.end }
            features.provenance = Array(Set(features.provenance + other.provenance)).sorted()
        }
        let setRecords = try context.fetch(FetchDescriptor<StrengthSetRecord>()).filter { ids.contains($0.sessionID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let sets = setRecords.map(input)
        let thresholds = try DataStore(modelContext: context).fetchUserThresholds()
        let priorRuns = all.filter {
            !$0.isDeleted && !$0.isSuppressed && $0.workoutType.lowercased().contains("run")
                && $0.startTime < session.startTime && $0.startTime >= session.startTime.addingTimeInterval(-28 * 86400)
                && ($0.features.end ?? $0.startTime.addingTimeInterval($0.duration)) <= session.startTime
        }
        let recentMinutes: Double? = priorRuns.isEmpty ? nil : priorRuns.reduce(0) { $0 + $1.duration / 60 }
        let tags = session.userTags.sorted()
        let snapshot = EstimateInput(type: session.workoutType, start: session.startTime, duration: session.duration,
                                     distance: session.distance, features: features, sets: sets, tags: tags,
                                     maxHeartRate: thresholds.cardioMaxHeartRate, recentRunningMinutes: recentMinutes,
                                     setRevisions: setRecords.map { SetRevision(id: $0.id, recordedAt: $0.recordedAt, updatedAt: $0.updatedAt) },
                                     thresholdsModifiedAt: thresholds.lastModified,
                                     sourceIDs: sources.map { "\($0.source):\($0.id)" }.sorted())
        let inputData = try encoder.encode(snapshot)
        let previous = try context.fetch(FetchDescriptor<LoadEstimateRecord>(sortBy: [SortDescriptor(\.computedAt, order: .reverse)]))
            .first { $0.sessionID == session.id }
        let now = clock()
        let estimate = LoadModel.estimate(type: session.workoutType, start: session.startTime, duration: session.duration,
                                          distance: session.distance, features: features, sets: sets, tags: tags,
                                          maxHeartRate: thresholds.cardioMaxHeartRate, now: now, recentRunningMinutes: recentMinutes)
        if previous?.inputData != inputData || previous?.version != estimate.version {
            context.insert(LoadEstimateRecord(sessionID: session.id, version: estimate.version,
                                             inputCutoff: estimate.inputCutoff, computedAt: now,
                                             payloadData: try encoder.encode(estimate), inputData: inputData))
        }
        try context.save()
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

private struct EstimateInput: Codable {
    var type: String
    var start: Date
    var duration: Double
    var distance: Double?
    var features: WorkoutFeatures
    var sets: [StrengthSetInput]
    var tags: [String]
    var maxHeartRate: Int?
    var recentRunningMinutes: Double?
    var setRevisions: [SetRevision]
    var thresholdsModifiedAt: Date
    var sourceIDs: [String]
}

private struct SetRevision: Codable {
    var id: UUID
    var recordedAt: Date
    var updatedAt: Date
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
