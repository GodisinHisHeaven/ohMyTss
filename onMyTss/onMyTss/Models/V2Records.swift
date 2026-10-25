import Foundation
import SwiftData

/// User observations are independent of modeled load; no row means not reported.
@Model
final class LocalObservation {
    @Attribute(.unique) var id: UUID
    var observedAt: Date
    var recordedAt: Date
    var updatedAt: Date
    var regionRaw: String
    var sideRaw: String
    var discomfortRaw: String
    var severity: Int?
    var weakness: Bool
    var tightness: Bool
    var limitedMovement: Bool
    var note: String
    var sessionID: String?

    init(regionRaw: String, sideRaw: String = "both", discomfortRaw: String = "soreness",
         severity: Int? = nil, observedAt: Date = Date(), sessionID: String? = nil) {
        self.id = UUID()
        self.regionRaw = regionRaw
        self.sideRaw = sideRaw
        self.discomfortRaw = discomfortRaw
        self.severity = severity
        self.observedAt = observedAt
        self.recordedAt = Date()
        self.updatedAt = recordedAt
        self.weakness = false
        self.tightness = false
        self.limitedMovement = false
        self.note = ""
        self.sessionID = sessionID
    }
}

@Model
final class StrengthSetRecord {
    @Attribute(.unique) var id: UUID
    var sessionID: String
    var exerciseID: String
    var reps: Int
    var weightKG: Double?
    var rir: Int?
    var effortRaw: String?
    var manualRegionsRaw: [String]
    var recordedAt: Date
    var updatedAt: Date

    init(sessionID: String, exerciseID: String, reps: Int, weightKG: Double? = nil,
         rir: Int? = nil, effortRaw: String? = nil, manualRegionsRaw: [String] = []) {
        self.id = UUID()
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.reps = reps
        self.weightKG = weightKG
        self.rir = rir
        self.effortRaw = effortRaw
        self.manualRegionsRaw = manualRegionsRaw
        self.recordedAt = Date()
        self.updatedAt = recordedAt
    }
}

@Model
final class StrengthTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var setsData: Data
    init(name: String, setsData: Data) {
        self.id = UUID()
        self.name = name
        self.setsData = setsData
    }
}

/// Append-only estimates retain the exact input snapshot for future time-ordered evaluation.
@Model
final class LoadEstimateRecord {
    @Attribute(.unique) var id: UUID
    var sessionID: String
    var version: String
    var inputCutoff: Date
    var computedAt: Date
    var payloadData: Data
    var inputData: Data

    init(sessionID: String, version: String, inputCutoff: Date, computedAt: Date,
         payloadData: Data, inputData: Data) {
        self.id = UUID()
        self.sessionID = sessionID
        self.version = version
        self.inputCutoff = inputCutoff
        self.computedAt = computedAt
        self.payloadData = payloadData
        self.inputData = inputData
    }

    var value: LoadEstimateValue? { try? JSONDecoder().decode(LoadEstimateValue.self, from: payloadData) }
}

extension Workout {
    var features: WorkoutFeatures {
        get {
            guard let data = featuresData else { return WorkoutFeatures() }
            return (try? JSONDecoder().decode(WorkoutFeatures.self, from: data)) ?? WorkoutFeatures()
        }
        set { featuresData = try? JSONEncoder().encode(newValue) }
    }
}

/// One schema list for production and v2 persistence tests; original entity names remain unchanged.
enum AppSchema {
    static var models: [any PersistentModel.Type] {
        [DayAggregate.self, UserThresholds.self, AppState.self, Workout.self, StravaAuth.self,
         LocalObservation.self, StrengthSetRecord.self, StrengthTemplate.self, LoadEstimateRecord.self]
    }
}
