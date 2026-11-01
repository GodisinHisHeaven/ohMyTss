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
        try await decode(inputs, decodeEnd: {
            (try? JSONDecoder().decode(WorkoutFeatures.self, from: $0))?.end
        })
    }

    static func decode(_ inputs: [WorkoutEndpointPayload],
                       decodeEnd: @escaping @Sendable (Data) -> Date?) async throws -> [PrewarmedWorkoutEndpoint] {
        let worker = Task.detached(priority: .utility) { () throws -> [PrewarmedWorkoutEndpoint] in
            try decodeBatch(inputs, decodeEnd: decodeEnd)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Reuse only the immediately preceding complete decode of the same ID
    /// and bytes. Keep each entry's independent proof and output order.
    static func decodeBatch(
        _ inputs: [WorkoutEndpointPayload],
        decodeEnd: (Data) -> Date?
    ) throws -> [PrewarmedWorkoutEndpoint] {
        var result: [PrewarmedWorkoutEndpoint] = []
        var previous: (id: String, data: Data?, end: Date?)?
        for input in inputs {
            try Task.checkCancellation()
            let end: Date?
            if let previous, previous.id == input.id, previous.data == input.data {
                end = previous.end
            } else {
                // Decode all channels: an unrelated corrupt channel still
                // makes the endpoint unreadable, just as Workout.features.
                end = input.data.flatMap(decodeEnd)
            }
            previous = (input.id, input.data, end)
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
}
