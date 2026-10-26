import Foundation

/// Display bands for a reported 1–10 effort, not a recovery percentage.
nonisolated enum MuscleEffortGrade: Int, CaseIterable, Identifiable, Sendable {
    case easy, moderate, hard, veryHard
    var id: Int { rawValue }

    init?(rpe: Int) {
        switch rpe {
        case 1...3: self = .easy
        case 4...6: self = .moderate
        case 7...8: self = .hard
        case 9...10: self = .veryHard
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .veryHard: return "Very hard"
        }
    }

    var rangeLabel: String {
        switch self {
        case .easy: return "1–3"
        case .moderate: return "4–6"
        case .hard: return "7–8"
        case .veryHard: return "9–10"
        }
    }

    var defaultRPE: Int {
        switch self {
        case .easy: return 2
        case .moderate: return 5
        case .hard: return 8
        case .veryHard: return 9
        }
    }
}

nonisolated enum WorkoutCategory: String, Sendable {
    case running = "Running", cycling = "Cycling", swimming = "Swimming"
    case strength = "Strength", walking = "Walking", other = "Workout"

    init(type: String) {
        let value = type.lowercased()
        if value.contains("run") { self = .running }
        else if value.contains("ride") || value.contains("cycl") { self = .cycling }
        else if value.contains("swim") { self = .swimming }
        else if value.contains("strength") || value.contains("weight") || value.contains("resistance") { self = .strength }
        else if value.contains("walk") || value.contains("hik") { self = .walking }
        else { self = .other }
    }

    var icon: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .strength: return "dumbbell"
        case .walking: return "figure.walk"
        case .other: return "figure.mixed.cardio"
        }
    }
}
