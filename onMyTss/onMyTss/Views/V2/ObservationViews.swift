import SwiftUI
import SwiftData

struct ObservationEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let existing: LocalObservation?
    let sessionID: String?
    @State private var region: Region
    @State private var side: String
    @State private var kind: String
    @State private var severity: Int
    @State private var observedAt: Date
    @State private var weakness: Bool
    @State private var tightness: Bool
    @State private var limitedMovement: Bool
    @State private var note: String
    @State private var error: String?

    init(region: Region = .quads, existing: LocalObservation? = nil, sessionID: String? = nil) {
        self.existing = existing
        self.sessionID = sessionID ?? existing?.sessionID
        _region = State(initialValue: existing.flatMap { Region(rawValue: $0.regionRaw) } ?? region)
        _side = State(initialValue: existing?.sideRaw ?? "both")
        _kind = State(initialValue: existing?.discomfortRaw ?? "soreness")
        _severity = State(initialValue: existing == nil ? 1 : (existing?.severity ?? -1))
        _observedAt = State(initialValue: existing?.observedAt ?? Date())
        _weakness = State(initialValue: existing?.weakness ?? false)
        _tightness = State(initialValue: existing?.tightness ?? false)
        _limitedMovement = State(initialValue: existing?.limitedMovement ?? false)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your report") {
                    Picker("Region", selection: $region) {
                        ForEach(Region.allCases) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("feedback.region")
                    Picker("Side", selection: $side) {
                        Text("Both / centre").tag("both")
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("feedback.side")
                    Picker("Discomfort", selection: $kind) {
                        Text("Soreness").tag("soreness")
                        Text("Sharp pain").tag("sharpPain")
                        Text("Joint pain").tag("jointPain")
                        Text("Other").tag("other")
                        Text("No noticeable discomfort").tag("none")
                    }
                    if kind != "none" {
                        Picker("Severity", selection: $severity) {
                            Text("Not recorded").tag(-1)
                            Text("None (0)").tag(0)
                            Text("Mild (1)").tag(1)
                            Text("Moderate (2)").tag(2)
                            Text("Strong (3)").tag(3)
                            Text("Severe (4)").tag(4)
                        }
                        .accessibilityIdentifier("feedback.severity")
                        Toggle("Weakness", isOn: $weakness)
                        Toggle("Tightness", isOn: $tightness)
                        Toggle("Limited movement", isOn: $limitedMovement)
                    }
                    Button("No noticeable discomfort") { save(noDiscomfort: true) }
                        .accessibilityIdentifier("feedback.none")
                }
                Section("When did you feel this?") {
                    DatePicker("Observed", selection: $observedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    TextField("Optional note", text: $note, axis: .vertical)
                    Text("Recorded time is saved separately. Backdated reports stay backdated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Your report is separate from estimated training burden. Recovery time cannot yet be estimated. Less soreness does not establish tissue repair or readiness for hard training.")
                        .font(.caption).foregroundStyle(.secondary)
                    if kind == "sharpPain" || kind == "jointPain" {
                        Text("This is recorded as a distinct discomfort type and is not used as a soreness recovery label.")
                            .font(.caption)
                    }
                    if let error { V2ErrorMessage(message: error) }
                }
                if existing != nil {
                    Section {
                        Button("Delete report", role: .destructive) {
                            do {
                                if let existing { try V2Store(context: context).deleteObservation(existing) }
                                dismiss()
                            } catch { context.rollback(); self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "How does it feel?" : "Edit report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(existing == nil ? "Skip" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("feedback.skip")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(noDiscomfort: false) }
                        .accessibilityIdentifier("feedback.save")
                }
            }
        }
    }

    private func save(noDiscomfort: Bool) {
        let report = existing ?? LocalObservation(regionRaw: region.rawValue, sessionID: sessionID)
        report.regionRaw = region.rawValue
        report.sideRaw = side
        let isNone = noDiscomfort || kind == "none"
        report.discomfortRaw = isNone ? "none" : kind
        report.severity = isNone ? 0 : (severity < 0 ? nil : severity)
        report.observedAt = observedAt
        report.weakness = isNone ? false : weakness
        report.tightness = isNone ? false : tightness
        report.limitedMovement = isNone ? false : limitedMovement
        report.note = note
        do {
            try V2Store(context: context).saveObservation(report)
            dismiss()
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}

struct ObservationHistoryView: View {
    @Query(sort: \LocalObservation.observedAt, order: .reverse) private var observations: [LocalObservation]
    @State private var editing: LocalObservation?
    @State private var adding = false

    var body: some View {
        List {
            if observations.isEmpty {
                ContentUnavailableView("No reports yet", systemImage: "figure.stand", description: Text("Unreported is different from no discomfort. Add a report whenever useful."))
            }
            ForEach(observations) { observation in
                Button { editing = observation } label: { V2ObservationRow(observation: observation) }
                    .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Your reports")
        .toolbar { Button("Add report", systemImage: "plus") { adding = true } }
        .sheet(item: $editing) { ObservationEditor(existing: $0) }
        .sheet(isPresented: $adding) { ObservationEditor() }
    }
}
