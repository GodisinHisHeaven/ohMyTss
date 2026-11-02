import Foundation

/// Immutable source fields needed to plan reconciliation. Managed objects and
/// their contexts never leave the main actor.
nonisolated struct WorkoutSourceMatchInput: Equatable, Sendable {
    let id: String
    let date: Date
    let start: Date
    let duration: Double
    let distance: Double?
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
            lhs.duration.bitPattern == rhs.duration.bitPattern && lhs.distance?.bitPattern == rhs.distance?.bitPattern &&
            lhs.type == rhs.type && lhs.source == rhs.source &&
            lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier && lhs.deviceManufacturer == rhs.deviceManufacturer &&
            lhs.deviceName == rhs.deviceName && lhs.featuresData == rhs.featuresData &&
            lhs.deletionOrigin == rhs.deletionOrigin && lhs.groupID == rhs.groupID && lhs.linkedID == rhs.linkedID &&
            lhs.isTombstoned == rhs.isTombstoned && lhs.isSuppressed == rhs.isSuppressed && lhs.userTags == rhs.userTags
    }
}

/// Scalar evidence shared by live reconciliation and offline history repair.
nonisolated struct WorkoutPausedTimingEvidence {
    let start: Date
    let duration: Double
    let distance: Double?
    let end: Date?
    let type: String
    let source: String
    let isGarmin: Bool
    let isStravaHealth: Bool
    let isDeleted: Bool
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

    /// This is deliberately broader than a definite match so a nearby
    /// competing record can block an otherwise ambiguous association.
    static func plausiblePausedTiming(_ first: WorkoutPausedTimingEvidence,
                                      _ second: WorkoutPausedTimingEvidence) -> Bool {
        guard abs(first.start.timeIntervalSince(second.start)) < 2,
              first.duration.isFinite, second.duration.isFinite,
              first.duration > 0, second.duration > 0 else { return false }
        for evidence in [first, second] {
            if let end = evidence.end {
                let elapsed = end.timeIntervalSince(evidence.start)
                guard elapsed.isFinite, elapsed > 0 else { return false }
            }
        }
        let durationTolerance = min(30, max(10, max(first.duration, second.duration) * 0.002))
        guard abs(first.duration - second.duration) <= durationTolerance else { return false }
        guard let firstDistance = first.distance, let secondDistance = second.distance,
              firstDistance.isFinite, secondDistance.isFinite,
              firstDistance > 0, secondDistance > 0 else { return true }
        return abs(firstDistance - secondDistance) <= max(firstDistance, secondDistance) * 0.002
    }

    /// Garmin Connect can save moving time as the end of a cycling workout,
    /// while Strava saves an elapsed end that includes pauses. Require several
    /// independent fields and leave deleted records out of this fallback.
    static func pausedGarminStravaMatch(_ first: WorkoutPausedTimingEvidence,
                                        _ second: WorkoutPausedTimingEvidence) -> Bool {
        guard plausiblePausedTiming(first, second), !first.isDeleted, !second.isDeleted,
              first.type == "cycling", second.type == "cycling",
              let firstDistance = first.distance, let secondDistance = second.distance,
              firstDistance.isFinite, secondDistance.isFinite,
              firstDistance >= 1_000, secondDistance >= 1_000 else { return false }
        let health: WorkoutPausedTimingEvidence
        let strava: WorkoutPausedTimingEvidence
        if first.source == "healthKit" && second.source == "strava" {
            health = first; strava = second
        } else if second.source == "healthKit" && first.source == "strava" {
            health = second; strava = first
        } else { return false }
        guard health.isGarmin, let healthEnd = health.end, let stravaEnd = strava.end else { return false }
        let healthElapsed = healthEnd.timeIntervalSince(health.start)
        let stravaElapsed = stravaEnd.timeIntervalSince(strava.start)
        let pause = stravaElapsed - strava.duration
        return abs(healthElapsed - health.duration) <= 2 && pause >= 60 &&
            pause <= min(7_200, health.duration * 0.5)
    }

    /// Strava can also write the same activity to HealthKit. Its elapsed
    /// duration differs from Garmin's moving-duration record, so pairwise
    /// matching alone cannot form a complete three-source group.
    static func pausedGarminStravaTriad(_ members: [WorkoutPausedTimingEvidence]) -> Bool {
        guard members.count == 3, members.allSatisfy({ !$0.isDeleted && $0.type == "cycling" }),
              let garmin = members.first(where: { $0.source == "healthKit" && $0.isGarmin && !$0.isStravaHealth }),
              let strava = members.first(where: { $0.source == "strava" }),
              let mirror = members.first(where: { $0.source == "healthKit" && $0.isStravaHealth }),
              pausedGarminStravaMatch(garmin, strava),
              abs(mirror.start.timeIntervalSince(strava.start)) < 2,
              let mirrorEnd = mirror.end, let stravaEnd = strava.end,
              abs(mirrorEnd.timeIntervalSince(stravaEnd)) < 5 else { return false }
        if let distance = mirror.distance, distance.isFinite, distance > 0, let other = strava.distance {
            return abs(distance - other) <= max(distance, other) * 0.002
        }
        return true
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
        func evidence(_ index: Int) -> WorkoutPausedTimingEvidence {
            let row = inputs[index]
            return WorkoutPausedTimingEvidence(
                start: row.start, duration: row.duration, distance: row.distance, end: endpoint(index),
                type: types[index], source: row.source,
                isGarmin: WorkoutAggregator.isGarminSource(source: row.source, bundleIdentifier: row.sourceBundleIdentifier,
                                                           manufacturer: row.deviceManufacturer, deviceName: row.deviceName),
                isStravaHealth: row.source == "healthKit" && row.sourceBundleIdentifier?.lowercased() == "com.strava.stravaride",
                isDeleted: row.isTombstoned || row.deletionOrigin != nil)
        }
        func strictTiming(_ first: Int, _ second: Int) -> Bool {
            let a = inputs[first], b = inputs[second]
            if let firstEnd = endpoint(first), let secondEnd = endpoint(second) {
                let firstElapsed = firstEnd.timeIntervalSince(a.start)
                let secondElapsed = secondEnd.timeIntervalSince(b.start)
                return firstElapsed.isFinite && secondElapsed.isFinite && firstElapsed > 0 && secondElapsed > 0
                    && abs(firstEnd.timeIntervalSince(secondEnd)) < 5
            }
            return abs(a.duration - b.duration) < 5
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
            return strictTiming(first, second) || plausiblePausedTiming(evidence(first), evidence(second))
        }
        func definite(_ first: Int, _ second: Int) throws -> Bool {
            guard try possible(first, second) else { return false }
            let a = inputs[first], b = inputs[second], type = types[first]
            if !strictTiming(first, second) { return pausedGarminStravaMatch(evidence(first), evidence(second)) }
            // Preserve ambiguity edges, but require actual endpoints before
            // grouping a candidate involving a user deletion.
            if a.deletionOrigin == "user" || b.deletionOrigin == "user" {
                guard endpoint(first) != nil && endpoint(second) != nil else { return false }
            }
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
            if (complete || (members.count == 3 && pausedGarminStravaTriad(members.map(evidence)))),
               let group = members.map({ inputs[$0].id }).min() {
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
