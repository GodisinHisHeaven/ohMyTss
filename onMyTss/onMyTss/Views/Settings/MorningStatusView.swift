import SwiftUI

struct MorningStatusView: View {
    @State private var model: MorningStatusViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var timezone = "UTC"
    @State private var confirmingUnsubscribe = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--morning-status-ui-fixture") {
            _model = State(initialValue: MorningStatusViewModel(api: MorningStatusUIFixture(), tokenStore: MorningSessionUIFixture()))
            return
        }
        #endif
        _model = State(initialValue: MorningStatusViewModel())
    }

    var body: some View {
        Form {
            if model.isSignedIn {
                if let status = model.status {
                    accountSection(status)
                    deliverySection(status)
                    wellnessSection(status)
                    Section {
                        NavigationLink {
                            MorningTimeZonePicker(selection: $timezone)
                        } label: {
                            LabeledContent("Time zone", value: timezone.replacingOccurrences(of: "_", with: " "))
                        }
                        .accessibilityIdentifier("morning.timezone")
                        Button("Use This Device's Time Zone") { timezone = TimeZone.current.identifier }
                        Button("Save Time Zone") { Task { await model.saveTimezone(timezone) } }
                            .disabled(model.isBusy || timezone == status.timezone)
                            .accessibilityIdentifier("morning.saveTimezone")
                        if let notice = model.notice {
                            Text(notice).foregroundStyle(.secondary)
                                .accessibilityIdentifier("morning.notice")
                        }
                    } header: { Text("Delivery settings") } footer: {
                        Text("The morning window follows this account time zone. Changing it does not send a message or reset today's delivery record.")
                    }
                    if status.smsEnabled {
                        Section {
                            Button("Turn Off Morning Texts", role: .destructive) { confirmingUnsubscribe = true }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("morning.unsubscribe")
                        }
                    }
                } else if !model.isBusy {
                    Section { Text("Your account is signed in. Refresh to load morning status.") }
                }
                Section {
                    Button("Refresh Status") { Task { await model.refresh() } }
                        .disabled(model.isBusy)
                    Button("Sign Out", role: .destructive) { model.signOut() }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("morning.signOut")
                } footer: {
                    Text("Signing out only removes this device's account session. It does not change your SMS subscription.")
                }
            } else {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("morning.email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("morning.password")
                    Button("Sign In") {
                        Task {
                            let submittedPassword = password
                            password = ""
                            await model.signIn(email: email, password: submittedPassword)
                        }
                    }
                    .disabled(model.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("morning.signIn")
                } header: { Text("Morning status account") } footer: {
                    Text("Use the email and password for your existing morning status account. New signups are paused.")
                }
            }

            if model.isBusy {
                Section { ProgressView("Loading morning status…") }
            }
            if let error = model.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    .accessibilityIdentifier("morning.error")
            }
            Section {
                NavigationLink("Data and Privacy") { MorningStatusPrivacyView() }
                    .accessibilityIdentifier("morning.privacy")
            } footer: {
                Text("Morning status uses your existing account's Intervals.icu data. Apple Health data is not uploaded by this feature.")
            }
        }
        .navigationTitle("Morning Status")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onChange(of: model.status?.timezone) { _, value in if let value { timezone = value } }
        .confirmationDialog("Turn off morning texts?", isPresented: $confirmingUnsubscribe, titleVisibility: .visible) {
            Button("Turn Off Texts", role: .destructive) { Task { await model.unsubscribe() } }
        } message: {
            Text("This unsubscribes your account from SMS. To resubscribe, reply START to an existing ohMyTss message.")
        }
    }

    private func accountSection(_ status: MorningStatus) -> some View {
        Section("Account") {
            LabeledContent("Name", value: status.displayName)
                .accessibilityIdentifier("morning.name")
            LabeledContent("Email", value: status.email)
            LabeledContent("Phone", value: status.phoneHint ?? "Not configured")
            LabeledContent("SMS", value: status.subscriptionLabel)
                .accessibilityIdentifier("morning.subscription")
            if !status.smsEnabled {
                Text("If your phone is already linked, reply START to an existing ohMyTss text to resubscribe. Reply STOP at any time to unsubscribe.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func deliverySection(_ status: MorningStatus) -> some View {
        Section {
            LabeledContent("Account date", value: status.localDate)
            LabeledContent("Morning window", value: "\(status.windowStart)–\(status.windowEnd)")
            Text(status.deliveryDescription)
                .accessibilityIdentifier("morning.delivery")
            if status.sentToday {
                Text("Submission does not confirm carrier delivery.").font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Wellness synced through", value: status.wellnessThrough ?? "No data yet")
            if status.syncFailures > 0 {
                Label("The last data sync did not complete. Scheduled sync will retry.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: { Text("Today's delivery") } footer: {
            Text("Up to one morning text per local day, between 06:00 and 10:30, after current-day data is available. Refreshing this screen does not send a text.")
        }
    }

    private func wellnessSection(_ status: MorningStatus) -> some View {
        Section("Today's wellness") {
            if let wellness = status.wellness {
                LabeledContent("HRV", value: measurement(wellness.hrv, unit: "ms"))
                LabeledContent("Resting heart rate", value: measurement(wellness.restingHr, unit: "bpm"))
                LabeledContent("Sleep", value: measurement(wellness.sleepHours, unit: "hours"))
                LabeledContent("Training stress balance", value: measurement(wellness.tsb, unit: ""))
            } else {
                Text("No wellness record for this account's current date yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func measurement(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "Not available" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)".trimmingCharacters(in: .whitespaces)
    }
}

private struct MorningTimeZonePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var search = ""

    private var timezones: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter {
            search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(timezones, id: \.self) { identifier in
            Button {
                selection = identifier
                dismiss()
            } label: {
                HStack {
                    Text(identifier.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.primary)
                    Spacer()
                    if identifier == selection { Image(systemName: "checkmark") }
                }
            }
            .accessibilityIdentifier("morning.zone.\(identifier)")
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or time zone")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MorningStatusPrivacyView: View {
    var body: some View {
        List {
            Section("Your account") {
                Text("Morning status uses your existing ohMyTss account, phone number, SMS consent and training data already synced from Intervals.icu. Account data is stored by the private service in Supabase.")
                Text("Your password is used to sign in over HTTPS and is not saved by this screen. The app stores the signed account session in this device's Keychain.")
            }
            Section("Morning texts") {
                Text("Twilio processes SMS delivery. Texts require opt-in and current-day wellness data, and are limited to one morning message per local day. Message and data rates may apply.")
                Text("Reply STOP to unsubscribe, START to resubscribe or HELP for help. Signing out of this device does not unsubscribe you.")
            }
            Section("Apple Health") {
                Text("This feature does not upload Apple Health data or grant the server access to it. Refreshing morning status reads your account state and does not trigger SMS delivery.")
            }
            Section("Contact") {
                Text("This is a personal project run by Mingjun Liu. For account access or data deletion, contact mingjun6@illinois.edu.")
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Data and Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
