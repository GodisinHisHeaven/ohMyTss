//
//  SettingsViewModel.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftData

/// View model for the Settings screen
@MainActor
@Observable
class SettingsViewModel {
    // Dependencies
    private let dataStore: DataStore
    private let engine: BodyBatteryEngine

    // UI State
    var isLoading: Bool = false
    var isSaving: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // Settings Data
    var thresholds: UserThresholds?
    var ftpInput: String = ""
    var lastSyncDate: Date?

    init(dataStore: DataStore, engine: BodyBatteryEngine) {
        self.dataStore = dataStore
        self.engine = engine
    }

    // MARK: - Data Loading

    /// Load user settings
    func loadSettings() async {
        isLoading = true
        errorMessage = nil

        do {
            thresholds = try dataStore.fetchUserThresholds()

            // Initialize FTP input
            if let ftp = thresholds?.cyclingFTP {
                ftpInput = String(ftp)
            }

            // Get last sync date from app state
            let appState = try dataStore.fetchAppState()
            lastSyncDate = appState.lastHealthKitSyncDate

        } catch {
            errorMessage = "Failed to load settings: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Settings Actions

    /// Save FTP value
    func saveFTP() async {
        guard let ftpValue = Int(ftpInput), ftpValue >= Constants.minFTP, ftpValue <= Constants.maxFTP else {
            errorMessage = "FTP must be between \(Constants.minFTP) and \(Constants.maxFTP) watts"
            return
        }

        isSaving = true
        errorMessage = nil
        successMessage = nil

        do {
            guard var thresholds = thresholds else {
                throw SettingsError.noThresholdsFound
            }

            thresholds.cyclingFTP = ftpValue
            try dataStore.saveUserThresholds(thresholds)

            // Trigger recompute with new FTP
            try await engine.recomputeAll()

            successMessage = "FTP updated successfully"

            // Clear success message after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }

        } catch {
            errorMessage = "Failed to save FTP: \(error.localizedDescription)"
        }

        isSaving = false
    }

    /// Trigger manual data sync
    func syncData() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil

        do {
            try await engine.recomputeAll()

            // Update last sync date
            let appState = try dataStore.fetchAppState()
            lastSyncDate = appState.lastHealthKitSyncDate

            successMessage = "Data synced successfully"

            // Clear success message after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }

        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }

        isSaving = false
    }

    /// Reset all data
    func resetAllData() async {
        isSaving = true
        errorMessage = nil

        do {
            try dataStore.deleteAllDayAggregates()
            try dataStore.resetAppState()

            successMessage = "All data reset successfully"

        } catch {
            errorMessage = "Failed to reset data: \(error.localizedDescription)"
        }

        isSaving = false
    }

    // MARK: - Computed Properties

    var ftpDisplay: String {
        if let ftp = thresholds?.cyclingFTP {
            return "\(ftp) W"
        }
        return "Not set"
    }

    var lastSyncDisplay: String {
        guard let lastSync = lastSyncDate else {
            return "Never"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastSync, relativeTo: Date())
    }

    var appVersion: String {
        Constants.appVersion
    }

    var buildNumber: String {
        Constants.buildNumber
    }
}

// MARK: - Settings Errors

enum SettingsError: LocalizedError {
    case noThresholdsFound
    case invalidFTP

    var errorDescription: String? {
        switch self {
        case .noThresholdsFound:
            return "User settings not found"
        case .invalidFTP:
            return "Invalid FTP value"
        }
    }
}
