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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SwissSectionHeading(number: "03", title: "Optional setup")
                Divider()

                // Title
                Text("Cycling Threshold (Optional)")
                    .font(.largeTitle.weight(.semibold)).tracking(-0.8)

                // Description
                Text("Your cycling FTP is used only for cycling power TSS. Other sports and local feedback work without it.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)

                // FTP Input
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cycling FTP (Watts)")
                        .font(.headline)

                    HStack {
                        TextField("e.g., 250", text: $ftp)
                            .font(.title2)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .textFieldStyle(.plain).padding(12)
                            .background(SwissStyle.inset, in: RoundedRectangle(cornerRadius: 8))

                        Text("W")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .swissPanel()

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
                        HelpItem(text: "Leave it unknown and update later")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .overlay(alignment: .top) { Divider() }

                // Spacer to allow scroll when keyboard is up
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .swissCanvas()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if let error = error {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(SwissStyle.critical)
                        .multilineTextAlignment(.leading)
                }

                Button(action: saveAndContinue) {
                    if isSaving {
                        ProgressView()
                            .tint(SwissStyle.accent)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .swissAction(prominent: true)
                .disabled(!isValidFTP || isSaving)

                Button("Skip (FTP Unknown)") {
                    do {
                        try dataStore.markOnboardingComplete()
                        onComplete()
                    } catch { self.error = error }
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(SwissStyle.canvas)
        }
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
                .foregroundStyle(SwissStyle.accent)
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
