import Foundation

/// Keeps source-owned labels untouched; conflicting single-choice labels
/// become unknown for the current grouped calculation rather than guessing.
nonisolated enum WorkoutTagProjection {
    static func merged(_ groups: [[String]]) -> [String] {
        var result = Set(groups.flatMap { $0 })
        for options in [Set(["seated", "standing"]),
                        Set(["freestyle", "backstroke", "breaststroke", "butterfly"])] {
            if result.intersection(options).count > 1 { result.subtract(options) }
        }
        return result.sorted()
    }
}
