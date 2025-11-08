import Foundation
import SwiftData

@Model
public final class AppState {
    @Attribute(.unique) public var id: String = "singleton"

    public var lastRecomputeDate: Date?
    public var healthKitAuthorized: Bool = false
    public var onboardingCompleted: Bool = false

    // HealthKit Anchors (stored as Data)
    public var workoutQueryAnchor: Data?
    public var hrvQueryAnchor: Data?
    public var rhrQueryAnchor: Data?

    // HRV/RHR baseline tracking
    public var hrvSamples: [Double] = []  // Last 28 nights
    public var rhrSamples: [Double] = []  // Last 28 days

    public var previousAdjustment: Double = 0  // For EWMA smoothing

    public init() {}
}
