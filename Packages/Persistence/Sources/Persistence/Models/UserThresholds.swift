import Foundation
import SwiftData

@Model
public final class UserThresholds {
    @Attribute(.unique) public var id: String = "primary"

    // Cycling
    public var ftp: Double?  // Watts

    // Running
    public var thresholdPace: Double?  // min/km
    public var thresholdHR: Double?    // bpm

    // Swimming
    public var criticalSwimSpeed: Double?  // min/100m

    // General
    public var restingHR: Double?
    public var maxHR: Double?

    // Preferences
    public var preferredUnits: UnitSystem = .metric
    public var enabledSports: Set<Sport> = [.cycling]

    public var lastModified: Date

    public init() {
        self.lastModified = Date()
    }
}

public enum Sport: String, Codable {
    case cycling
    case running
    case swimming
    case other
}

public enum UnitSystem: String, Codable {
    case metric
    case imperial
}
