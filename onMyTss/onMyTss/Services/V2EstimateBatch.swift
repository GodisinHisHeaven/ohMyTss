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

    @MainActor init(context: ModelContext, includePrevious: Bool = true) throws {
        sessions = try context.fetch(FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.id)])).map {
            Session(id: $0.id, startTime: $0.startTime, duration: $0.duration, type: $0.workoutType,
                    distance: $0.distance, featuresData: $0.featuresData, tags: $0.userTags.sorted(),
                    source: $0.source, isGarmin: WorkoutAggregator.isGarminSource($0), linkedID: $0.linkedSessionID,
                    deleted: $0.isTombstoned, deletionOrigin: $0.deletionOrigin, suppressed: $0.isSuppressed)
        }
        sets = try context.fetch(FetchDescriptor<StrengthSetRecord>()).sorted { $0.id.uuidString < $1.id.uuidString }.map {
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
        previous = includePrevious ? try Self.latestEstimates(context: context) : [:]
    }

    @MainActor static func latestEstimates(context: ModelContext, sessionIDs: [String]? = nil) throws -> [String: Previous] {
        var query = FetchDescriptor<LoadEstimateRecord>(sortBy: [SortDescriptor(\.computedAt, order: .reverse)])
        if let sessionIDs { query.predicate = #Predicate { sessionIDs.contains($0.sessionID) } }
        var latest: [String: Previous] = [:]
        for row in try context.fetch(query)
            where latest[row.sessionID] == nil {
            latest[row.sessionID] = Previous(version: row.version, inputData: row.inputData)
        }
        return latest
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
        // Retain only run endpoints for prior-exposure lookup, not every decoded
        // HR/power sample in the entire history at once.
        let runningHistory = sessions.filter { !$0.deleted && !$0.suppressed && $0.type.lowercased().contains("run") }.map {
            let end = $0.featuresData.flatMap { try? decoder.decode(SessionEndpoint.self, from: $0) }?.end
                ?? $0.startTime.addingTimeInterval($0.duration)
            return (start: $0.startTime, end: end, duration: $0.duration)
        }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        // A user-deleted node and its descendants must not contribute to an active group.
        let children = Dictionary(grouping: sessions.filter { $0.linkedID != nil && !($0.deleted && $0.deletionOrigin != "source") }, by: { $0.linkedID! })
        var result: [Pending] = []
        for session in sessions where !session.deleted && !session.suppressed && (sessionID == nil || session.id == sessionID) {
            try Task.checkCancellation()
            if onlyMissing, let old = previous[session.id], old.version == LoadModel.version,
               let saved = try? decoder.decode(SavedThresholds.self, from: old.inputData),
               saved.maxHeartRate == maxHeartRate && saved.thresholdsModifiedAt == thresholdsModifiedAt {
                continue
            }
            var ids: Set<String> = [session.id]
            var pendingIDs = [session.id]
            while let id = pendingIDs.popLast() {
                for child in children[id] ?? [] where ids.insert(child.id).inserted { pendingIDs.append(child.id) }
            }
            let sources = ids.compactMap { byID[$0] }.filter { !$0.deleted }.sorted { $0.id < $1.id }
            var features = decodedFeatures(for: session)
            let window = TimeRange(start: session.startTime, end: features.end ?? session.startTime.addingTimeInterval(session.duration))
            func supported(_ values: [TimedValue], pauses: [TimeRange], range: ClosedRange<Double>) -> Double {
                SignalProcessing.coveredSeconds(SignalProcessing.intervals(samples: values, window: window, pauses: pauses, validRange: range))
            }
            if sources.count > 1 && sources.contains(where: \.isGarmin) {
                // Materialize each source's valid support using its own pauses.
                // Garmin samples win overlaps; other sources fill only gaps.
                let inputs = sources.map { ($0, $0.id == session.id ? features : decodedFeatures(for: $0)) }
                let primaryPauses = session.isGarmin ? features.pauses
                    : inputs.first(where: { $0.0.isGarmin })?.1.pauses ?? features.pauses
                func fillGaps(_ selected: [TimedValue], with additions: [TimedValue]) -> [TimedValue] {
                    var uncovered: [TimedValue] = []
                    var firstPossible = 0
                    for sample in additions {
                        while firstPossible < selected.count && selected[firstPossible].end <= sample.start { firstPossible += 1 }
                        var cursor = sample.start
                        var index = firstPossible
                        while index < selected.count && selected[index].start < sample.end {
                            let existing = selected[index]
                            if existing.start > cursor {
                                uncovered.append(TimedValue(start: cursor, end: min(existing.start, sample.end), value: sample.value))
                            }
                            cursor = max(cursor, existing.end)
                            if cursor >= sample.end { break }
                            index += 1
                        }
                        if cursor < sample.end { uncovered.append(TimedValue(start: cursor, end: sample.end, value: sample.value)) }
                    }
                    return (selected + uncovered).sorted { $0.start < $1.start }
                }
                func merged(_ key: KeyPath<WorkoutFeatures, [TimedValue]>, range: ClosedRange<Double>) -> [TimedValue] {
                    let candidates = inputs.map { source, value in
                        let intervals = SignalProcessing.intervals(samples: value[keyPath: key], window: window,
                                                                   pauses: value.pauses + primaryPauses, validRange: range)
                        return (source, intervals, SignalProcessing.coveredSeconds(intervals))
                    }.filter { !$0.1.isEmpty }.sorted {
                        if $0.0.isGarmin != $1.0.isGarmin { return $0.0.isGarmin }
                        if $0.0.isGarmin && ($0.0.id == session.id) != ($1.0.id == session.id) { return $0.0.id == session.id }
                        return $0.2 == $1.2 ? $0.0.id < $1.0.id : $0.2 > $1.2
                    }
                    guard let first = candidates.first else { return [] }
                    // Without any usable Garmin intervals retain the existing
                    // highest-coverage fallback, rather than combining sources.
                    guard first.0.isGarmin else { return first.1 }
                    return candidates.dropFirst().reduce(first.1) { fillGaps($0, with: $1.1) }
                }
                features.heartRate = merged(\.heartRate, range: 30...240)
                features.power = merged(\.power, range: 0...2500)
                features.cadence = merged(\.cadence, range: 0...250)
                features.speed = merged(\.speed, range: 0...15)
                features.elevation = merged(\.elevation, range: -500...9000)
                features.grade = merged(\.grade, range: -0.5...0.5)
                // The canonical Garmin timeline controls overall activity pauses;
                // a different source's pauses must not erase Garmin measurements.
                features.pauses = primaryPauses
                let ranked = inputs.sorted {
                    if $0.0.isGarmin != $1.0.isGarmin { return $0.0.isGarmin }
                    if ($0.0.id == session.id) != ($1.0.id == session.id) { return $0.0.id == session.id }
                    return $0.0.id < $1.0.id
                }
                features.ascentMeters = ranked.compactMap { $0.1.ascentMeters }.first
                features.descentMeters = ranked.compactMap { $0.1.descentMeters }.first
                features.swimSegments = ranked.first { !$0.1.swimSegments.isEmpty }?.1.swimSegments ?? []
                for (source, other) in inputs where source.id != session.id {
                    if features.end == nil { features.end = other.end }
                    features.provenance = Array(Set(features.provenance + other.provenance)).sorted()
                }
            } else {
                // Preserve the existing highest-coverage rule for non-Garmin groups.
                // Single-source sessions skip coverage comparisons entirely.
                for source in sources where source.id != session.id {
                    let other = decodedFeatures(for: source)
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
            }
            let recordedSets = sets.filter { ids.contains($0.sessionID) }
            let inputs = recordedSets.map(\.input)
            // Read attached labels through the current logical group without
            // migrating them. A later source correction can split that group.
            let tagSources = ids.compactMap { byID[$0] }.filter { !$0.deleted || $0.deletionOrigin == "source" }
            let groupTags = WorkoutTagProjection.merged(tagSources.map(\.tags))
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
