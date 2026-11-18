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
    private let engine: any BodyBatteryEngineProtocol
    private let stravaAuthManager: any StravaConnectionManaging

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
    var preferStravaFTP: Bool { thresholds?.preferStravaFTP == true }

    init(dataStore: DataStore, engine: any BodyBatteryEngineProtocol, stravaAuthManager: any StravaConnectionManaging) {
        self.dataStore = dataStore
        self.engine = engine
        self.stravaAuthManager = stravaAuthManager
    }

    // Convenience init for backward compatibility
    convenience init(dataStore: DataStore, engine: any BodyBatteryEngineProtocol) {
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

            let message = appState.lastSyncMessage
            successMessage = message.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            } ?? "Data synced successfully"

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

    func resetActivitySync() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        successMessage = nil

        do {
            try await engine.resetActivitySync()
            lastSyncDate = try dataStore.fetchAppState().lastHealthKitSyncDate
            successMessage = "Activity sync reset"

        } catch {
            errorMessage = "Failed to reset activity sync: \(error.localizedDescription)"
        }

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

            successMessage = "Connected to Strava successfully"

            do {
                try await engine.recomputeAll()
                lastSyncDate = try dataStore.fetchAppState().lastHealthKitSyncDate
            } catch {
                errorMessage = "Strava connected, but workout sync failed: \(error.localizedDescription)"
            }

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
            if let thresholds, thresholds.preferStravaFTP {
                try dataStore.setStravaFTPPreference(false, for: thresholds)
            }

            successMessage = "Disconnected from Strava"
            do { try await engine.recomputeAll() }
            catch { errorMessage = "Strava disconnected. Sync again to update training load." }

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

    func setStravaFTPPreference(_ enabled: Bool) async {
        guard !isSaving, let thresholds, enabled != thresholds.preferStravaFTP else { return }

        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        successMessage = nil

        do {
            try dataStore.setStravaFTPPreference(enabled, for: thresholds)
        } catch {
            errorMessage = "Failed to save FTP preference: \(error.localizedDescription)"
            return
        }

        do {
            try await engine.recomputeAll()
            successMessage = "FTP preference saved"
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                successMessage = nil
            }
        } catch {
            errorMessage = "FTP preference saved. Sync again to update training load."
        }
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
        guard let stravaFTP = stravaAuth?.validFTP else {
            return nil
        }
        return "\(stravaFTP) W"
    }

    var showFTPToggle: Bool {
        // Only show toggle if both manual and Strava FTP exist
        return thresholds?.cyclingFTP != nil && stravaAuth?.validFTP != nil
    }

    var activeFTPSource: String {
        thresholds?.effectiveCyclingFTP(strava: stravaAuth).fromStrava == true ? "Strava" : "Manual"
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
