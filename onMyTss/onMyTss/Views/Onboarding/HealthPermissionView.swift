//
//  HealthPermissionView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

struct HealthPermissionView: View {
    @State private var healthKitManager: HealthKitManager
    @State private var isRequesting = false
    @State private var error: Error?

    var onContinue: () -> Void

    init(healthKitManager: HealthKitManager, onContinue: @escaping () -> Void) {
        self.healthKitManager = healthKitManager
        self.onContinue = onContinue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SwissSectionHeading(number: "02", title: "Apple Health")
                Divider()
                Text("Health Data Access")
                    .font(.largeTitle.weight(.semibold)).tracking(-0.8)
                Text("Use your workouts and recovery measurements to build your daily readiness estimate.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 20) {
                    HealthDataRow(icon: "figure.run", text: "Workouts")
                    Divider()
                    HealthDataRow(icon: "bolt", text: "Cycling Power")
                    Divider()
                    HealthDataRow(icon: "heart", text: "Heart Rate")
                    Divider()
                    HealthDataRow(icon: "waveform.path.ecg", text: "Heart Rate Variability")
                }
                .padding(20).swissPanel()
                Text("Raw Apple Health data stays on this device. Optional morning texts share a short summary only after you enable them.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error {
                    Text(error.localizedDescription).font(.footnote).foregroundStyle(SwissStyle.critical)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24).frame(maxWidth: .infinity)
        }
        .swissCanvas()
        .safeAreaInset(edge: .bottom) {
            Button(action: requestPermission) {
                HStack {
                    if isRequesting { ProgressView() }
                    Text("Continue").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .swissAction(prominent: true).disabled(isRequesting)
            .padding(24).background(SwissStyle.canvas)
        }
    }

    private func requestPermission() {
        isRequesting = true
        error = nil

        Task {
            do {
                try await healthKitManager.requestAuthorization()
                await MainActor.run {
                    isRequesting = false
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    isRequesting = false
                }
            }
        }
    }
}

struct HealthDataRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SwissStyle.accent)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    HealthPermissionView(
        healthKitManager: HealthKitManager(),
        onContinue: {}
    )
}
