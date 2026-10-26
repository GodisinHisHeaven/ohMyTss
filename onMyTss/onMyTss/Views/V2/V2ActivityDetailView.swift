import SwiftUI
import SwiftData

struct V2ActivityDetailView: View {
    let workout: Workout
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StrengthSetRecord.recordedAt) private var allSets: [StrengthSetRecord]
    @Query(sort: \LoadEstimateRecord.computedAt, order: .reverse) private var estimates: [LoadEstimateRecord]
    @Query(sort: \LocalObservation.observedAt, order: .reverse) private var observations: [LocalObservation]
    @Query(sort: \StrengthTemplate.name) private var templates: [StrengthTemplate]
    @Query private var workouts: [Workout]
    @State private var editingSet: StrengthSetRecord?
    @State private var addSet = false
    @State private var addReport = false
    @State private var linkSession = false
    @State private var templateName = ""
    @State private var namingTemplate = false
    @State private var confirmDelete = false
    @State private var tags: Set<String>
    @State private var error: String?

    init(workout: Workout) {
        self.workout = workout
        _tags = State(initialValue: Set(workout.userTags))
    }

    private var sets: [StrengthSetRecord] { allSets.filter { $0.sessionID == workout.id } }
    private var revisions: [LoadEstimateRecord] { estimates.filter { $0.sessionID == workout.id } }
    private var latest: LoadEstimateValue? { revisions.first?.value }
    private var isActive: Bool { !workout.isSuppressed && !workout.isTombstoned }
    private var isSwim: Bool { workout.workoutType.lowercased().contains("swim") }
    private var isRide: Bool {
        let type = workout.workoutType.lowercased()
        return type.contains("cycl") || type.contains("ride") || type.contains("bike")
    }

    var body: some View {
        List {
            if workout.isSuppressed || workout.isTombstoned {
                Section("Archived or linked activity") {
                    Text("This record no longer contributes separately.")
                    if let targetID = workout.linkedSessionID, let target = workouts.first(where: { $0.id == targetID && !$0.isTombstoned }) {
                        NavigationLink("Open linked activity") { V2ActivityDetailView(workout: target) }
                    }
                }
            }
            Section("Activity") {
                V2WorkoutRow(workout: workout)
                Text("Legacy TSS: \(workout.tss, specifier: "%.1f") · \(workout.calculationMethod)")
                    .font(.caption).foregroundStyle(.secondary)
                if let original = workout.legacyTSS {
                    Text("Preserved original TSS: \(original, specifier: "%.1f") · \(workout.legacyCalculationMethod ?? "legacy")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("TSS, Cardio Load and regional proxies have different meanings and are not added together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Latest estimate") {
                if let latest { V2EstimateView(estimate: latest) }
                else { Text("No v2 estimate yet. Recalculate to use the available inputs.").foregroundStyle(.secondary) }
                if isActive {
                    Button("Recalculate using current inputs") { recalculate() }
                        .accessibilityIdentifier("activity.recalculate")
                    Text("Recalculation adds a versioned result and keeps prior estimates, reports and sets.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Archived estimate, excluded from current totals.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isActive && !workout.userTags.isEmpty {
                Section("Saved activity details") {
                    Text(workout.userTags.joined(separator: ", "))
                }
            }
            if isActive && (isSwim || isRide) {
                Section("Your activity details") {
                    if isSwim {
                        Text("Unknown unless selected. Imported stroke segments remain separate from these whole-session labels.")
                            .font(.caption).foregroundStyle(.secondary)
                        tag("Hand paddles", raw: "paddles")
                        tag("Fins", raw: "fins")
                        tag("Pull buoy", raw: "pull_buoy")
                        tag("Kick drill", raw: "kick_drill")
                        Picker("Whole-session stroke", selection: singleTagBinding(["freestyle", "backstroke", "breaststroke", "butterfly"])) {
                            Text("Unknown / mixed").tag("")
                            Text("Freestyle").tag("freestyle")
                            Text("Backstroke").tag("backstroke")
                            Text("Breaststroke").tag("breaststroke")
                            Text("Butterfly").tag("butterfly")
                        }
                    }
                    if isRide {
                        Picker("Reported riding posture", selection: singleTagBinding(["seated", "standing"])) {
                            Text("Unknown / mixed").tag("")
                            Text("Mostly seated").tag("seated")
                            Text("Mostly standing").tag("standing")
                        }
                        Text("This is your label, not a sensor measurement. Unknown posture is not inferred.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save details and recalculate") {
                        workout.userTags = tags.sorted()
                        recalculate()
                    }
                    .accessibilityIdentifier("activity.saveTags")
                    .disabled(workout.isSuppressed || workout.isTombstoned)
                }
            }
            Section("Strength sets") {
                Text(isActive ? "Adding details supplements this session. It does not add its imported cardio contribution again." : "Retained strength log; excluded from current totals.")
                    .font(.caption).foregroundStyle(.secondary)
                if sets.isEmpty { Text("No sets recorded").foregroundStyle(.secondary) }
                ForEach(sets) { set in
                    Button { editingSet = set } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(V2Presentation.exerciseName(set.exerciseID)).font(.headline)
                            Text(setDescription(set)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                    .disabled(workout.isSuppressed || workout.isTombstoned)
                }
                if isActive {
                    Button("Add sets", systemImage: "plus") { addSet = true }
                        .accessibilityIdentifier("activity.addSets")
                }
                if isActive && !sets.isEmpty {
                    Button("Save these sets as a template") { namingTemplate = true }
                }
                if !templates.isEmpty && !workout.isSuppressed && !workout.isTombstoned {
                    Menu("Use a saved template") {
                        ForEach(templates) { template in
                            Button(template.name) {
                                do { try V2Store(context: context).applyTemplate(template, to: workout) }
                                catch { context.rollback(); self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Section("Your reports") {
                if isActive { Button("Record a regional report") { addReport = true } }
                ForEach(observations.filter { $0.sessionID == workout.id }) { report in
                    V2ObservationRow(observation: report)
                }
                if isActive { NavigationLink("View and edit report history") { ObservationHistoryView() } }
            }
            if workout.source == "manual" && !workout.isSuppressed && !workout.isTombstoned {
                Section("Already imported elsewhere?") {
                    Button("Link to an imported activity") { linkSession = true }
                    Text("Moves these details to the chosen session, preserving your sets and reports and leaving one contribution.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if revisions.count > 1 {
                Section("Estimate history") {
                    ForEach(Array(revisions.dropFirst())) { revision in
                        DisclosureGroup("\(revision.version) · \(revision.computedAt.formatted(date: .abbreviated, time: .shortened))") {
                            if let value = revision.value { V2EstimateView(estimate: value) }
                        }
                    }
                }
            }
            Section {
                Text("Recovery time is not yet estimable. Regional burden is not measured tissue damage or injury risk.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { V2ErrorMessage(message: error) }
                if isActive {
                    Button("Remove activity from totals", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(workout.workoutType)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addSet) { StrengthSetEditor(sessionID: workout.id) }
        .sheet(item: $editingSet) { StrengthSetEditor(sessionID: workout.id, existing: $0) }
        .sheet(isPresented: $addReport) { ObservationEditor(sessionID: workout.id) }
        .sheet(isPresented: $linkSession) { LinkSessionView(manual: workout) }
        .alert("Template name", isPresented: $namingTemplate) {
            TextField("Name", text: $templateName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do {
                    try V2Store(context: context).saveTemplate(name: templateName, sets: sets)
                    templateName = ""
                } catch { context.rollback(); self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Remove this activity from totals? Your reports and recorded sets are retained.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove activity", role: .destructive) {
                Task {
                    do { try await V2Store(context: context).deleteSession(workout); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func tag(_ label: String, raw: String) -> some View {
        Toggle(label, isOn: Binding(get: { tags.contains(raw) }, set: { selected in
            if selected { tags.insert(raw) } else { tags.remove(raw) }
        }))
    }

    private func singleTagBinding(_ options: [String]) -> Binding<String> {
        Binding(get: { options.first(where: { tags.contains($0) }) ?? "" }, set: { newValue in
            for option in options { tags.remove(option) }
            if !newValue.isEmpty { tags.insert(newValue) }
        })
    }

    private func recalculate() {
        do { try V2Store(context: context).recalculate(workout); error = nil }
        catch { context.rollback(); self.error = error.localizedDescription }
    }

    private func setDescription(_ set: StrengthSetRecord) -> String {
        let weight = set.weightKG.map { String(format: "%.1f kg", $0) } ?? "Weight unknown"
        let effort = set.rir.map { "RIR \($0)" } ?? set.effortRaw?.capitalized ?? "Effort unknown"
        return "\(set.reps) reps · \(weight) · \(effort)"
    }
}

private struct LinkSessionView: View {
    let manual: Workout
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Text("Select the imported record for this same session. Dates and durations help you check the match.")
                    .font(.caption).foregroundStyle(.secondary)
                let candidates = workouts.filter { $0.source != "manual" && !$0.isSuppressed && !$0.isTombstoned }
                if candidates.isEmpty { Text("No imported activities available. Sync first, then return here.") }
                ForEach(candidates) { candidate in
                    Button {
                        do {
                            try V2Store(context: context).linkSession(manual: manual, to: candidate)
                            dismiss()
                        } catch { context.rollback(); self.error = error.localizedDescription }
                    } label: { V2WorkoutRow(workout: candidate) }.foregroundStyle(.primary)
                }
                if let error { V2ErrorMessage(message: error) }
            }
            .navigationTitle("Link same session")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
