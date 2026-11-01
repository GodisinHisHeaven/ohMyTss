import Foundation

/// An experimental heart-rate/power deflection candidate from a complete,
/// user-confirmed incremental cycling test. This does not measure lactate.
/// The method and its engineering quality gates have not been validated for
/// identifying either lactate threshold or for individual accuracy.
/// Do not infer an intentional test from a workout's shape.
nonisolated struct HRPowerDeflectionCandidate: Equatable, Sendable {
    let heartRateBPM: Double
    let powerWatts: Double
    /// The complete test explicitly marked by the user.
    let testWindow: TimeRange
    /// Full-minute prefix used for analysis; the final partial minute is excluded.
    let analyzedWindow: TimeRange
}

nonisolated enum HRPowerDeflectionEstimator {
    private struct Bin { let power: Double; let hr: Double }
    private struct Fit { let error: Double; let coefficients: [Double] }

    static func candidate(window: TimeRange, heartRate: [TimedValue], power: [TimedValue],
                          userConfirmedCompleteIncrementalTest: Bool,
                          pauses: [TimeRange] = []) -> HRPowerDeflectionCandidate? {
        let seconds = window.duration
        guard userConfirmedCompleteIncrementalTest, seconds.isFinite, seconds >= 12 * 60, seconds < 41 * 60,
              !pauses.contains(where: { $0.start < window.end && $0.end > window.start }),
              rawSamplesAreUsable(heartRate, window: window, validRange: 30...240),
              rawSamplesAreUsable(power, window: window, validRange: 20...1500) else { return nil }
        let hr = SignalProcessing.intervals(samples: heartRate, window: window,
                    validRange: 30...240, maxGap: 5)
        let watts = SignalProcessing.intervals(samples: power, window: window,
                    validRange: 20...1500, maxGap: 5)
        let count = Int(seconds / 60)
        var bins = [Bin]()
        for minute in 0..<count {
            let start = window.start.addingTimeInterval(Double(minute) * 60)
            let end = start.addingTimeInterval(60)
            guard let h = statistics(hr, from: start, to: end),
                  let p = statistics(watts, from: start, to: end),
                  h.coverage >= 59.0, p.coverage >= 59.0,
                  h.standardDeviation <= 6, p.standardDeviation <= 12,
                  h.range <= 24, p.range <= 50 else { return nil }
            bins.append(Bin(power: p.mean, hr: h.mean))
        }
        guard let first = bins.first, let last = bins.last,
              last.power - first.power >= 100, last.hr - first.hr >= 20 else { return nil }
        let tailStart = window.start.addingTimeInterval(Double(count) * 60)
        let tailSeconds = window.end.timeIntervalSince(tailStart)
        if tailSeconds > 0 {
            // The incomplete tail is not fitted, but still belongs to the
            // user-selected test and must have coverage and a plausible trend.
            guard let h = statistics(hr, from: tailStart, to: window.end),
                  let p = statistics(watts, from: tailStart, to: window.end),
                  h.coverage >= max(tailSeconds - 1, tailSeconds * 0.95),
                  p.coverage >= max(tailSeconds - 1, tailSeconds * 0.95),
                  h.standardDeviation <= 6, p.standardDeviation <= 12,
                  h.range <= 24, p.range <= 50,
                  (-3...10).contains(h.mean - last.hr),
                  (-5...35).contains(p.mean - last.power) else { return nil }
        }
        for i in 1..<bins.count {
            let dp = bins[i].power - bins[i-1].power
            let dh = bins[i].hr - bins[i-1].hr
            guard (5...35).contains(dp), (-1...10).contains(dh) else { return nil }
        }
        let x = bins.map { ($0.power - first.power) / 100 }
        let y = bins.map(\.hr)
        guard let linear = fit(x: x, y: y, knot: nil), linear.error > 1 else { return nil }
        // Find the unrestricted best fit first. Restricting the search before
        // fitting can misreport an early/late deflection as an interior one.
        let allFits: [(Int, Fit)] = (1..<(count - 2)).compactMap { i in
            fit(x: x, y: y, knot: x[i]).map { (i, $0) }
        }.sorted { $0.1.error < $1.1.error }
        guard let overallBest = allFits.first,
              (3..<(count - 4)).contains(overallBest.0) else { return nil }
        var candidates: [(Int, Fit)] = []
        // At least four observations on each side of the fitted knot.
        for (i, f) in allFits where (3..<(count - 4)).contains(i) {
            let early = f.coefficients[1], late = early + f.coefficients[2]
            guard early > 0, late > 0, late <= early * 0.65,
                  f.error <= linear.error * 0.30,
                  sqrt(f.error / Double(count)) <= 2 else { continue }
            candidates.append((i, f))
        }
        candidates.sort { $0.1.error < $1.1.error }
        guard let best = candidates.first, best.0 == overallBest.0 else { return nil }
        // Reject a materially different breakpoint that explains the data almost as well.
        if allFits.dropFirst().contains(where: { abs($0.0 - best.0) > 2 &&
            $0.1.error <= max(best.1.error * 1.25, best.1.error + 1) }) { return nil }
        let i = best.0
        let fittedHR = best.1.coefficients[0] + best.1.coefficients[1] * x[i]
        guard fittedHR.isFinite, (30...240).contains(fittedHR) else { return nil }
        return .init(heartRateBPM: fittedHR, powerWatts: bins[i].power, testWindow: window,
                     analyzedWindow: .init(start: window.start,
                                           end: window.start.addingTimeInterval(Double(count) * 60)))
    }

    /// Check the raw data before filtering/interpolation, so an invalid or
    /// conflicting observation cannot disappear and make its neighbors appear
    /// continuous. Long explicit averages cannot prove fine-grained coverage.
    private static func rawSamplesAreUsable(_ samples: [TimedValue], window: TimeRange,
                                           validRange: ClosedRange<Double>) -> Bool {
        var starts: [Date: TimedValue] = [:]
        for sample in samples {
            guard sample.start.timeIntervalSince1970.isFinite,
                  sample.end.timeIntervalSince1970.isFinite,
                  sample.end >= sample.start else { return false }
            guard sample.start <= window.end && sample.end >= window.start else { continue }
            guard sample.value.isFinite, validRange.contains(sample.value),
                  sample.end.timeIntervalSince(sample.start) <= 5 else { return false }
            if let prior = starts[sample.start], prior.end != sample.end || prior.value != sample.value {
                return false
            }
            starts[sample.start] = sample
        }
        return true
    }

    private static func statistics(_ rows: [TimedValue], from: Date, to: Date)
      -> (mean: Double, standardDeviation: Double, range: Double, coverage: Double)? {
        var duration = 0.0, sum = 0.0, square = 0.0
        var minimum = Double.infinity, maximum = -Double.infinity
        for row in rows where row.start < to && row.end > from {
            let d = min(row.end, to).timeIntervalSince(max(row.start, from))
            guard d > 0 else { continue }
            duration += d; sum += row.value * d; square += row.value * row.value * d
            minimum = min(minimum, row.value); maximum = max(maximum, row.value)
        }
        guard duration > 0 else { return nil }
        let mean = sum / duration
        return (mean, sqrt(max(0, square / duration - mean * mean)), maximum - minimum, duration)
    }

    /// Ordinary least squares, with a continuous hinge at knot when supplied.
    private static func fit(x: [Double], y: [Double], knot: Double?) -> Fit? {
        let rows = x.map { v -> [Double] in
            if let knot { return [1, v, max(0, v - knot)] }
            return [1, v]
        }
        let n = rows[0].count
        var a = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n)
        for i in 0..<rows.count {
            for j in 0..<n {
                for k in 0..<n { a[j][k] += rows[i][j] * rows[i][k] }
                a[j][n] += rows[i][j] * y[i]
            }
        }
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-10 else { return nil }
            a.swapAt(col, pivot)
            let divisor = a[col][col]
            for k in col...n { a[col][k] /= divisor }
            for r in 0..<n where r != col {
                let factor = a[r][col]
                for k in col...n { a[r][k] -= factor * a[col][k] }
            }
        }
        let coef = a.map { $0[n] }
        let error = zip(rows, y).reduce(0.0) { total, pair in
            let prediction = zip(pair.0, coef).reduce(0.0) { $0 + $1.0 * $1.1 }
            return total + pow(pair.1 - prediction, 2)
        }
        guard error.isFinite, coef.allSatisfy(\.isFinite) else { return nil }
        return Fit(error: error, coefficients: coef)
    }
}
