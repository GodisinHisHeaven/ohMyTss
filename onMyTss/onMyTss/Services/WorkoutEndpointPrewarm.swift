import Foundation
import CryptoKit

/// Prewarming is only a performance hint. A missed or stale hint always uses
/// the existing synchronous decoder during reconciliation.
nonisolated struct WorkoutEndpointCandidate: Sendable {
    let id: String
    let start: Date
    let duration: Double
    let type: String
    let source: String
}

nonisolated struct WorkoutEndpointPayload: Sendable {
    let id: String
    let data: Data?
    let retainRaw: Bool

    init(id: String, data: Data?, retainRaw: Bool = true) {
        self.id = id
        self.data = data
        self.retainRaw = retainRaw
    }
}

/// A digest is a bounded performance hint, not byte-for-byte proof. It is
/// never used by reconciliation components containing a user deletion.
nonisolated enum WorkoutEndpointProof: Sendable {
    case exact(Data?)
    case digest(byteCount: Int, sha256: Data)
}

nonisolated struct PrewarmedWorkoutEndpoint: Sendable {
    let id: String
    let proof: WorkoutEndpointProof
    let end: Date?
}

nonisolated enum WorkoutEndpointPrewarmer {
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// This deliberately selects a superset of definite matches: ambiguous
    /// candidates must remain available to prevent erroneous merges.
    static func candidateIDs(_ inputs: [WorkoutEndpointCandidate]) async throws -> [String] {
        let worker = Task.detached(priority: .utility) { () throws -> [String] in
            let rows = inputs.filter { $0.source != "manual" }.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
            let types = rows.map { WorkoutSourceMatching.normalizeType($0.type) }
            var result = Set<String>()
            for index in rows.indices {
                try Task.checkCancellation()
                var other = index + 1
                while other < rows.count && rows[other].start.timeIntervalSince(rows[index].start) < 60 {
                    try Task.checkCancellation()
                    let first = rows[index], second = rows[other]
                    let a = types[index], b = types[other]
                    let compatible: Bool
                    if a == b { compatible = !a.isEmpty }
                    else {
                        compatible = (first.source == "healthKit" && a == "other") ||
                            (second.source == "healthKit" && b == "other")
                    }
                    if compatible, abs(first.start.timeIntervalSince(second.start)) < 60,
                       first.duration.isFinite, second.duration.isFinite,
                       first.duration > 0, second.duration > 0 {
                        result.insert(first.id)
                        result.insert(second.id)
                    }
                    other += 1
                }
            }
            return result.sorted()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func decode(_ inputs: [WorkoutEndpointPayload]) async throws -> [PrewarmedWorkoutEndpoint] {
        let worker = Task.detached(priority: .utility) { () throws -> [PrewarmedWorkoutEndpoint] in
            var result: [PrewarmedWorkoutEndpoint] = []
            for input in inputs {
                try Task.checkCancellation()
                // Decode the whole payload exactly as Workout.features does;
                // malformed unrelated sensor channels still yield nil.
                let end = input.data.flatMap { (try? JSONDecoder().decode(WorkoutFeatures.self, from: $0))?.end }
                let proof: WorkoutEndpointProof
                if !input.retainRaw, let data = input.data {
                    proof = .digest(byteCount: data.count, sha256: digest(data))
                } else {
                    proof = .exact(input.data)
                }
                result.append(PrewarmedWorkoutEndpoint(id: input.id, proof: proof, end: end))
            }
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
