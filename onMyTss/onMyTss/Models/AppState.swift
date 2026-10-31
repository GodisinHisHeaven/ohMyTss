//
//  AppState.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

@Model
final class AppState {
    @Attribute(.unique) var id: String

    // HealthKit sync state
    var lastHealthKitSyncDate: Date?
    var healthKitAnchor: Data? // HKQueryAnchor for anchored queries
    var lastHealthKitSampleRefreshDate: Date?
    var pendingHealthKitWorkoutIDs: [String] = []
    // Separate from sensor retries: unsupported activity types are checked only once.
    var healthKitTypeBackfillVersion: Int = 0
    var pendingHealthKitTypeBackfillIDs: [String] = []
    // Independent checkpoint for identifying the producer of old HealthKit rows.
    var healthKitSourceBackfillVersion: Int = 0
    var pendingHealthKitSourceBackfillIDs: [String] = []
    var pendingWorkoutSourceFinalization: Bool = false
    var lastRecoverySyncDate: Date?

    var lastSyncMessage: String?

    // Computation state
    var lastComputationDate: Date?
    var isComputationInProgress: Bool

    // User engagement
    var appInstallDate: Date
    var lastOpenDate: Date

    // Feature flags (future use)
    var enabledFeatures: [String]

    init(
        id: String = "app_state",
        lastHealthKitSyncDate: Date? = nil,
        healthKitAnchor: Data? = nil,
        lastComputationDate: Date? = nil,
        isComputationInProgress: Bool = false,
        appInstallDate: Date = Date(),
        lastOpenDate: Date = Date(),
        enabledFeatures: [String] = []
    ) {
        self.id = id
        self.lastHealthKitSyncDate = lastHealthKitSyncDate
        self.healthKitAnchor = healthKitAnchor
        self.lastComputationDate = lastComputationDate
        self.isComputationInProgress = isComputationInProgress
        self.appInstallDate = appInstallDate
        self.lastOpenDate = lastOpenDate
        self.enabledFeatures = enabledFeatures
    }
}
