import Foundation

/// Immutable source fields needed to plan reconciliation. Managed objects and
/// their contexts never leave the main actor.
nonisolated struct WorkoutSourceMatchInput: Equatable, Sendable {
    let id: String
    let date: Date
    let start: Date
    let duration: Double
    let type: String
    let source: String
    let sourceBundleIdentifier: String?
    let deviceManufacturer: String?
    let deviceName: String?
    let featuresData: Data?
    let deletionOrigin: String?
    let groupID: String?
    let linkedID: String?
    let isTombstoned: Bool
    let isSuppressed: Bool
    let userTags: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Stable comparison matters for corrupt historic non-finite values:
        // NaN is not equal to itself, but its stored bits can be unchanged.
        lhs.id == rhs.id && lhs.date.timeIntervalSinceReferenceDate.bitPattern == rhs.date.timeIntervalSinceReferenceDate.bitPattern &&
            lhs.start.timeIntervalSinceReferenceDate.bitPattern == rhs.start.timeIntervalSinceReferenceDate.bitPattern &&
            lhs.duration.bitPattern == rhs.duration.bitPattern && lhs.type == rhs.type && lhs.source == rhs.source &&
            lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier && lhs.deviceManufacturer == rhs.deviceManufacturer &&
            lhs.deviceName == rhs.deviceName && lhs.featuresData == rhs.featuresData &&
            lhs.deletionOrigin == rhs.deletionOrigin && lhs.groupID == rhs.groupID && lhs.linkedID == rhs.linkedID &&
            lhs.isTombstoned == rhs.isTombstoned && lhs.isSuppressed == rhs.isSuppressed && lhs.userTags == rhs.userTags
    }
}

/// Pure reconciliation planning, suitable for a detached, cancellable task.
/// Input order is preserved so callers can validate the exact snapshot before
/// applying a plan to their own context.
nonisolated enum WorkoutSourceMatching {
    private struct Endpoint { let value: Date? }

    static func detachedPlan(_ inputs: [WorkoutSourceMatchInput]) async throws -> [String: String] {
        let task = Task.detached(priority: .userInitiated) { try plan(inputs) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func normalizeType(_ type: String) -> String {
        let lowercased = type.lowercased()
        if lowercased.contains("cycl") || lowercased.contains("bike") || lowercased.contains("ride") {
            return "cycling"
        } else if lowercased.contains("run") {
            return "running"
        } else if lowercased.contains("swim") {
            return "swimming"
        } else if lowercased.contains("strength") || lowercased.contains("weighttraining") {
            return "strength"
        } else if lowercased.contains("walk") {
            return "walking"
        } else if lowercased == "hike" || lowercased == "hiking" {
            return "hiking"
        }
        return lowercased
    }

    /// Return the selected group ID for each external source row, including
    /// still-matching source-deleted aliases from previous groups.
    static func plan(_ inputs: [WorkoutSourceMatchInput]) throws -> [String: String] {
        try Task.checkCancellation()
        let external = inputs.indices.filter { inputs[$0].source != "manual" }
        let types = inputs.map { normalizeType($0.type) }
        var endpoints: [Int: Endpoint] = [:]
        var operations = 0
        func checkCancellation() throws {
            operations += 1
            if operations.isMultiple(of: 64) { try Task.checkCancellation() }
        }
        func endpoint(_ index: Int) -> Date? {
            if let cached = endpoints[index] { return cached.value }
            // Keep the original full-payload decoding behavior: invalid sensor
            // data invalidates its endpoint and uses the duration fallback.
            let value = inputs[index].featuresData.flatMap {
                (try? JSONDecoder().decode(WorkoutFeatures.self, from: $0))?.end
            }
            endpoints[index] = Endpoint(value: value)
            return value
        }
        func possible(_ first: Int, _ second: Int) throws -> Bool {
            try checkCancellation()
            let a = inputs[first], b = inputs[second]
            let firstType = types[first], secondType = types[second]
            let compatible: Bool
            if firstType == secondType { compatible = !firstType.isEmpty }
            else {
                compatible = (a.source == "healthKit" && firstType == "other") ||
                    (b.source == "healthKit" && secondType == "other")
            }
            guard compatible, abs(a.start.timeIntervalSince(b.start)) < 60,
                  a.duration.isFinite, b.duration.isFinite, a.duration > 0, b.duration > 0 else { return false }
            if let firstEnd = endpoint(first), let secondEnd = endpoint(second) {
                let firstElapsed = firstEnd.timeIntervalSince(a.start)
                let secondElapsed = secondEnd.timeIntervalSince(b.start)
                return firstElapsed.isFinite && secondElapsed.isFinite && firstElapsed > 0 && secondElapsed > 0
                    && abs(firstEnd.timeIntervalSince(secondEnd)) < 5
            }
            return abs(a.duration - b.duration) < 5
        }
        func definite(_ first: Int, _ second: Int) throws -> Bool {
            guard try possible(first, second) else { return false }
            let a = inputs[first], b = inputs[second], type = types[first]
            guard type != "other", type == types[second] else { return false }
            if (a.source == "healthKit" && b.source == "strava") ||
                (a.source == "strava" && b.source == "healthKit") { return true }
            guard a.source == "healthKit", b.source == "healthKit",
                  let firstBundle = a.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let secondBundle = b.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !firstBundle.isEmpty, !secondBundle.isEmpty else { return false }
            return firstBundle != secondBundle
        }

        let active = external.filter { inputs[$0].deletionOrigin != "source" }.sorted {
            if inputs[$0].start != inputs[$1].start { return inputs[$0].start < inputs[$1].start }
            return inputs[$0].id < inputs[$1].id
        }
        var neighbors = Array(repeating: [Int](), count: inputs.count)
        for position in active.indices {
            try checkCancellation()
            let first = active[position]
            var other = position + 1
            while other < active.count && inputs[active[other]].start.timeIntervalSince(inputs[first].start) < 60 {
                let second = active[other]
                if try possible(first, second) {
                    neighbors[first].append(second)
                    neighbors[second].append(first)
                }
                other += 1
            }
        }
        var groupForID = Dictionary(uniqueKeysWithValues: external.map { (inputs[$0].id, inputs[$0].id) })
        var visited = Set<Int>()
        for index in active where visited.insert(index).inserted {
            try checkCancellation()
            var pending = [index], members: [Int] = []
            while let current = pending.popLast() {
                try checkCancellation()
                members.append(current)
                for neighbor in neighbors[current] where visited.insert(neighbor).inserted { pending.append(neighbor) }
            }
            var complete = true
            for left in members.indices {
                for right in members.indices where right > left {
                    if try !definite(members[left], members[right]) { complete = false }
                }
            }
            if complete, let group = members.map({ inputs[$0].id }).min() {
                for member in members { groupForID[inputs[member].id] = group }
            }
        }
        let previousGroups = Dictionary(grouping: external.filter { inputs[$0].groupID != nil }) { inputs[$0].groupID! }
        for index in external where inputs[index].deletionOrigin == "source" {
            try checkCancellation()
            guard let oldGroup = inputs[index].groupID else { continue }
            var survivorGroups = Set<String>()
            for candidate in previousGroups[oldGroup] ?? [] where candidate != index {
                guard inputs[candidate].deletionOrigin != "source", inputs[candidate].groupID == oldGroup,
                      try definite(index, candidate) else { continue }
                if let group = groupForID[inputs[candidate].id] { survivorGroups.insert(group) }
            }
            if survivorGroups.count == 1, let group = survivorGroups.first { groupForID[inputs[index].id] = group }
        }
        try Task.checkCancellation()
        return groupForID
    }
}
