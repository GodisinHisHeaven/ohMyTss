//
//  SettingsView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData

/// Settings screen for managing user preferences and app configuration
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var cardioHR = ""
    @State private var cardioMessage: String?
    @State private var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false
    @State private var showingFTPEditor = false

    init(dataStore: DataStore, engine: any BodyBatteryEngineProtocol) {
        _viewModel = State(initialValue: SettingsViewModel(dataStore: dataStore, engine: engine))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Confirmed maximum heart rate (bpm)", text: $cardioHR)
                        .keyboardType(.numberPad)
                    Button("Save Cardio Settings") {
                        do {
                            let store = DataStore(modelContext: modelContext)
                            let thresholds = try store.fetchUserThresholds()
                            let text = cardioHR.trimmingCharacters(in: .whitespaces)
                            if text.isEmpty { thresholds.cardioMaxHeartRate = nil }
                            else if let value = Int(text), (100...230).contains(value) {
                                thresholds.cardioMaxHeartRate = value
                            } else {
                                cardioMessage = "Enter 100–230 bpm, or leave blank for unknown."
                                return
                            }
                            try store.saveUserThresholds(thresholds)
                            try V2Store(context: modelContext).refreshEstimates()
                            cardioMessage = "Saved. New estimate snapshots created; previous versions retained."
                        } catch { cardioMessage = error.localizedDescription }
                    }
                    if let cardioMessage { Text(cardioMessage).font(.caption) }
                } header: { Text("Cardio Load") } footer: {
                    Text("Optional. Use a maximum heart rate you know; no age or FTP default is assumed. Leave blank for unknown. Changing this creates new estimates from saved inputs, retaining earlier snapshots.")
                }
                .task {
                    if let value = try? DataStore(modelContext: modelContext).fetchUserThresholds().cardioMaxHeartRate {
                        cardioHR = String(value)
                    }
                }

                // Cycling Settings
                Section("Cycling") {
                    HStack {
                        Label("FTP (Functional Threshold Power)", systemImage: "bolt.fill")
                        Spacer()
                        Text(viewModel.ftpDisplay)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingFTPEditor = true
                    }

                    Button {
                        showingFTPEditor = true
                    } label: {
                        Label("Edit FTP", systemImage: "pencil")
                    }
                }

                // Strava Integration
                Section {
                    if viewModel.isStravaConnected {
                        // Connected state
                        HStack {
                            Label(viewModel.stravaAthleteDisplay, systemImage: "person.fill")
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        if let stravaFTP = viewModel.stravaFTPDisplay {
                            HStack {
                                Label("Strava FTP", systemImage: "bolt.fill")
                                Spacer()
                                Text(stravaFTP)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // FTP Source Toggle (only if both FTPs exist)
                        if viewModel.showFTPToggle {
                            Toggle(isOn: $viewModel.preferStravaFTP) {
                                Label("Use Strava FTP", systemImage: "chart.line.uptrend.xyaxis")
                            }
                            .onChange(of: viewModel.preferStravaFTP) { _, _ in
                                Task {
                                    await viewModel.toggleStravaFTPPreference()
                                }
                            }

                            HStack {
                                Text("Active FTP Source")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(viewModel.activeFTPSource)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            Task {
                                await viewModel.disconnectStrava()
                            }
                        } label: {
                            Label("Disconnect Strava", systemImage: "link.badge.minus")
                        }
                        .disabled(viewModel.isSaving)

                    } else {
                        // Not connected state
                        Button {
                            Task {
                                await viewModel.connectStrava()
                            }
                        } label: {
                            HStack {
                                Label("Connect to Strava", systemImage: "link.badge.plus")
                                Spacer()
                                if viewModel.isConnectingStrava {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(viewModel.isConnectingStrava)
                    }
                } header: {
                    Text("Strava")
                } footer: {
                    if viewModel.isStravaConnected {
                        Text("Strava workouts will be synced and prioritized over HealthKit duplicates.")
                    } else {
                        Text("Connect your Strava account to sync activities and use Strava's FTP.")
                    }
                }

                // Data Management
                Section("Data") {
                    Button("Review Apple Health Access") {
                        Task {
                            do {
                                try await HealthKitManager().requestAuthorization()
                                cardioMessage = "Health access requested. Sync to read available records; read denial can appear as no data."
                            } catch { cardioMessage = "Health access unavailable. Manual records remain usable." }
                        }
                    }
                    Button {
                        Task {
                            await viewModel.syncData()
                        }
                    } label: {
                        HStack {
                            Label("Sync Activities", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if viewModel.isSaving {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isSaving)

                    HStack {
                        Label("Last Sync", systemImage: "clock.fill")
                        Spacer()
                        Text(viewModel.lastSyncDisplay)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Link(destination: AppIdentity.accountURL) {
                        Label("Open Morning Status Account", systemImage: "message")
                    }
                    Link(destination: AppIdentity.servicePrivacyURL) {
                        Label("Morning Status Privacy", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Morning Status SMS")
                } footer: {
                    Text("Existing ohMyTss accounts receive one morning status text when current-day data is available, between 6:00 and 10:30 AM in their local time. SMS requires opt-in; reply STOP to unsubscribe. Coaching chat, plans, and other alerts are paused. Opening the account page does not upload Apple Health data.")
                }

                // App Information
                Section("About") {
                    LabeledContent("Version", value: viewModel.appVersion)
                    LabeledContent("Build", value: viewModel.buildNumber)

                    Link(destination: URL(string: "https://godisinHisHeaven.github.io/ohMyTss/privacy-policy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised.fill")
                    }

                    Link(destination: URL(string: "https://github.com/GodisinHisHeaven/ohMyTss")!) {
                        Label("GitHub Repository", systemImage: "link")
                    }
                }

                // Danger Zone
                Section {
                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset All Data", systemImage: "trash.fill")
                    }
                    .disabled(viewModel.isSaving)
                } footer: {
                    Text("This will delete all calculated metrics. Your HealthKit data will not be affected.")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .task {
                await viewModel.loadSettings()
            }
            .sheet(isPresented: $showingFTPEditor) {
                FTPEditorSheet(viewModel: viewModel)
            }
            .alert("Reset All Data?", isPresented: $showingResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    Task {
                        await viewModel.resetAllData()
                    }
                }
            } message: {
                Text("This will delete all calculated Body Battery data. This action cannot be undone.")
            }
            .overlay {
                if let successMessage = viewModel.successMessage {
                    successBanner(message: successMessage)
                } else if let errorMessage = viewModel.errorMessage {
                    errorBanner(message: errorMessage)
                }
            }
        }
    }

    // MARK: - Helper Views

    private func successBanner(message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            .padding()

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func errorBanner(message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                Button("Dismiss") {
                    viewModel.errorMessage = nil
                }
                .font(.subheadline.weight(.medium))
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            .padding()

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - FTP Editor Sheet

struct FTPEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("FTP (Watts)", text: $viewModel.ftpInput)
                        .keyboardType(.numberPad)
                        .focused($isFocused)
                } header: {
                    Text("Functional Threshold Power")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your FTP is the maximum power you can sustain for one hour.")
                        Text("Valid range: \(Constants.minFTP)-\(Constants.maxFTP) watts")
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Edit FTP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.saveFTP()
                            if viewModel.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

// MARK: - Previews

#Preview {
    @Previewable @State var previewSetup: (DataStore, BodyBatteryEngine) = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: DayAggregate.self, UserThresholds.self, AppState.self, configurations: config)
        let dataStore = DataStore(modelContainer: container)

        // Create sample thresholds
        var thresholds = UserThresholds()
        thresholds.cyclingFTP = 250
        thresholds.hasCompletedOnboarding = true
        try! dataStore.saveUserThresholds(thresholds)

        let healthKitManager = HealthKitManager()
        let engine = BodyBatteryEngine(healthKitManager: healthKitManager, dataStore: dataStore)

        return (dataStore, engine)
    }()

    SettingsView(dataStore: previewSetup.0, engine: previewSetup.1)
        .modelContainer(for: [DayAggregate.self, UserThresholds.self, AppState.self])
}
