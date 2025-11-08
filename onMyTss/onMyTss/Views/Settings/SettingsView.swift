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
    @State private var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false
    @State private var showingFTPEditor = false

    init(dataStore: DataStore, engine: BodyBatteryEngine) {
        _viewModel = State(initialValue: SettingsViewModel(dataStore: dataStore, engine: engine))
    }

    var body: some View {
        NavigationStack {
            Form {
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

                // Data Management
                Section("Data") {
                    Button {
                        Task {
                            await viewModel.syncData()
                        }
                    } label: {
                        HStack {
                            Label("Sync HealthKit Data", systemImage: "arrow.triangle.2.circlepath")
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
