import SwiftUI

struct MorningStatusView: View {
    @State private var model: MorningStatusViewModel
    @State private var phone = ""
    @State private var code = ""
    @State private var timezone = "UTC"
    @State private var confirmingUnsubscribe = false
    @FocusState private var focusedField: PhoneField?
    private enum PhoneField { case phone, code }

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
                    subscriptionSection(status)
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
                        Text("The morning window follows this time zone. Changing it does not send a message or reset today's delivery record.")
                    }
                    if status.smsEnabled {
                        Section {
                            Button("Turn Off Morning Texts", role: .destructive) { confirmingUnsubscribe = true }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("morning.unsubscribe")
                        }
                    }
                } else if !model.isBusy {
                    Section { Text("Your phone is connected. Refresh to load morning status.") }
                }
                Section {
                    Button("Refresh Status") { Task { await model.refresh() } }
                        .disabled(model.isBusy)
                    Button("Disconnect This Device", role: .destructive) { model.signOut(); phone = ""; code = "" }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("morning.signOut")
                } footer: {
                    Text("Disconnecting only removes this device's saved session. It does not change your SMS subscription.")
                }
            } else {
                phoneSection
            }

            if model.isBusy {
                Section { ProgressView("Loading morning status…") }
            }
            if model.isSignedIn, let error = model.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    .accessibilityIdentifier("morning.error")
            }
            Section {
                NavigationLink("Data and Privacy") { MorningStatusPrivacyView() }
                    .accessibilityIdentifier("morning.privacy")
            } footer: {
                Text("Morning status uses the Intervals.icu data linked to your phone. Apple Health data is not uploaded by this feature.")
            }
        }
        .navigationTitle("Morning Status")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if focusedField != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .task { await model.load() }
        .onChange(of: model.status?.timezone) { _, value in if let value { timezone = value } }
        .confirmationDialog("Turn off morning texts?", isPresented: $confirmingUnsubscribe, titleVisibility: .visible) {
            Button("Turn Off Texts", role: .destructive) { Task { await model.unsubscribe() } }
        } message: {
            Text("This unsubscribes your phone from SMS. To resubscribe, reply START to an existing ohMyTss message.")
        }
    }

    private var phoneSection: some View {
        Section {
            if let verification = model.verification {
                Text("Code sent · \(verification.phoneHint)")
                    .accessibilityIdentifier("morning.codeSent")
                TextField("6-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .code)
                    .accessibilityIdentifier("morning.code")
                phoneError
                Button("Verify Phone") {
                    let submittedCode = code
                    code = ""
                    focusedField = nil
                    Task { await model.verifyCode(submittedCode) }
                }
                .disabled(model.isBusy || !MorningPhoneInput.validCode(code))
                .accessibilityIdentifier("morning.verify")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = model.resendSeconds(at: context.date)
                    Button(remaining > 0 ? "Resend in \(remaining)s" : "Resend Code") {
                        code = ""
                        focusedField = nil
                        Task { await model.resendCode() }
                    }
                    .disabled(model.isBusy || remaining > 0)
                    .accessibilityIdentifier("morning.resend")
                }
                Button("Use a Different Number") { code = ""; focusedField = nil; model.changePhone() }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("morning.changePhone")
            } else {
                TextField("Phone number", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                    .accessibilityIdentifier("morning.phone")
                phoneError
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = model.resendSeconds(at: context.date)
                    Button(remaining > 0 ? "Try again in \(remaining)s" : "Send Code") {
                        focusedField = nil
                        Task { await model.requestCode(phone: phone) }
                    }
                    .disabled(model.isBusy || remaining > 0 || MorningPhoneInput.normalized(phone) == nil)
                    .accessibilityIdentifier("morning.sendCode")
                }
            }
        } header: { Text("Your phone number") } footer: {
            Text("Enter the US number linked to your morning texts. We'll send a verification code and remember this device. Message and data rates may apply. Verification does not change your SMS subscription.")
        }
    }

    @ViewBuilder
    private var phoneError: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("morning.error")
        }
    }

    private func subscriptionSection(_ status: MorningStatus) -> some View {
        Section("Morning texts") {
            LabeledContent("Phone", value: status.phoneHint ?? "Not configured")
                .accessibilityIdentifier("morning.connectedPhone")
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
            LabeledContent("Local date", value: status.localDate)
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
                Text("No wellness record for today yet.").foregroundStyle(.secondary)
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
            Section("Your phone number") {
                Text("Morning status uses your phone number, SMS consent and training data already synced from Intervals.icu. This data is stored by the private service in Supabase.")
                Text("Twilio verifies your phone with a one-time text code. Your number and code are sent over HTTPS. The app stores only your signed session in this device's Keychain, so you do not need an email or password.")
            }
            Section("Morning texts") {
                Text("Twilio processes SMS delivery. Texts require opt-in and current-day wellness data, and are limited to one morning message per local day. Message and data rates may apply.")
                Text("Reply STOP to unsubscribe, START to resubscribe or HELP for help. Disconnecting this device does not unsubscribe you.")
            }
            Section("Apple Health") {
                Text("This feature does not upload Apple Health data or grant the server access to it. Refreshing morning status does not trigger SMS delivery.")
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
