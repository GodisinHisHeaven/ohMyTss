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
    var onSkip: () -> Void

    init(healthKitManager: HealthKitManager, onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.healthKitManager = healthKitManager
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Icon
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 70))
                .foregroundColor(.red)
                .padding(.bottom, 10)

            // Title
            Text("Health Data Access")
                .font(.title)
                .fontWeight(.bold)

            // Description
            Text("Body Battery needs access to your workout data to calculate your daily readiness score.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            // What we access
            VStack(alignment: .leading, spacing: 15) {
                Text("We'll access:")
                    .font(.headline)
                    .padding(.bottom, 5)

                HealthDataRow(icon: "figure.run", text: "Workouts")
                HealthDataRow(icon: "bolt.fill", text: "Cycling Power")
                HealthDataRow(icon: "heart.fill", text: "Heart Rate")
                HealthDataRow(icon: "waveform.path.ecg", text: "Heart Rate Variability")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            // Privacy note
            Text("Your data never leaves your device and is not shared with anyone.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            // Error message
            if let error = error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Continue Button
            Button(action: requestPermission) {
                if isRequesting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Allow Access")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(Color.blue)
            .cornerRadius(12)
            .disabled(isRequesting)
            .padding(.horizontal)

            // Skip Button
            Button("Skip for Now") {
                onSkip()
            }
            .foregroundColor(.secondary)
            .padding(.bottom, 30)
        }
        .padding()
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
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    HealthPermissionView(
        healthKitManager: HealthKitManager(),
        onContinue: {},
        onSkip: {}
    )
}
