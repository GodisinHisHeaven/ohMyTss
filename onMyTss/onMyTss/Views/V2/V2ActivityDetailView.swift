import SwiftUI
import SwiftData

@MainActor
enum V2ActivityDetailProjection {
    static func linkMetadata() -> FetchDescriptor<Workout> {
        // Keep every possible target observable when a manual link changes,
        // without loading any workout's sensor payload into the detail query.
        var descriptor = FetchDescriptor<Workout>()
        descriptor.propertiesToFetch = [\.id, \.linkedSessionID, \.isSuppressed, \.isTombstoned,
                                       \.deletionOrigin, \.userTags, \.workoutType, \.source]
        return descriptor
    }

    static func sets(sessionIDs: [String]) -> FetchDescriptor<StrengthSetRecord> {
        FetchDescriptor(predicate: #Predicate { sessionIDs.contains($0.sessionID) },
                        sortBy: [SortDescriptor(\.recordedAt)])
    }

    static func reports(sessionIDs: [String]) -> FetchDescriptor<LocalObservation> {
        FetchDescriptor(predicate: #Predicate {
            if let sessionID = $0.sessionID { sessionIDs.contains(sessionID) } else { false }
        },
                        sortBy: [SortDescriptor(\.observedAt, order: .reverse)])
    }

    static func revisions(sessionID: String) -> FetchDescriptor<LoadEstimateRecord> {
        var descriptor = FetchDescriptor<LoadEstimateRecord>(predicate: #Predicate { $0.sessionID == sessionID },
                            sortBy: [SortDescriptor(\.computedAt, order: .reverse)])
        // The UI displays results, never the archived sensor input stream.
        descriptor.propertiesToFetch = [\.id, \.sessionID, \.version, \.computedAt, \.payloadData]
        return descriptor
    }

    /// A source deletion retains personal details; a user deletion cuts the link.
    static func linkedSources(for workout: Workout, in workouts: [Workout]) -> [Workout] {
        guard !workout.isSuppressed && !workout.isTombstoned else { return [] }
        let links = workouts.compactMap { source -> WorkoutLinkGraph.Link? in
            guard (!source.isTombstoned || source.deletionOrigin == "source"),
                  let parentID = source.linkedSessionID else { return nil }
            return .init(id: source.id, parentID: parentID)
        }
        let ids = WorkoutLinkGraph(links).relatedIDs(to: workout.id)
        guard ids.count > 1 else { return [] }
        return workouts.filter { $0.id != workout.id && ids.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

struct V2ActivityDetailView: View {
    let workout: Workout
    @Query private var candidates: [Workout]

    init(workout: Workout) {
        self.workout = workout
        _candidates = Query(V2ActivityDetailProjection.linkMetadata())
    }

    var body: some View {
        V2ActivityDetailContent(workout: workout,
            linked: V2ActivityDetailProjection.linkedSources(for: workout, in: candidates),
            linkedTarget: candidates.first { $0.id == workout.linkedSessionID && !$0.isTombstoned })
    }
}

private struct V2ActivityDetailContent: View {
    let workout: Workout
    let linked: [Workout]
    let linkedTarget: Workout?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allSets: [StrengthSetRecord]
    @Query private var estimates: [LoadEstimateRecord]
    @Query private var observations: [LocalObservation]
    @Query(sort: \StrengthTemplate.name) private var templates: [StrengthTemplate]
    @State private var editingSet: StrengthSetRecord?
    @State private var addSet = false
    @State private var addReport = false
    @State private var linkSession = false
    @State private var templateName = ""
    @State private var namingTemplate = false
    @State private var confirmDelete = false
    @State private var tags: Set<String>
    @State private var error: String?

    init(workout: Workout, linked: [Workout], linkedTarget: Workout?) {
        self.workout = workout
        self.linked = linked
        self.linkedTarget = linkedTarget
        let ids = [workout.id] + linked.map(\.id)
        _allSets = Query(V2ActivityDetailProjection.sets(sessionIDs: ids))
        _observations = Query(V2ActivityDetailProjection.reports(sessionIDs: ids))
        _estimates = Query(V2ActivityDetailProjection.revisions(sessionID: workout.id))
        _tags = State(initialValue: Set(workout.userTags))
    }

    private var sets: [StrengthSetRecord] { allSets.filter { $0.sessionID == workout.id } }
    private var revisions: [LoadEstimateRecord] { estimates.filter { $0.sessionID == workout.id } }
    private var isActive: Bool { !workout.isSuppressed && !workout.isTombstoned }
    private var isSwim: Bool { workout.workoutType.lowercased().contains("swim") }
    private var isRide: Bool {
        let type = workout.workoutType.lowercased()
        return type.contains("cycl") || type.contains("ride") || type.contains("bike")
    }

    var body: some View {
        let displayedSets = sets
        let displayedRevisions = revisions
        let latest = displayedRevisions.first?.value
        let linkedIDs = Set(linked.map(\.id))
        let linkedSets = linkedIDs.isEmpty ? [] : allSets.filter { linkedIDs.contains($0.sessionID) }
        let linkedReports = linkedIDs.isEmpty ? [] : observations.filter { $0.sessionID.map { linkedIDs.contains($0) } == true }
        SwissList {
            if workout.isSuppressed || workout.isTombstoned {
                Section("Archived or linked activity") {
                    Text("This record no longer contributes separately.")
                    if let target = linkedTarget {
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
            if linked.contains(where: { !$0.userTags.isEmpty }) {
                Section("Details from linked sources") {
                    Text("These details stay with their original records. Changes above affect only this activity record.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(linked.filter { !$0.userTags.isEmpty }) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(source.workoutType) · \(source.source)").font(.caption).foregroundStyle(.secondary)
                            Text(source.userTags.joined(separator: ", "))
                        }
                        .accessibilityIdentifier("activity.linkedTags")
                    }
                }
            }
            Section("Strength sets") {
                Text(isActive ? "Adding details supplements this session. It does not add its imported cardio contribution again." : "Retained strength log; excluded from current totals.")
                    .font(.caption).foregroundStyle(.secondary)
                if displayedSets.isEmpty && linkedSets.isEmpty { Text("No sets recorded").foregroundStyle(.secondary) }
                ForEach(displayedSets) { set in
                    Button { editingSet = set } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(V2Presentation.exerciseName(set.exerciseID)).font(.headline)
                            Text(setDescription(set)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(.primary)
                    .accessibilityIdentifier("activity.ownSet")
                    .disabled(workout.isSuppressed || workout.isTombstoned)
                }
                if !linkedSets.isEmpty {
                    Text("Sets from linked sources are shown here but cannot be edited here yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(linkedSets) { set in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(V2Presentation.exerciseName(set.exerciseID)).font(.headline)
                            Text(setDescription(set)).font(.caption)
                            Text("Linked source · view only").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("activity.linkedSet")
                    }
                }
                if isActive {
                    Button("Add sets", systemImage: "plus") { addSet = true }
                        .accessibilityIdentifier("activity.addSets")
                }
                if isActive && !displayedSets.isEmpty {
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
                if !linkedReports.isEmpty {
                    Text("Reports from linked sources retain their original activity. Edit them in report history.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(linkedReports) { report in
                        V2ObservationRow(observation: report)
                            .accessibilityIdentifier("activity.linkedReport")
                    }
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
            if displayedRevisions.count > 1 {
                Section("Estimate history") {
                    ForEach(Array(displayedRevisions.dropFirst())) { revision in
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
    @Query(WorkoutListQuery.orderedMetadata) private var workouts: [Workout]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SwissList {
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
