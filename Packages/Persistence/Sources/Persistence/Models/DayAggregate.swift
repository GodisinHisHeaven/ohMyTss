import Foundation
import SwiftData

@Model
public final class DayAggregate {
    @Attribute(.unique) public var date: Date

    // Training Load
    public var dailyTSS: Double = 0
    public var ctl: Double = 0
    public var atl: Double = 0
    public var tsb: Double { ctl - atl }

    // Body Battery
    public var bodyBatteryRaw: Int = 50
    public var bodyBatteryFinal: Int = 50

    // Physiology (v1.0+)
    public var hrvMedian: Double?
    public var restingHR: Double?
    public var hrvAdjustment: Double = 0
    public var rhrAdjustment: Double = 0
    public var isIllnessDetected: Bool = false

    // Quality Flags
    public var hasWorkoutData: Bool = false
    public var hasHRVData: Bool = false
    public var hasRHRData: Bool = false
    public var sleepDuration: TimeInterval?

    // Metadata
    public var lastUpdated: Date
    public var workoutCount: Int = 0

    public init(date: Date) {
        self.date = Calendar.current.startOfDay(for: date)
        self.lastUpdated = Date()
    }
}
