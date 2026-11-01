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
    private enum IntensityField: Hashable { case lt1, lt2 }
    private let dataStore: DataStore
    @Environment(\.modelContext) private var modelContext
    @State private var cardioHR = ""
    @State private var cardioMessage: String?
    @State private var savingCardio = false
    @State private var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false
    @State private var showingFTPEditor = false
    @AppStorage("intensityLT1HeartRate") private var intensityLT1HeartRate = 0
    @AppStorage("intensityLT2HeartRate") private var intensityLT2HeartRate = 0
    @AppStorage("intensityLT2Source") private var intensityLT2Source = ""
    @State private var lt1Input = ""
    @State private var lt2Input = ""
    @State private var lt2ManuallyEdited = false
    @State private var loadedLT1 = 0
    @State private var loadedLT2 = 0
    @State private var loadedLT2Source = ""
    @State private var intensityMessage: String?
    @FocusState private var focusedIntensity: IntensityField?

    init(dataStore: DataStore, engine: any BodyBatteryEngineProtocol) {
        self.dataStore = dataStore
        _viewModel = State(initialValue: SettingsViewModel(dataStore: dataStore, engine: engine))
    }

    var body: some View {
        NavigationStack {
            SwissForm {
                Section {
                    TextField("Confirmed maximum heart rate (bpm)", text: $cardioHR)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("settings.cardioHR")
                        .disabled(savingCardio)
                    Button(savingCardio ? "Updating estimates…" : "Save Cardio Settings") {
                        Task { await saveCardioSettings() }
                    }
                    .disabled(savingCardio)
                    .swissAction()
                    .accessibilityIdentifier("settings.saveCardio")
                    if let cardioMessage { Text(cardioMessage).font(.caption) }
                } header: { Text("Cardio Load") } footer: {
                    Text("Optional. Use a maximum heart rate you know; no age or FTP default is assumed. Leave blank for unknown. Changing this creates new estimates from saved inputs, retaining earlier snapshots.")
                }
                .task {
                    if let value = try? DataStore(modelContext: modelContext).fetchUserThresholds().cardioMaxHeartRate {
                        cardioHR = String(value)
                    }
                }

                Section {
                    TextField("LT1 heart rate (bpm)", text: $lt1Input)
                        .keyboardType(.numberPad)
                        .focused($focusedIntensity, equals: .lt1)
                        .accessibilityIdentifier("settings.lt1HeartRate")
                    TextField("LT2 heart rate (bpm)", text: Binding(get: { lt2Input }, set: {
                        lt2Input = $0
                        lt2ManuallyEdited = true
                    }))
                        .keyboardType(.numberPad)
                        .focused($focusedIntensity, equals: .lt2)
                        .accessibilityIdentifier("settings.lt2HeartRate")
                    Button("Save intensity thresholds") { saveIntensityThresholds() }
                        .swissAction()
                        .accessibilityIdentifier("settings.saveIntensityThresholds")
                    if intensityLT2Source == "unvalidated_cycling_deflection", intensityLT2HeartRate > 0 {
                        Text("LT2 selected from an unvalidated cycling deflection candidate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let intensityMessage { Text(intensityMessage).font(.caption) }
                } header: {
                    Text("Training intensity")
                } footer: {
                    Text("Enter your LT1 heart rate. LT2 can be entered now or selected after reviewing a cycling test candidate. Values must be 30–240 bpm, with LT1 below LT2. Leave both blank to clear them.")
                }
                .onAppear {
                    loadedLT1 = intensityLT1HeartRate
                    loadedLT2 = intensityLT2HeartRate
                    loadedLT2Source = intensityLT2Source
                    lt1Input = intensityLT1HeartRate > 0 ? String(intensityLT1HeartRate) : ""
                    lt2Input = intensityLT2HeartRate > 0 ? String(intensityLT2HeartRate) : ""
                    lt2ManuallyEdited = false
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
                                .foregroundStyle(SwissStyle.positive)
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
                        Text("Garmin workouts are prioritized when the same activity appears in multiple sources.")
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
                    NavigationLink {
                        MorningStatusView(dataStore: dataStore)
                    } label: {
                        Label("Morning Status", systemImage: "message")
                    }
                    .accessibilityIdentifier("settings.morningStatus")
                } header: {
                    Text("Morning Status SMS")
                } footer: {
                    Text("Connect with your phone number to view morning status, set the delivery time zone and manage your texts here.")
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedIntensity != nil {
                        Spacer()
                        Button("Done") { focusedIntensity = nil }
                            .accessibilityIdentifier("settings.intensityDone")
                    }
                }
            }
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

    private func saveIntensityThresholds() {
        focusedIntensity = nil
        guard loadedLT1 == intensityLT1HeartRate, loadedLT2 == intensityLT2HeartRate,
              loadedLT2Source == intensityLT2Source else {
            intensityMessage = "Thresholds changed elsewhere. Reopen Settings to review the latest values."
            return
        }
        let first = lt1Input.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = lt2Input.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty && second.isEmpty {
            intensityLT1HeartRate = 0
            intensityLT2HeartRate = 0
            intensityLT2Source = ""
            loadedLT1 = 0
            loadedLT2 = 0
            loadedLT2Source = ""
            intensityMessage = "Intensity thresholds cleared."
            return
        }
        let lt2 = second.isEmpty ? nil : Int(second)
        guard let lt1 = Int(first), (30...240).contains(lt1),
              second.isEmpty || (lt2.map { (30...240).contains($0) && lt1 < $0 } == true) else {
            intensityMessage = "Enter LT1 from 30–240 bpm, and a higher LT2 if set."
            return
        }
        intensityLT1HeartRate = lt1
        intensityLT2HeartRate = lt2 ?? 0
        if lt2ManuallyEdited || lt2 == nil { intensityLT2Source = "" }
        loadedLT1 = intensityLT1HeartRate
        loadedLT2 = intensityLT2HeartRate
        loadedLT2Source = intensityLT2Source
        lt1Input = String(lt1)
        lt2Input = lt2.map { String($0) } ?? ""
        lt2ManuallyEdited = false
        intensityMessage = "Intensity thresholds saved."
    }

    @MainActor private func saveCardioSettings() async {
        guard !savingCardio else { return }
        let text = cardioHR.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || Int(text).map({ (100...230).contains($0) }) == true else {
            cardioMessage = "Enter 100–230 bpm, or leave blank for unknown."
            return
        }
        savingCardio = true
        cardioMessage = "Updating estimates. You can continue using the app."
        defer { savingCardio = false }
        do {
            let store = DataStore(modelContext: modelContext)
            let thresholds = try store.fetchUserThresholds()
            let value = Int(text)
            if thresholds.cardioMaxHeartRate != value {
                thresholds.cardioMaxHeartRate = value
                try store.saveUserThresholds(thresholds)
            }
            try await V2Store(context: modelContext).refreshEstimates()
            cardioMessage = "Saved. Estimates updated; previous versions retained."
        } catch {
            cardioMessage = "Could not finish updating estimates. Tap Save Cardio Settings to retry. \(error.localizedDescription)"
        }
    }

    // MARK: - Helper Views

    private func successBanner(message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SwissStyle.positive)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding()
            .swissGlass()
            .padding()

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func errorBanner(message: String) -> some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SwissStyle.caution)

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
            .swissGlass()
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
            SwissForm {
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
