import Foundation

/// Experimental exposure rules. Levels describe recorded training demand only.
/// They do not measure tissue damage or predict recovery/safety.
nonisolated enum LoadModel {
    static let version = "v2-exposure-1"

    static func cardioLevel(_ points: Double) -> String {
        if points < 60 { return "Low" }
        if points < 180 { return "Moderate" }
        return "High"
    }

    static func estimate(
        type: String, start: Date, duration: Double, distance: Double?,
        features: WorkoutFeatures, sets: [StrengthSetInput], tags: [String],
        maxHeartRate: Int?, now: Date, recentRunningMinutes: Double? = nil
    ) -> LoadEstimateValue {
        let validDuration = duration.isFinite ? max(0, duration) : 0
        let end = min(features.end ?? start.addingTimeInterval(validDuration), now)
        let window = TimeRange(start: start, end: max(start, end))
        let active = SignalProcessing.intervals(
            samples: [.init(start: start, end: window.end, value: 1)],
            window: window, pauses: features.pauses, validRange: 0...1
        )
        let timelineSeconds = SignalProcessing.coveredSeconds(active)
        let seconds = min(validDuration, timelineSeconds)
        let unlocatedInactiveTime = timelineSeconds > validDuration + 30
        let minutes = seconds / 60
        let hr = SignalProcessing.intervals(samples: features.heartRate, window: window,
            pauses: features.pauses, validRange: 30...240)
        let hrCoverage = coverage(SignalProcessing.coveredSeconds(hr), timelineSeconds)
        var reasons = ["Experimental training exposure estimate; recovery time cannot yet be estimated.",
            "Body regions are bilateral unless you separately record left/right feedback."]
        reasons.append(contentsOf: features.provenance)
        var cardio: CardioEstimate?
        if let maxHeartRate, (100...240).contains(maxHeartRate), !hr.isEmpty, seconds > 0 {
            // Edwards-style zone minutes: <50% HRmax=0, then 1..5 for each 10% band.
            // This is its own unit; no conversion to power TSS or muscular load.
            let points = hr.reduce(0.0) { result, sample in
                result + sample.duration / 60 * zoneWeight(sample.value / Double(maxHeartRate))
            }
            var cardioReasons = [
                    "Integrated observed HR time using configured maximum HR \(maxHeartRate) bpm.",
                    "Weights 0 below 50%, then 1–5 across 50–60/60–70/70–80/80–90/90%+ of maximum HR.",
                    "Missing time is excluded, not estimated as zero. Observed \(Int((hrCoverage * 100).rounded()))% of the available timeline after known pauses.",
                    "Zone minutes are not power TSS. Maximum HR and coarse level thresholds are not personal calibration."
                ]
            if unlocatedInactiveTime {
                cardioReasons.append("Moving duration is shorter than the timeline after known pauses. Unlocated inactive time may be included in observed HR demand; no pause locations were invented.")
            }
            cardio = CardioEstimate(points: points, level: cardioLevel(points), coverage: hrCoverage,
                method: unlocatedInactiveTime ? "HR zone minutes (unlocated pauses)" : "HR zone minutes", reasons: cardioReasons)
        } else {
            reasons.append(hr.isEmpty ? "Cardio Load unknown: no usable timestamped heart rate." : "Cardio Load unknown: maximum HR is missing or outside 100–240 bpm.")
        }
        var regions: [RegionalEstimate] = []
        let sport = normalizedSport(type)
        if seconds > 0 {
            switch sport {
            case "cycling": regions = cyclingEstimates(minutes: minutes, seconds: seconds, features: features, tags: tags, window: window)
            case "running": regions = runningEstimates(minutes: minutes, seconds: seconds, distance: distance, features: features, window: window, recentMinutes: recentRunningMinutes)
            case "swimming": regions = swimmingEstimates(minutes: minutes, seconds: seconds, features: features, tags: tags, window: window)
            case "strength": break
            default: reasons.append("Regional burden unknown for this activity type. Add a manual region set to record participation.")
            }
        } else { reasons.append("No positive active duration; no endurance burden inferred.") }
        if !sets.isEmpty, start <= now {
            // A mixed session retains separate modality contributions/units.
            // Adding strength details cannot erase its run/ride/swim exposure.
            regions += strengthEstimates(sets)
        } else if sport == "strength" {
            reasons.append("Regional burden unknown: add completed strength sets or a manual region entry; an imported duration is not a muscle measurement.")
        }
        return LoadEstimateValue(version: version, method: "Independent HR and modality exposure",
            inputCutoff: min(now, max(start, end)), computedAt: now, cardio: cardio,
            regions: regions, coverage: hrCoverage, reasons: reasons)
    }

    static func normalizedSport(_ type: String) -> String {
        let value = type.lowercased()
        if value.contains("ride") || value.contains("cycl") || value.contains("bike") { return "cycling" }
        if value.contains("run") { return "running" }
        if value.contains("swim") { return "swimming" }
        if value.contains("strength") || value.contains("weight") || value.contains("functional") { return "strength" }
        return value
    }

    static func zoneWeight(_ ratio: Double) -> Double {
        guard ratio.isFinite, ratio >= 0.5 else { return 0 }
        if ratio < 0.6 { return 1 }
        if ratio < 0.7 { return 2 }
        if ratio < 0.8 { return 3 }
        if ratio < 0.9 { return 4 }
        return 5
    }

    private static func coverage(_ observed: Double, _ total: Double) -> Double {
        total > 0 ? min(1, max(0, observed / total)) : 0
    }

    private static func exposureLevel(_ minutes: Double) -> String {
        if minutes < 20 { return "Low" }
        if minutes < 60 { return "Moderate" }
        return "High"
    }

    private static func raised(_ level: String) -> String {
        level == "Low" ? "Moderate" : "High"
    }

    private static func cyclingEstimates(minutes: Double, seconds: Double, features: WorkoutFeatures, tags: [String], window: TimeRange) -> [RegionalEstimate] {
        let power = SignalProcessing.intervals(samples: features.power, window: window, pauses: features.pauses, validRange: 0...2500)
        let cadence = SignalProcessing.intervals(samples: features.cadence, window: window, pauses: features.pauses, validRange: 0...250)
        let torque = SignalProcessing.torque(power: power, cadence: cadence)
        let torqueSeconds = SignalProcessing.coveredSeconds(torque)
        let powerSeconds = SignalProcessing.coveredSeconds(power)
        let meanPower = SignalProcessing.weightedMean(power)
        let highPowerMinutes = meanPower.map { mean in
            power.filter { mean > 0 && $0.value > 1.5 * mean }.reduce(0) { $0 + $1.duration } / 60
        }
        let highTorqueMinutes = torque.filter { $0.value >= 40 }.reduce(0) { $0 + $1.duration } / 60
        var reasons = ["Cycling duration indicates leg participation; minute bands are provisional (<20 / <60 / ≥60)."]
        if let meanPower {
            reasons.append("Observed mean power \(Int(meanPower.rounded())) W; mechanical work \(Int((meanPower * powerSeconds / 1000).rounded())) kJ, not muscle work.")
            reasons.append("\(Int((highPowerMinutes ?? 0).rounded())) observed minutes above 1.5× this session's mean power; no FTP was invented.")
        } else { reasons.append("Power distribution missing; duration-only regional context.") }
        if let meanTorque = SignalProcessing.weightedMean(torque) {
            reasons.append("Observed crank torque proxy \(Int(meanTorque.rounded())) N m from simultaneous power/cadence; not muscle force or fatigue.")
            reasons.append("\(Int(highTorqueMinutes.rounded())) observed minutes at ≥40 N m; this provisional mechanical flag can raise leg exposure one grade after 10 minutes.")
        } else { reasons.append("Cadence/power overlap missing or cadence zero; crank torque unknown.") }
        if !tags.contains("standing") && !tags.contains("seated") { reasons.append("Riding posture unknown.") }
        let base = exposureLevel(minutes)
        let level = highTorqueMinutes >= 10 || (highPowerMinutes ?? 0) >= 10 ? raised(base) : base
        var regions: [Region] = [.quads, .glutes, .hamstrings, .calves]
        if tags.contains("standing") {
            reasons.append("User reported standing; core participation included. The tag does not specify its duration.")
            regions.append(.core)
        }
        return regions.map { region in
            RegionalEstimate(region: region, level: region == .quads || region == .glutes ? level : base,
                exposure: minutes, unit: "cycling minutes", method: "Cycling exposure heuristic",
                coverage: power.isEmpty ? 0.25 : max(0.25, coverage(torqueSeconds > 0 ? torqueSeconds : powerSeconds, seconds)),
                reasons: reasons)
        }
    }

    private static func runningEstimates(minutes: Double, seconds: Double, distance: Double?, features: WorkoutFeatures, window: TimeRange, recentMinutes: Double?) -> [RegionalEstimate] {
        let speed = SignalProcessing.intervals(samples: features.speed, window: window, pauses: features.pauses, validRange: 0...15)
        let grade = SignalProcessing.intervals(samples: features.grade, window: window, pauses: features.pauses, validRange: -0.5...0.5)
        let uphill = grade.filter { $0.value >= 0.03 }.reduce(0) { $0 + $1.duration } / 60
        let downhill = grade.filter { $0.value <= -0.03 }.reduce(0) { $0 + $1.duration } / 60
        let averageSpeed = SignalProcessing.weightedMean(speed)
        let fasterMinutes = averageSpeed.map { mean in
            speed.filter { mean > 0 && $0.value > mean * 1.2 }.reduce(0) { $0 + $1.duration } / 60
        }
        var reasons = ["Running minutes describe repeated lower-limb exposure; no injury probability is estimated."]
        if let distance, distance.isFinite, distance >= 0 { reasons.append("Recorded distance \(String(format: "%.1f", distance / 1000)) km; pace is contextual, not an individual intensity threshold.") }
        else { reasons.append("Distance missing.") }
        if let averageSpeed {
            reasons.append("Observed mean speed \(String(format: "%.1f", averageSpeed)) m/s; \(Int((fasterMinutes ?? 0).rounded())) minutes above 1.2× this session mean.")
        } else { reasons.append("Speed distribution missing; average distance/time does not replace it.") }
        let elevation = SignalProcessing.elevationChange(features.elevation.filter { $0.start >= window.start && $0.start <= window.end })
        // Whole-session altitude summaries are only available at the source endpoint.
        let sourceEnd = features.end ?? window.end
        let complete = window.end >= sourceEnd
        let ascent = (complete ? features.ascentMeters : nil) ?? elevation?.ascent
        let descent = (complete ? features.descentMeters : nil) ?? elevation?.descent
        if let ascent, let descent, ascent.isFinite, descent.isFinite {
            reasons.append("Filtered route elevation: \(Int(ascent.rounded())) m ascent / \(Int(descent.rounded())) m descent; altitude noise and route coverage limit this proxy.")
        }
        if !grade.isEmpty { reasons.append("Observed uphill \(Int(uphill.rounded())) min / downhill \(Int(downhill.rounded())) min at ±3% grade.") }
        else { reasons.append("Time-aligned slope unavailable; no slope-specific burden inferred.") }
        if let recentMinutes, recentMinutes.isFinite, recentMinutes >= 0 {
            reasons.append("Prior 28-day running exposure: \(Int(recentMinutes.rounded())) min (before this session); current \(Int(minutes.rounded())) min. This context is not a safe-load threshold.")
        } else { reasons.append("Recent running baseline unavailable; conservative initial duration rules only.") }
        let base = exposureLevel(minutes)
        return [Region.quads, .hamstrings, .glutes, .calves, .core].map { region in
            let terrainFlag = (region == .quads && downhill >= 5) || ((region == .glutes || region == .calves) && uphill >= 5)
            let speedFlag = (fasterMinutes ?? 0) >= 10 && region != .core
            var regionReasons = reasons
            if terrainFlag { regionReasons.append("Provisional terrain flag raises this region one grade after 5 observed slope minutes; no calibrated physiological coefficient.") }
            if speedFlag { regionReasons.append("Sustained faster running flag raises exposure one grade; it is relative to this session, not a measured threshold.") }
            return RegionalEstimate(region: region, level: terrainFlag || speedFlag ? raised(base) : base,
                exposure: minutes, unit: "running minutes", method: "Running exposure heuristic",
                coverage: speed.isEmpty ? 0.25 : max(0.25, coverage(SignalProcessing.coveredSeconds(speed), seconds)), reasons: regionReasons)
        }
    }

    private static func swimmingEstimates(minutes: Double, seconds: Double, features: WorkoutFeatures, tags: [String], window: TimeRange) -> [RegionalEstimate] {
        let strokeTags = ["freestyle", "backstroke", "breaststroke", "butterfly"]
        var strokeMinutes: [String: Double] = [:]
        // Overlapping source segments are cut at the next start, never double counted.
        let segments = features.swimSegments.sorted { $0.start < $1.start }
        for (index, segment) in segments.enumerated() {
            let end = min(segment.end, index + 1 < segments.count ? segments[index + 1].start : window.end)
            let values = SignalProcessing.intervals(samples: [.init(start: segment.start, end: end, value: 1)], window: window, pauses: features.pauses, validRange: 0...1)
            strokeMinutes[segment.stroke.lowercased(), default: 0] += SignalProcessing.coveredSeconds(values) / 60
        }
        if strokeMinutes.isEmpty, let tag = tags.first(where: { strokeTags.contains($0) }) {
            strokeMinutes[tag] = minutes
        }
        let knownMinutes = strokeMinutes.filter { strokeTags.contains($0.key) }.values.reduce(0, +)
        var regions: [Region] = [.shoulders, .back, .arms, .core]
        var reasons = ["Coarse swimming participation only; stroke segments and equipment are proxies, not muscle force."]
        if strokeMinutes.isEmpty { reasons.append("Stroke unknown; no stroke-specific inference.") }
        else {
            for stroke in strokeMinutes.keys.sorted() {
                reasons.append("\(stroke.capitalized): \(Int((strokeMinutes[stroke] ?? 0).rounded())) observed minutes.")
            }
        }
        if (strokeMinutes["breaststroke"] ?? 0) > 0 { regions += [.quads, .glutes, .chest] }
        if tags.contains("fins") { regions += [.calves, .glutes]; reasons.append("User reported fins; lower-limb participation included, magnitude uncalibrated.") }
        if tags.contains("kick_drill") { regions = [.quads, .glutes, .calves, .core]; reasons.append("User reported kick drill; lower-limb participation emphasized.") }
        if tags.contains("pull_buoy") { reasons.append("User reported pull buoy; upper-body context highlighted without assuming the legs were unused.") }
        if tags.contains("paddles") { reasons.append("User reported paddles; upper-body exposure grade raised once, an experimental rule without measured force.") }
        if !tags.contains(where: { ["fins", "paddles", "pull_buoy", "kick_drill"].contains($0) }) { reasons.append("Equipment unknown, not assumed absent.") }
        return Array(Set(regions)).sorted { $0.rawValue < $1.rawValue }.map { region in
            let paddleFlag = tags.contains("paddles") && [.shoulders, .back, .arms].contains(region)
            return RegionalEstimate(region: region, level: paddleFlag ? raised(exposureLevel(minutes)) : exposureLevel(minutes),
                exposure: minutes, unit: "swimming minutes", method: "Swimming participation heuristic",
                coverage: max(0.2, coverage(knownMinutes * 60, seconds)), reasons: reasons)
        }
    }

    private static func strengthEstimates(_ sets: [StrengthSetInput]) -> [RegionalEstimate] {
        var exposures: [Region: Double] = [:]
        var details: [Region: [String]] = [:]
        var known: [Region: Int] = [:]
        var counts: [Region: Int] = [:]
        for set in sets {
            guard (1...500).contains(set.reps), set.weightKG == nil || (set.weightKG!.isFinite && (0...1500).contains(set.weightKG!)),
                set.rir == nil || (0...10).contains(set.rir!) else { continue }
            let exercise = ExerciseCatalog.exercise(id: set.exerciseID)
            let regions = Array(Set((exercise?.regions ?? []) + set.manualRegions))
            guard !regions.isEmpty else { continue }
            let effortKnown = set.rir != nil || set.effort != nil
            let factor: Double
            if let rir = set.rir { factor = rir <= 1 ? 1.25 : (rir <= 3 ? 1 : 0.75) }
            else {
                switch set.effort {
                case .easy: factor = 0.75
                case .moderate: factor = 1
                case .hard: factor = 1.25
                case nil: factor = 1
                }
            }
            // Repetitions influence a bounded work-set proxy; kg*reps stays separate.
            let repetitionsFactor = set.reps > 15 ? 1.25 : (set.reps < 5 ? 0.75 : 1)
            for region in regions {
                exposures[region, default: 0] += factor * repetitionsFactor
                counts[region, default: 0] += 1
                if effortKnown, exercise != nil { known[region, default: 0] += 1 }
                var detail = "\(exercise?.name ?? "Manual participation"): \(set.reps) reps"
                if let kg = set.weightKG {
                    detail += ", \(String(format: "%.1f", kg)) kg external load (\(String(format: "%.1f", kg * Double(set.reps))) kg·reps)"
                } else { detail += ", external weight unknown" }
                if let rir = set.rir { detail += ", RIR \(rir)" }
                else if let effort = set.effort { detail += ", \(effort.label.lowercased()) effort" }
                else { detail += ", effort unknown" }
                if exercise == nil || set.manualRegions.contains(region) { detail += "; user-specified participation, low confidence" }
                details[region, default: []].append(detail)
            }
        }
        return exposures.keys.sorted { $0.rawValue < $1.rawValue }.map { region in
            let exposure = exposures[region] ?? 0
            var reasons = details[region] ?? []
            reasons += ["Work-set proxy: reps <5 / 5–15 / >15 use 0.75 / 1 / 1.25; RIR ≥4 / 2–3 / 0–1 use 0.75 / 1 / 1.25. Missing effort stays unknown (neutral factor).",
                "Each participating region receives the set participation proxy, not a force percentage. Do not sum regions.",
                "External kg·reps is retained as context; it does not independently determine recovery. Bodyweight and individual strength are not modeled.",
                "Provisional grades: <3 Low, <8 Moderate, ≥8 High equivalent sets; no physiological calibration."]
            return RegionalEstimate(region: region, level: exposure < 3 ? "Low" : (exposure < 8 ? "Moderate" : "High"),
                exposure: exposure, unit: "strength set equivalents", method: "Strength participation heuristic",
                coverage: Double(known[region] ?? 0) / Double(max(1, counts[region] ?? 0)), reasons: reasons)
        }
    }
}
