import SwiftUI

struct MorningStatusView: View {
    let dataStore: DataStore
    @State private var model: MorningStatusViewModel
    @State private var phone = ""
    @State private var code = ""
    @State private var timezone = "UTC"
    @State private var confirmingUnsubscribe = false
    @State private var confirmingEnable = false
    @FocusState private var focusedField: PhoneField?
    private enum PhoneField { case phone, code }

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--morning-status-ui-fixture") {
            _model = State(initialValue: MorningStatusViewModel(api: MorningStatusUIFixture(), tokenStore: MorningSessionUIFixture()))
            return
        }
        #endif
        _model = State(initialValue: MorningStatusViewModel())
    }

    var body: some View {
        SwissForm {
            if model.isSignedIn {
                if let status = model.status {
                    subscriptionSection(status)
                    deliverySection(status)
                    appSummarySection(status)
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
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(SwissStyle.critical) }
                    .accessibilityIdentifier("morning.error")
            }
            Section {
                NavigationLink("Data and Privacy") { MorningStatusPrivacyView() }
                    .accessibilityIdentifier("morning.privacy")
            } footer: {
                Text("Use your app's latest summary for morning texts. No email, password or Intervals.icu account is required.")
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
        .alert("Enable morning texts with your app summary?", isPresented: $confirmingEnable) {
            Button("Cancel", role: .cancel) { }
            Button("Enable Morning Texts") {
                Task {
                    await model.enableAppMorning(timezone: TimeZone.current.identifier)
                    if model.status?.canUploadSummary == true { await syncAppSummary() }
                }
            }
        } message: {
            Text("Share your latest readiness score, sleep duration and seven-day training minutes with ohMyTss for up to one morning text per day. Message and data rates may apply. Reply STOP to unsubscribe or HELP for help. Uses this device's time zone.")
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
                .swissAction(prominent: true)
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
                    .swissAction(prominent: true)
                    .accessibilityIdentifier("morning.sendCode")
                }
            }
        } header: { Text("Your phone number") } footer: {
            Text("Enter your US phone number. We'll send a code and remember this device. Verifying connects your number under our Data and Privacy terms; it does not subscribe you or share training data. Message and data rates may apply.")
        }
    }

    @ViewBuilder
    private var phoneError: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(SwissStyle.critical)
                .accessibilityIdentifier("morning.error")
        }
    }

    private func subscriptionSection(_ status: MorningStatus) -> some View {
        Section("Morning texts") {
            LabeledContent("Phone", value: status.phoneHint ?? "Not configured")
                .accessibilityIdentifier("morning.connectedPhone")
            LabeledContent("SMS", value: status.subscriptionLabel)
                .accessibilityIdentifier("morning.subscription")
            if status.requiresSmsRestart == true {
                Text("If your phone is already linked, reply START to an existing ohMyTss text to resubscribe. Reply STOP at any time to unsubscribe.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !status.canUploadSummary {
                Button(status.smsEnabled ? "Use App Summary" : "Enable Morning Texts") { confirmingEnable = true }
                    .swissAction(prominent: true)
                    .disabled(model.isBusy || status.smsState == "paused")
                    .accessibilityIdentifier("morning.enable")
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
            LabeledContent("App summary date", value: status.wellnessThrough ?? "No data yet")
            if status.syncFailures > 0 {
                Label("The last data sync did not complete. Scheduled sync will retry.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SwissStyle.caution)
            }
        } header: { Text("Today's delivery") } footer: {
            Text("Up to one morning text per local day, between 06:00 and 10:30, after current-day data is available. Refreshing this screen does not send a text.")
        }
    }

    private func appSummarySection(_ status: MorningStatus) -> some View {
        Section {
            if let summary = status.appSummary {
                LabeledContent("Readiness", value: summary.readinessScore.map { "\($0)/100" } ?? "Not available")
                LabeledContent("Sleep", value: measurement(summary.sleepHours, unit: "hours"))
                LabeledContent("Last 7 days", value: "\(summary.trainingMinutes7d) min of training")
            } else {
                Text("No app summary for today yet.").foregroundStyle(.secondary)
            }
            if status.canUploadSummary {
                Button("Sync App Summary") { Task { await syncAppSummary() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("morning.syncSummary")
            }
        } header: { Text("Today's app summary") } footer: {
            Text("Open and sync the app in the morning. Summaries update while the app is active; iOS may not refresh data while it is closed. Only the latest summary is stored, and syncing does not send a text immediately.")
        }
    }

    private func syncAppSummary() async {
        guard let status = model.status, status.canUploadSummary else { return }
        do {
            guard let summary = try MorningAppSummary.make(store: dataStore, timezone: status.timezone) else {
                model.notice = "Sync today's training on Today first, and use this device's time zone for morning delivery."
                return
            }
            await model.syncSummary(summary)
        } catch {
            model.errorMessage = "Unable to prepare your app summary. Your saved training data has not changed."
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
        SwissList {
            ForEach(timezones, id: \.self) { identifier in
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
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or time zone")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MorningStatusPrivacyView: View {
    var body: some View {
        SwissList {
            Section("Your phone number") {
                Text("Morning status uses your verified phone number. No email, password or Intervals.icu account is needed. Verification creates a private connection but does not enable texts or upload training data.")
                Text("Twilio verifies your phone with a one-time text code. Your number and code are sent over HTTPS. The app stores only your signed session in this device's Keychain, so you do not need an email or password.")
            }
            Section("Morning texts") {
                Text("When you enable app summaries, ohMyTss stores only your latest readiness score, sleep duration and seven-day training minutes in its private Supabase service. No raw HealthKit samples, workout routes or muscle notes are uploaded. Morning texts use only app summaries. Historical service records are not used for delivery.")
                Text("Twilio processes SMS delivery and receives the text summary. Texts require opt-in and a current-day summary, and are limited to one morning message per local day. Message and data rates may apply.")
                Text("Reply STOP to unsubscribe, START to resubscribe or HELP for help. Disconnecting this device does not unsubscribe you.")
            }
            Section("Apple Health") {
                Text("HealthKit calculations happen on your device. Only the three summary values described above are shared after you enable morning texts. Turning texts off stops future summary uploads; disconnecting removes this device's session. Refreshing status does not trigger SMS delivery.")
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
