import Foundation

/// Sensor input for one workout. Missing samples remain unobserved time.
nonisolated struct IntensityWorkout {
    let start: Date
    let end: Date
    let heartRate: [TimedValue]
    let pauses: [TimeRange]
}

/// A source row and its canonical link. Suppressed aliases may contain the
/// heart-rate stream even when their canonical activity does not.
nonisolated struct IntensitySource {
    let id: String
    let linkedID: String?
    let isGarmin: Bool
    let isSuppressed: Bool
    let isDeleted: Bool
    let workout: IntensityWorkout
}

/// Time in each heart-rate range, using user-supplied lactate thresholds.
nonisolated struct IntensityDistribution {
    let lowSeconds: Double
    let moderateSeconds: Double
    let highSeconds: Double

    var totalSeconds: Double { lowSeconds + moderateSeconds + highSeconds }

    static func calculate(sources: [IntensitySource], lt1: Int, lt2: Int,
                          window: TimeRange) -> IntensityDistribution? {
        guard (30...240).contains(lt1), (30...240).contains(lt2), lt1 < lt2,
              window.duration > 0, window.duration.isFinite else { return nil }
        let live = sources.filter { !$0.isDeleted }
        let children = Dictionary(grouping: live.compactMap { source -> (String, IntensitySource)? in
            source.linkedID.map { ($0, source) }
        }, by: { $0.0 })
        var low = 0.0, moderate = 0.0, high = 0.0
        for canonical in live where !canonical.isSuppressed {
            let start = max(canonical.workout.start, window.start)
            let end = min(canonical.workout.end, window.end)
            guard end > start else { continue }
            let activityWindow = TimeRange(start: start, end: end)
            var group = [canonical]
            var visited: Set<String> = [canonical.id]
            var pending = [canonical.id]
            while let id = pending.popLast() {
                for (_, child) in children[id] ?? [] where visited.insert(child.id).inserted {
                    group.append(child)
                    pending.append(child.id)
                }
            }
            group.sort { $0.id < $1.id }
            let hasGarmin = group.contains { $0.isGarmin }
            let primaryPauses = canonical.isGarmin ? canonical.workout.pauses
                : group.first(where: { $0.isGarmin })?.workout.pauses ?? canonical.workout.pauses
            let candidates = group.map { source in
                let pauses = hasGarmin ? source.workout.pauses + primaryPauses : source.workout.pauses
                let intervals = SignalProcessing.intervals(samples: source.workout.heartRate,
                    window: activityWindow, pauses: pauses, validRange: 30...240)
                return (source: source, intervals: intervals, coverage: SignalProcessing.coveredSeconds(intervals))
            }.filter { !$0.intervals.isEmpty }.sorted {
                if hasGarmin && $0.source.isGarmin != $1.source.isGarmin { return $0.source.isGarmin }
                if hasGarmin && $0.source.isGarmin && ($0.source.id == canonical.id) != ($1.source.id == canonical.id) {
                    return $0.source.id == canonical.id
                }
                if !hasGarmin && $0.coverage == $1.coverage && ($0.source.id == canonical.id) != ($1.source.id == canonical.id) {
                    return $0.source.id == canonical.id
                }
                return $0.coverage == $1.coverage ? $0.source.id < $1.source.id : $0.coverage > $1.coverage
            }
            guard let first = candidates.first else { continue }
            var intervals = first.intervals
            if hasGarmin && first.source.isGarmin {
                for candidate in candidates.dropFirst() {
                    intervals = fillingGaps(in: intervals, with: candidate.intervals)
                }
            }
            for interval in intervals {
                if interval.value < Double(lt1) { low += interval.duration }
                else if interval.value < Double(lt2) { moderate += interval.duration }
                else { high += interval.duration }
            }
        }
        let result = IntensityDistribution(lowSeconds: low, moderateSeconds: moderate, highSeconds: high)
        return result.totalSeconds > 0 ? result : nil
    }

    /// Preferred-source intervals win overlaps; later sources fill only gaps.
    private static func fillingGaps(in selected: [TimedValue], with additions: [TimedValue]) -> [TimedValue] {
        var uncovered: [TimedValue] = []
        var firstPossible = 0
        for sample in additions {
            while firstPossible < selected.count && selected[firstPossible].end <= sample.start { firstPossible += 1 }
            var cursor = sample.start
            var index = firstPossible
            while index < selected.count && selected[index].start < sample.end {
                let existing = selected[index]
                if existing.start > cursor {
                    uncovered.append(.init(start: cursor, end: min(existing.start, sample.end), value: sample.value))
                }
                cursor = max(cursor, existing.end)
                if cursor >= sample.end { break }
                index += 1
            }
            if cursor < sample.end { uncovered.append(.init(start: cursor, end: sample.end, value: sample.value)) }
        }
        return (selected + uncovered).sorted { $0.start < $1.start }
    }


}

