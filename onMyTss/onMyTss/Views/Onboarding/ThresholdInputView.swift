//
//  ThresholdInputView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData

struct ThresholdInputView: View {
    @State private var dataStore: DataStore
    @State private var ftp: String = ""
    @State private var isSaving = false
    @State private var error: Error?

    var onComplete: () -> Void

    init(dataStore: DataStore, onComplete: @escaping () -> Void) {
        self.dataStore = dataStore
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Icon
            Image(systemName: "speedometer")
                .font(.system(size: 70))
                .foregroundColor(.orange)
                .padding(.bottom, 10)

            // Title
            Text("Set Your FTP")
                .font(.title)
                .fontWeight(.bold)

            // Description
            Text("Your Functional Threshold Power helps us calculate accurate training stress scores.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            // FTP Input
            VStack(alignment: .leading, spacing: 10) {
                Text("Cycling FTP (Watts)")
                    .font(.headline)

                HStack {
                    TextField("e.g., 250", text: $ftp)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2)

                    Text("W")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            // Help text
            VStack(alignment: .leading, spacing: 10) {
                Text("What is FTP?")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("FTP is the maximum power you can sustain for one hour. If you don't know your FTP, you can:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HelpItem(text: "Complete an FTP test")
                    HelpItem(text: "Estimate from a 20-minute test")
                    HelpItem(text: "Use a default value and update later")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
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
            Button(action: saveAndContinue) {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Continue")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(isValidFTP ? Color.blue : Color.gray)
            .cornerRadius(12)
            .disabled(!isValidFTP || isSaving)
            .padding(.horizontal)

            // Skip Button
            Button("Skip (Use Default)") {
                ftp = "\(Constants.defaultFTP)"
                saveAndContinue()
            }
            .foregroundColor(.secondary)
            .padding(.bottom, 30)
        }
        .padding()
    }

    private var isValidFTP: Bool {
        guard let ftpValue = Int(ftp) else { return false }
        return ftpValue >= Constants.minFTP && ftpValue <= Constants.maxFTP
    }

    private func saveAndContinue() {
        guard let ftpValue = Int(ftp), ftpValue >= Constants.minFTP else {
            error = ValidationError.invalidFTP
            return
        }

        isSaving = true
        error = nil

        Task {
            do {
                try dataStore.updateFTP(ftpValue)
                try dataStore.markOnboardingComplete()

                await MainActor.run {
                    isSaving = false
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    isSaving = false
                }
            }
        }
    }
}

struct HelpItem: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)

            Text(text)
        }
    }
}

enum ValidationError: LocalizedError {
    case invalidFTP

    var errorDescription: String? {
        switch self {
        case .invalidFTP:
            return "Please enter a valid FTP between \(Constants.minFTP) and \(Constants.maxFTP) watts."
        }
    }
}

#Preview {
    ThresholdInputView(
        dataStore: DataStore(modelContext: ModelContext(try! ModelContainer(for: UserThresholds.self))),
        onComplete: {}
    )
}
