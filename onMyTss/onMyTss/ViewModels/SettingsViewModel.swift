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
    private let stravaAuthManager: StravaAuthManager

    // UI State
    var isLoading: Bool = false
    var isSaving: Bool = false
    var errorMessage: String?
    var successMessage: String?

    // Settings Data
    var thresholds: UserThresholds?
    var ftpInput: String = ""
    var lastSyncDate: Date?

    // Strava State
    var stravaAuth: StravaAuth?
    var isConnectingStrava: Bool = false
    var preferStravaFTP: Bool = false

    init(dataStore: DataStore, engine: BodyBatteryEngine, stravaAuthManager: StravaAuthManager) {
        self.dataStore = dataStore
        self.engine = engine
        self.stravaAuthManager = stravaAuthManager
    }

    // Convenience init for backward compatibility
    convenience init(dataStore: DataStore, engine: BodyBatteryEngine) {
        let stravaAuthManager = StravaAuthManager(dataStore: dataStore)
        self.init(dataStore: dataStore, engine: engine, stravaAuthManager: stravaAuthManager)
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

            // Load Strava auth state
            stravaAuth = try dataStore.fetchStravaAuth()
            preferStravaFTP = thresholds?.preferStravaFTP ?? false

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
            try dataStore.deleteAllWorkouts()
            try dataStore.resetAppState()

            successMessage = "All data reset successfully"

        } catch {
            errorMessage = "Failed to reset data: \(error.localizedDescription)"
        }

        isSaving = false
    }

    // MARK: - Strava Actions

    /// Connect to Strava
    func connectStrava() async {
        isConnectingStrava = true
        errorMessage = nil
        successMessage = nil

        do {
            try await stravaAuthManager.connectStrava()

            // Reload Strava auth state
            stravaAuth = try dataStore.fetchStravaAuth()

            // Update Strava FTP from athlete profile if available
            if let stravaFTP = stravaAuth?.stravaFTP {
                thresholds?.stravaFTP = stravaFTP
                try dataStore.saveUserThresholds(thresholds!)
            }

            // Trigger data sync to fetch Strava activities
            try await engine.recomputeAll()

            successMessage = "Connected to Strava successfully"

            // Clear success message after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }

        } catch {
            errorMessage = "Failed to connect Strava: \(error.localizedDescription)"
        }

        isConnectingStrava = false
    }

    /// Disconnect from Strava
    func disconnectStrava() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil

        do {
            try await stravaAuthManager.disconnectStrava()

            // Clear Strava auth state
            stravaAuth = nil

            // Reset prefer Strava FTP flag
            preferStravaFTP = false
            thresholds?.preferStravaFTP = false
            thresholds?.stravaFTP = nil
            try dataStore.saveUserThresholds(thresholds!)

            successMessage = "Disconnected from Strava"

            // Clear success message after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }

        } catch {
            errorMessage = "Failed to disconnect Strava: \(error.localizedDescription)"
        }

        isSaving = false
    }

    /// Toggle Strava FTP preference
    func toggleStravaFTPPreference() async {
        guard var thresholds = thresholds else { return }

        isSaving = true
        errorMessage = nil

        do {
            preferStravaFTP.toggle()
            thresholds.preferStravaFTP = preferStravaFTP
            try dataStore.saveUserThresholds(thresholds)

            // Recompute with new FTP preference
            try await engine.recomputeAll()

            let source = preferStravaFTP ? "Strava" : "manual"
            successMessage = "Now using \(source) FTP"

            // Clear success message after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }

        } catch {
            errorMessage = "Failed to update FTP preference: \(error.localizedDescription)"
            // Revert toggle on error
            preferStravaFTP.toggle()
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

    // MARK: - Strava Computed Properties

    var isStravaConnected: Bool {
        stravaAuth?.isConnected ?? false
    }

    var stravaAthleteDisplay: String {
        guard let auth = stravaAuth, auth.isConnected else {
            return "Not connected"
        }
        return auth.athleteName ?? "Strava Athlete"
    }

    var stravaFTPDisplay: String? {
        guard let stravaFTP = stravaAuth?.stravaFTP else {
            return nil
        }
        return "\(stravaFTP) W"
    }

    var showFTPToggle: Bool {
        // Only show toggle if both manual and Strava FTP exist
        return thresholds?.cyclingFTP != nil && stravaAuth?.stravaFTP != nil
    }

    var activeFTPSource: String {
        if preferStravaFTP, let _ = stravaAuth?.stravaFTP {
            return "Strava"
        } else {
            return "Manual"
        }
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
