import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            WelcomePage()
                .tag(0)

            HealthKitPermissionPage()
                .tag(1)

            ThresholdInputPage(onComplete: {
                hasCompletedOnboarding = true
            })
            .tag(2)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }
}

struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            Text("Welcome to OnMyTSS")
                .font(.largeTitle.bold())

            Text("Calculate your daily Body Battery from training load, HRV, and resting heart rate.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Text("Swipe to continue")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 40)
        }
    }
}

struct HealthKitPermissionPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)

            Text("HealthKit Access")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(icon: "figure.run", text: "Read your workouts")
                PermissionRow(icon: "heart", text: "Read HRV and resting heart rate")
                PermissionRow(icon: "bed.double", text: "Read sleep data")
            }
            .padding(.horizontal, 40)

            Spacer()

            Text("We never share your data. Everything stays on your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 30)
                .foregroundStyle(.blue)
            Text(text)
        }
    }
}

struct ThresholdInputPage: View {
    @AppStorage("ftp") private var ftp: Double = 250
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "speedometer")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("Set Your FTP")
                .font(.largeTitle.bold())

            Text("We need your Functional Threshold Power to calculate training stress accurately.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                Text("FTP (Watts)")
                    .font(.headline)

                TextField("Enter FTP", value: $ftp, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    OnboardingView()
}
