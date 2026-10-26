import Foundation

nonisolated struct TimeRange: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var duration: Double { max(0, end.timeIntervalSince(start)) }
}

/// A measured interval, or a timestamped observation when start == end.
nonisolated struct TimedValue: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var value: Double
    var duration: Double { max(0, end.timeIntervalSince(start)) }
}

nonisolated struct SwimSegment: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    /// Raw source stroke name; unknown remains unknown.
    var stroke: String
}

nonisolated struct WorkoutFeatures: Codable, Equatable, Sendable {
    var heartRate: [TimedValue] = [] // beats/minute
    var power: [TimedValue] = [] // watts
    var cadence: [TimedValue] = [] // crank revolutions/minute
    var speed: [TimedValue] = [] // metres/second
    var swimSegments: [SwimSegment] = []
    var pauses: [TimeRange] = []
    var provenance: [String] = []
    var unavailableChannels: [String] = []
    var failedChannels: [String] = []
    var grade: [TimedValue] = [] // rise/run from quality-filtered route points
    var elevation: [TimedValue] = [] // metres, paired route observations; optional
    var ascentMeters: Double? = nil
    var descentMeters: Double? = nil
    /// External elapsed endpoint preserves wall-clock gaps when duration is moving time.
    var end: Date? = nil
}

nonisolated enum Region: String, Codable, CaseIterable, Identifiable, Sendable {
    case quads, hamstrings, glutes, calves, shoulders, chest, back, arms, core
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quads: return "Front thighs"
        case .hamstrings: return "Back thighs"
        case .glutes: return "Glutes"
        case .calves: return "Calves"
        case .shoulders: return "Shoulders"
        case .chest: return "Chest"
        case .back: return "Back"
        case .arms: return "Arms"
        case .core: return "Core"
        }
    }
}

nonisolated enum StrengthEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy, moderate, hard
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated struct StrengthSetInput: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var exerciseID: String
    var reps: Int
    var weightKG: Double?
    var rir: Int?
    var effort: StrengthEffort? = nil
    var manualRegions: [Region] = []
}

nonisolated struct ExerciseDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    /// Participation categories, never activation percentages or force shares.
    let regions: [Region]
}

nonisolated struct CardioEstimate: Codable, Equatable, Sendable {
    var points: Double
    var level: String
    var coverage: Double
    var method: String
    var reasons: [String]
}

nonisolated struct RegionalEstimate: Codable, Equatable, Identifiable, Sendable {
    var region: Region
    var level: String
    var exposure: Double
    var unit: String
    var method: String
    var coverage: Double
    var reasons: [String]
    var id: String { "\(region.rawValue):\(method):\(unit)" }
}

nonisolated struct LoadEstimateValue: Codable, Equatable, Sendable {
    var version: String
    var method: String
    var inputCutoff: Date
    var computedAt: Date
    var cardio: CardioEstimate?
    var regions: [RegionalEstimate]
    var coverage: Double
    var reasons: [String]
}

/// Values are retained as observations, independent of model estimates.
nonisolated enum BodySide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, both, unspecified
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum DiscomfortKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case soreness, sharpPain, jointPain, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .soreness: return "Soreness"
        case .sharpPain: return "Sharp pain"
        case .jointPain: return "Joint pain"
        case .other: return "Other discomfort"
        }
    }
}
