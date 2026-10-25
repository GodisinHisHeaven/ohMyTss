import Foundation

/// Timestamp-based integration shared by the import adapter and v2 model.
enum SignalProcessing {
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
