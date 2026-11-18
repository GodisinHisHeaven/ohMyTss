import Foundation
import SwiftData

/// Only immutable values cross to the calculation task. SwiftData objects stay
/// on their context's actor, including when a user edits data during a refresh.
nonisolated struct V2EstimateBatch: Sendable {
    struct Session: Equatable, Sendable {
        let id: String
        let startTime: Date
        let duration: Double
        let type: String
        let distance: Double?
        let featuresData: Data?
        let tags: [String]
        let source: String
        let isGarmin: Bool
        let linkedID: String?
        let deleted: Bool
        let deletionOrigin: String?
        let suppressed: Bool
    }

    struct RecordedSet: Equatable, Sendable {
        let sessionID: String
        let input: StrengthSetInput
        let recordedAt: Date
        let updatedAt: Date
    }

    struct Previous: Sendable {
        let version: String
        let inputData: Data
    }

    struct Pending: Sendable {
        let sessionID: String
        let value: LoadEstimateValue
        let inputData: Data
        let payloadData: Data
    }

    let sessions: [Session]
    let sets: [RecordedSet]
    let maxHeartRate: Int?
    let thresholdsModifiedAt: Date
    let previous: [String: Previous]

    @MainActor init(context: ModelContext, includePrevious: Bool = true, sessionID: String? = nil) throws {
        let rows: [Workout]
        let setRows: [StrengthSetRecord]
        if let sessionID {
            // Editing one activity must not load sensor payloads and versioned
            // estimates for the entire history. Preserve linked sources and the
            // prior running window used by the existing calculation.
            let group = try Self.sourceGroup(context: context, sessionID: sessionID)
            let ids = group.map(\.id)
            setRows = try context.fetch(FetchDescriptor(predicate: #Predicate<StrengthSetRecord> {
                ids.contains($0.sessionID)
            }))
            if let target = group.first(where: { $0.id == sessionID && !$0.isTombstoned && !$0.isSuppressed }) {
                let end = target.startTime
                let start = end.addingTimeInterval(-28 * 86400)
                // Keep the same case-insensitive running-type rule in calculate.
                let recent = try context.fetch(FetchDescriptor(predicate: #Predicate<Workout> {
                    $0.startTime >= start && $0.startTime < end && !$0.isTombstoned && !$0.isSuppressed
                }))
                let groupIDs = Set(ids)
                rows = group + recent.filter { !groupIDs.contains($0.id) && $0.workoutType.lowercased().contains("run") }
            } else { rows = group }
        } else {
            rows = try context.fetch(FetchDescriptor<Workout>())
            setRows = try context.fetch(FetchDescriptor<StrengthSetRecord>())
        }
        // Sort the models' small identifiers, not full BLOB-bearing SQL rows.
        sessions = rows.sorted(using: SortDescriptor(\.id)).map {
            Session(id: $0.id, startTime: $0.startTime, duration: $0.duration, type: $0.workoutType,
                    distance: $0.distance, featuresData: $0.featuresData, tags: $0.userTags.sorted(),
                    source: $0.source, isGarmin: WorkoutAggregator.isGarminSource($0), linkedID: $0.linkedSessionID,
                    deleted: $0.isTombstoned, deletionOrigin: $0.deletionOrigin, suppressed: $0.isSuppressed)
        }
        sets = setRows.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            RecordedSet(sessionID: $0.sessionID,
                        input: StrengthSetInput(id: $0.id, exerciseID: $0.exerciseID, reps: $0.reps,
                                                weightKG: $0.weightKG, rir: $0.rir,
                                                effort: $0.effortRaw.flatMap(StrengthEffort.init(rawValue:)),
                                                manualRegions: $0.manualRegionsRaw.compactMap(Region.init(rawValue:))),
                        recordedAt: $0.recordedAt, updatedAt: $0.updatedAt)
        }
        let thresholds = try DataStore(modelContext: context).fetchUserThresholds()
        maxHeartRate = thresholds.cardioMaxHeartRate
        thresholdsModifiedAt = thresholds.lastModified
        previous = includePrevious ? try Self.latestEstimates(context: context, sessionIDs: sessionID.map { [$0] }) : [:]
    }

    @MainActor static func sourceGroup(context: ModelContext, sessionID: String) throws -> [Workout] {
        var rows = try context.fetch(FetchDescriptor(predicate: #Predicate<Workout> { $0.id == sessionID }))
        var seen = Set(rows.map(\.id))
        var frontier = Array(seen)
        while !frontier.isEmpty {
            let parents = frontier
            let children = try context.fetch(FetchDescriptor(predicate: #Predicate<Workout> { row in
                if let parent = row.linkedSessionID {
                    parents.contains(parent) && (!row.isTombstoned || row.deletionOrigin == "source")
                } else { false }
            }))
            frontier = []
            for child in children where seen.insert(child.id).inserted {
                rows.append(child)
                frontier.append(child.id)
            }
        }
        return rows
    }

    @MainActor static func latestEstimates(context: ModelContext, sessionIDs: [String]? = nil) throws -> [String: Previous] {
        var query = FetchDescriptor<LoadEstimateRecord>()
        if let sessionIDs { query.predicate = #Predicate { sessionIDs.contains($0.sessionID) } }
        // Old revisions can each contain an entire sensor stream. Select the
        // newest record using metadata before accessing its input payload.
        query.propertiesToFetch = [\.sessionID, \.computedAt]
        var latest: [String: LoadEstimateRecord] = [:]
        for row in try context.fetch(query) {
            if let current = latest[row.sessionID], current.computedAt >= row.computedAt { continue }
            latest[row.sessionID] = row
        }
        return latest.mapValues { Previous(version: $0.version, inputData: $0.inputData) }
    }

    func hasSameInputs(as other: Self) -> Bool {
        sessions == other.sessions && sets == other.sets && maxHeartRate == other.maxHeartRate
            && thresholdsModifiedAt == other.thresholdsModifiedAt
    }

    func calculate(now: Date, onlyMissing: Bool = false, sessionID: String? = nil) throws -> [Pending] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        func decodedFeatures(for session: Session) -> WorkoutFeatures {
            session.featuresData.flatMap { try? decoder.decode(WorkoutFeatures.self, from: $0) } ?? WorkoutFeatures()
        }
        // A single-session recalculation only needs runs that could fall within
        // that session's prior 28-day window. Filter before decoding payloads;
        // the full-history path keeps its original ordering and scope.
        let targetStart = sessionID.flatMap { id in
            sessions.first { $0.id == id && !$0.deleted && !$0.suppressed }?.startTime
        }
        let targetWindowStart = targetStart?.addingTimeInterval(-28 * 86400)
        let runningHistory = sessions.filter { candidate in
            guard !candidate.deleted, !candidate.suppressed, candidate.type.lowercased().contains("run") else { return false }
            guard sessionID != nil else { return true }
            guard let targetStart, let targetWindowStart else { return false }
            return candidate.startTime < targetStart && candidate.startTime >= targetWindowStart
        }.map {
            let end = $0.featuresData.flatMap { try? decoder.decode(SessionEndpoint.self, from: $0) }?.end
                ?? $0.startTime.addingTimeInterval($0.duration)
            return (start: $0.startTime, end: end, duration: $0.duration)
        }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        // Cutting a user-deleted link also excludes its descendants from the active group.
        let links = WorkoutLinkGraph(sessions.filter { !$0.deleted || $0.deletionOrigin == "source" }
            .map { .init(id: $0.id, parentID: $0.linkedID) })
        var result: [Pending] = []
        for session in sessions where !session.deleted && !session.suppressed && (sessionID == nil || session.id == sessionID) {
            try Task.checkCancellation()
            if onlyMissing, let old = previous[session.id], old.version == LoadModel.version,
               let saved = try? decoder.decode(SavedThresholds.self, from: old.inputData),
               saved.maxHeartRate == maxHeartRate && saved.thresholdsModifiedAt == thresholdsModifiedAt {
                continue
            }
            let ids = links.relatedIDs(to: session.id)
            let members = ids.compactMap { byID[$0] }
            let sources = members.filter { !$0.deleted }.sorted { $0.id < $1.id }
            var features = decodedFeatures(for: session)
            if sources.count > 1 {
                let inputs = sources.map { source in
                    WorkoutSignals.Source(id: source.id, isGarmin: source.isGarmin,
                                          features: source.id == session.id ? features : decodedFeatures(for: source))
                }
                let signals = WorkoutSignals(canonicalID: session.id, sources: inputs,
                    start: session.startTime, fallbackEnd: session.startTime.addingTimeInterval(session.duration))
                features.heartRate = signals.intervals(\.heartRate, validRange: 30...240)
                features.power = signals.intervals(\.power, validRange: 0...2500)
                features.cadence = signals.intervals(\.cadence, validRange: 0...250)
                features.speed = signals.intervals(\.speed, validRange: 0...15)
                features.elevation = signals.intervals(\.elevation, validRange: -500...9000)
                features.grade = signals.intervals(\.grade, validRange: -0.5...0.5)
                features.pauses = signals.pauses
                features.end = signals.recordedEnd
                features.ascentMeters = signals.sources.compactMap { $0.features.ascentMeters }.first
                features.descentMeters = signals.sources.compactMap { $0.features.descentMeters }.first
                let segments = signals.sources.map { $0.features.swimSegments }
                if signals.sources.first?.isGarmin == true {
                    features.swimSegments = segments.first { !$0.isEmpty } ?? []
                } else {
                    features.swimSegments = segments.max { $0.count < $1.count } ?? []
                }
                features.provenance = Array(Set(signals.sources.flatMap { $0.features.provenance })).sorted()
            }
            let recordedSets = sets.filter { ids.contains($0.sessionID) }
            let inputs = recordedSets.map(\.input)
            let groupTags = WorkoutTagProjection.merged(members.map(\.tags))
            let priorRuns = runningHistory.filter {
                $0.start < session.startTime && $0.start >= session.startTime.addingTimeInterval(-28 * 86400)
                    && $0.end <= session.startTime
            }
            let recentMinutes: Double? = priorRuns.isEmpty ? nil : priorRuns.reduce(0) { $0 + $1.duration / 60 }
            let snapshot = EstimateInput(type: session.type, start: session.startTime, duration: session.duration,
                                         distance: session.distance, features: features, sets: inputs, tags: groupTags,
                                         maxHeartRate: maxHeartRate, recentRunningMinutes: recentMinutes,
                                         setRevisions: recordedSets.map { SetRevision(id: $0.input.id, recordedAt: $0.recordedAt, updatedAt: $0.updatedAt) },
                                         thresholdsModifiedAt: thresholdsModifiedAt,
                                         sourceIDs: sources.map { "\($0.source):\($0.id)" }.sorted())
            let inputData = try encoder.encode(snapshot)
            if previous[session.id]?.inputData == inputData && previous[session.id]?.version == LoadModel.version { continue }
            let value = LoadModel.estimate(type: session.type, start: session.startTime, duration: session.duration,
                                           distance: session.distance, features: features, sets: inputs, tags: groupTags,
                                           maxHeartRate: maxHeartRate, now: now, recentRunningMinutes: recentMinutes)
            result.append(Pending(sessionID: session.id, value: value, inputData: inputData, payloadData: try encoder.encode(value)))
        }
        return result
    }
}

nonisolated private struct EstimateInput: Codable, Sendable {
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

nonisolated private struct SetRevision: Codable, Sendable {
    var id: UUID
    var recordedAt: Date
    var updatedAt: Date
}

nonisolated private struct SessionEndpoint: Decodable {
    var end: Date?
}

/// A threshold edit is saved before the history refresh. Reopen must finish an
/// interrupted refresh even when those old snapshots use the current model.
nonisolated private struct SavedThresholds: Decodable {
    var maxHeartRate: Int?
    var thresholdsModifiedAt: Date
}

/// Bound CPU and decoded-sample memory when launch, Sync and Settings overlap.
actor V2EstimateCalculator {
    static let shared = V2EstimateCalculator()

    func calculate(_ snapshot: V2EstimateBatch, now: Date, onlyMissing: Bool) throws -> [V2EstimateBatch.Pending] {
        try snapshot.calculate(now: now, onlyMissing: onlyMissing)
    }
}