/// Timestamp-based integration shared by the import adapter and v2 model.
nonisolated enum SignalProcessing {
    /// Explicit nonzero intervals retain their measured support. Point samples are
    /// held until the next timestamp only when that gap is <= maxGap (15 s).
    /// Last points, invalid values, and longer gaps are missing, never zero.
    /// Overlap resolution is deterministic: latest start wins; equal starts use
    /// longest explicit support, then the lower value. This avoids double counting.
    static func intervals(
        samples: [TimedValue], window: TimeRange, pauses: [TimeRange] = [],
        validRange: ClosedRange<Double>, maxGap: TimeInterval = 15
    ) -> [TimedValue] {
        guard window.duration > 0, window.duration.isFinite else { return [] }
        let sorted = samples.filter {
            $0.value.isFinite && validRange.contains($0.value) &&
            $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite &&
            $0.end >= $0.start
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.value < $1.value
        }
        var unique: [TimedValue] = []
        for sample in sorted where unique.last?.start != sample.start { unique.append(sample) }
        var result: [TimedValue] = []
        for (index, sample) in unique.enumerated() {
            let nextStart = index + 1 < unique.count ? unique[index + 1].start : nil
            var end = sample.end
            if end == sample.start {
                guard let nextStart, nextStart.timeIntervalSince(sample.start) <= maxGap else { continue }
                end = nextStart
            }
            if let nextStart { end = min(end, nextStart) }
            let begin = max(sample.start, window.start)
            end = min(end, window.end)
            guard end > begin else { continue }
            var pieces = [TimeRange(start: begin, end: end)]
            for pause in pauses where pause.end > pause.start {
                pieces = pieces.flatMap { piece -> [TimeRange] in
                    guard pause.start < piece.end, pause.end > piece.start else { return [piece] }
                    var remaining: [TimeRange] = []
                    if pause.start > piece.start { remaining.append(.init(start: piece.start, end: pause.start)) }
                    if pause.end < piece.end { remaining.append(.init(start: pause.end, end: piece.end)) }
                    return remaining
                }
            }
            result.append(contentsOf: pieces.map { TimedValue(start: $0.start, end: $0.end, value: sample.value) })
        }
        return result
    }

    static func coveredSeconds(_ intervals: [TimedValue]) -> Double {
        intervals.reduce(0) { $0 + $1.duration }
    }

    static func weightedMean(_ intervals: [TimedValue]) -> Double? {
        let seconds = coveredSeconds(intervals)
        guard seconds > 0 else { return nil }
        let result = intervals.reduce(0) { $0 + $1.value * $1.duration } / seconds
        return result.isFinite ? result : nil
    }

    /// Exact integral over timestamp intervals. No interpolation across gaps.
    static func integral(_ intervals: [TimedValue], from: Date, to: Date) -> (value: Double, seconds: Double) {
        var value = 0.0
        var seconds = 0.0
        // Sanitized intervals are sorted and disjoint. Locate support by binary
        // search so a long workout does not rescan its whole stream each second.
        var low = 0, high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if intervals[middle].end <= from { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < intervals.count, intervals[index].start < to {
            let interval = intervals[index]
            let overlap = max(0, min(interval.end, to).timeIntervalSince(max(interval.start, from)))
            value += overlap * interval.value
            seconds += overlap
            index += 1
        }
        return (value, seconds)
    }

    /// 30 elapsed seconds, not 30 samples. Uses 1 s quadrature for the fourth
    /// power of rolling means; only windows with complete observed support count.
    /// Continuous fragments shorter than 30 s cannot produce NP.
    static func normalizedPower(_ intervals: [TimedValue], windowSeconds: Double = 30) -> Double? {
        guard windowSeconds > 0, windowSeconds.isFinite, !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted { $0.start < $1.start }
        var runs: [[TimedValue]] = []
        for interval in sorted {
            if let last = runs.last?.last, abs(interval.start.timeIntervalSince(last.end)) < 0.0001 {
                runs[runs.count - 1].append(interval)
            } else { runs.append([interval]) }
        }
        var fourth = 0.0
        var count = 0.0
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            var end = first.start.addingTimeInterval(windowSeconds)
            while end <= last.end {
                let sum = integral(run, from: end.addingTimeInterval(-windowSeconds), to: end)
                if abs(sum.seconds - windowSeconds) < 0.0001 {
                    fourth += pow(sum.value / windowSeconds, 4)
                    count += 1
                }
                end = end.addingTimeInterval(1)
            }
        }
        guard count > 0 else { return nil }
        let result = pow(fourth / count, 0.25)
        return result.isFinite ? result : nil
    }

    /// Simultaneous crank power/cadence only; N m is a crank torque proxy.
    /// Zero cadence is observed but cannot define finite torque.
    static func torque(power: [TimedValue], cadence: [TimedValue]) -> [TimedValue] {
        var result: [TimedValue] = []
        var p = 0
        var c = 0
        while p < power.count, c < cadence.count {
            let a = power[p], b = cadence[c]
            let start = max(a.start, b.start), end = min(a.end, b.end)
            if end > start, b.value > 0 {
                let value = a.value / (2 * Double.pi * b.value / 60)
                if value.isFinite { result.append(.init(start: start, end: end, value: value)) }
            }
            if a.end <= b.end { p += 1 } else { c += 1 }
        }
        return result
    }

    /// Route altitude noise suppression: 5-point median, then 3 m hysteresis.
    /// Does not invent terrain when route samples are absent.
    static func elevationChange(_ samples: [TimedValue]) -> (ascent: Double, descent: Double)? {
        let points = samples.filter { $0.value.isFinite && (-500...9000).contains($0.value) }.sorted { $0.start < $1.start }
        guard points.count >= 5 else { return nil }
        let filtered = points.indices.map { index -> Double in
            let lower = max(0, index - 2), upper = min(points.count - 1, index + 2)
            let values = points[lower...upper].map(\.value).sorted()
            return values[values.count / 2]
        }
        var anchor = filtered[0], ascent = 0.0, descent = 0.0
        for index in 1..<filtered.count {
            if points[index].start.timeIntervalSince(points[index - 1].start) > 30 {
                anchor = filtered[index]
                continue
            }
            let delta = filtered[index] - anchor
            if abs(delta) >= 3 {
                if delta > 0 { ascent += delta } else { descent -= delta }
                anchor = filtered[index]
            }
        }
        return (ascent, descent)
    }
}
