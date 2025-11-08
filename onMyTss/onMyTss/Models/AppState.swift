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
