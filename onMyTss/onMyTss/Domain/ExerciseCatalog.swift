import Foundation

/// A small participation catalog, not a biomechanical force model.
nonisolated enum ExerciseCatalog {
    static let exercises: [ExerciseDefinition] = [
        .init(id: "squat", name: "Squat", regions: [.quads, .glutes, .core]),
        .init(id: "goblet_squat", name: "Goblet squat", regions: [.quads, .glutes, .core]),
        .init(id: "leg_press", name: "Leg press", regions: [.quads, .glutes]),
        .init(id: "lunge", name: "Lunge", regions: [.quads, .glutes]),
        .init(id: "split_squat", name: "Split squat", regions: [.quads, .glutes]),
        .init(id: "step_up", name: "Step-up", regions: [.quads, .glutes]),
        .init(id: "deadlift", name: "Deadlift", regions: [.glutes, .hamstrings, .back, .core]),
        .init(id: "romanian_deadlift", name: "Romanian deadlift", regions: [.hamstrings, .glutes, .back]),
        .init(id: "hip_thrust", name: "Hip thrust", regions: [.glutes, .hamstrings]),
        .init(id: "leg_curl", name: "Leg curl", regions: [.hamstrings]),
        .init(id: "leg_extension", name: "Leg extension", regions: [.quads]),
        .init(id: "calf_raise", name: "Calf raise", regions: [.calves]),
        .init(id: "bench_press", name: "Bench press", regions: [.chest, .arms, .shoulders]),
        .init(id: "push_up", name: "Push-up", regions: [.chest, .arms, .shoulders, .core]),
        .init(id: "overhead_press", name: "Overhead press", regions: [.shoulders, .arms]),
        .init(id: "lateral_raise", name: "Lateral raise", regions: [.shoulders]),
        .init(id: "dip", name: "Dip", regions: [.chest, .arms]),
        .init(id: "row", name: "Row", regions: [.back, .arms]),
        .init(id: "pull_up", name: "Pull-up", regions: [.back, .arms]),
        .init(id: "lat_pulldown", name: "Lat pulldown", regions: [.back, .arms]),
        .init(id: "face_pull", name: "Face pull", regions: [.shoulders, .back]),
        .init(id: "biceps_curl", name: "Biceps curl", regions: [.arms]),
        .init(id: "triceps_extension", name: "Triceps extension", regions: [.arms]),
        .init(id: "crunch", name: "Crunch", regions: [.core]),
        .init(id: "dead_bug", name: "Dead bug", regions: [.core]),
        .init(id: "hanging_knee_raise", name: "Hanging knee raise", regions: [.core])
    ]

    static func exercise(id: String) -> ExerciseDefinition? {
        exercises.first { $0.id == id }
    }
}
