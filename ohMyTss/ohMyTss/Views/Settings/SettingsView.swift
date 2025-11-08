import SwiftUI

struct SettingsView: View {
    @AppStorage("ftp") private var ftp: Double = 250
    @AppStorage("thresholdPace") private var thresholdPace: Double = 4.0  // min/km

    var body: some View {
        NavigationStack {
            Form {
                Section("Cycling") {
                    HStack {
                        Text("FTP")
                        Spacer()
                        TextField("Watts", value: $ftp, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("W")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Running") {
                    HStack {
                        Text("Threshold Pace")
                        Spacer()
                        TextField("min/km", value: $thresholdPace, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("min/km")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data") {
                    Button("Request HealthKit Permission") {
                        // TODO: Request permission
                    }

                    Button("Export Data") {
                        // TODO: Export JSON
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")

                    Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
                    Link("GitHub", destination: URL(string: "https://github.com/GodisinHisHeaven/ohMyTss")!)
                }

                Section {
                    Button("Reset All Data", role: .destructive) {
                        // TODO: Confirm + reset
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
