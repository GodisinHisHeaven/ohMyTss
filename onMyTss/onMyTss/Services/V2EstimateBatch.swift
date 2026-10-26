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
        let linkedID: String?
        let deleted: Bool
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
                    source: $0.source, linkedID: $0.linkedSessionID,
                    deleted: $0.isTombstoned, suppressed: $0.isSuppressed)
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
        func features(for session: Session) -> WorkoutFeatures {
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
        let children = Dictionary(grouping: sessions.filter { $0.linkedID != nil }, by: { $0.linkedID! })
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
            var features = features(for: session)
            let window = TimeRange(start: session.startTime, end: features.end ?? session.startTime.addingTimeInterval(session.duration))
            func supported(_ values: [TimedValue], pauses: [TimeRange], range: ClosedRange<Double>) -> Double {
                SignalProcessing.coveredSeconds(SignalProcessing.intervals(samples: values, window: window, pauses: pauses, validRange: range))
            }
            for source in sources where source.id != session.id {
                let other = source.featuresData.flatMap { try? decoder.decode(WorkoutFeatures.self, from: $0) } ?? WorkoutFeatures()
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
            let recordedSets = sets.filter { ids.contains($0.sessionID) }
            let inputs = recordedSets.map(\.input)
            let priorRuns = runningHistory.filter {
                $0.start < session.startTime && $0.start >= session.startTime.addingTimeInterval(-28 * 86400)
                    && $0.end <= session.startTime
            }
            let recentMinutes: Double? = priorRuns.isEmpty ? nil : priorRuns.reduce(0) { $0 + $1.duration / 60 }
            let snapshot = EstimateInput(type: session.type, start: session.startTime, duration: session.duration,
                                         distance: session.distance, features: features, sets: inputs, tags: session.tags,
                                         maxHeartRate: maxHeartRate, recentRunningMinutes: recentMinutes,
                                         setRevisions: recordedSets.map { SetRevision(id: $0.input.id, recordedAt: $0.recordedAt, updatedAt: $0.updatedAt) },
                                         thresholdsModifiedAt: thresholdsModifiedAt,
                                         sourceIDs: sources.map { "\($0.source):\($0.id)" }.sorted())
            let inputData = try encoder.encode(snapshot)
            if previous[session.id]?.inputData == inputData && previous[session.id]?.version == LoadModel.version { continue }
            let value = LoadModel.estimate(type: session.type, start: session.startTime, duration: session.duration,
                                           distance: session.distance, features: features, sets: inputs, tags: session.tags,
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
