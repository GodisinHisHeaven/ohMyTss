import SwiftUI
import SwiftData

struct StrengthSessionChooser: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workout.startTime, order: .reverse) private var workouts: [Workout]
    @State private var start = Date()
    @State private var minutes = 45
    @State private var created: Workout?
    @State private var showCreated = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Supplement an existing activity") {
                    Text("Choose the original session to add sets without adding another cardio contribution.")
                        .font(.caption).foregroundStyle(.secondary)
                    let available = workouts.filter { !$0.isSuppressed && !$0.isDeleted }
                    if available.isEmpty { Text("No existing sessions").foregroundStyle(.secondary) }
                    ForEach(available) { workout in
                        NavigationLink { V2ActivityDetailView(workout: workout) } label: { V2WorkoutRow(workout: workout) }
                    }
                }
                Section("New unrecorded activity") {
                    DatePicker("Started", selection: $start, in: ...Date())
                    Stepper("Duration: \(minutes) min", value: $minutes, in: 1...600, step: 1)
                    Button("Create strength session") {
                        do {
                            created = try V2Store(context: context).createStrengthSession(start: start, duration: Double(minutes) * 60)
                            showCreated = true
                        } catch { context.rollback(); self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("strength.createSession")
                    Text("If this session imports later, link it from activity details to preserve your sets and reports.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { V2ErrorMessage(message: error) }
            }
            .navigationTitle("Strength session")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showCreated) {
                if let created { V2ActivityDetailView(workout: created) }
            }
        }
    }
}

struct StrengthSetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let existing: StrengthSetRecord?
    @State private var exerciseID: String
    @State private var reps: Int
    @State private var weight: String
    @State private var rir: String
    @State private var effort: String
    @State private var manualRegions: Set<String>
    @State private var count = 1
    @State private var choosingExercise = false
    @State private var error: String?

    init(sessionID: String, existing: StrengthSetRecord? = nil) {
        self.sessionID = sessionID
        self.existing = existing
        _exerciseID = State(initialValue: existing?.exerciseID ?? ExerciseCatalog.exercises.first?.id ?? "custom")
        _reps = State(initialValue: existing?.reps ?? 8)
        _weight = State(initialValue: existing?.weightKG.map { String($0) } ?? "")
        _rir = State(initialValue: existing?.rir.map { String($0) } ?? "")
        _effort = State(initialValue: existing?.effortRaw ?? "unknown")
        _manualRegions = State(initialValue: Set(existing?.manualRegionsRaw ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    Button { choosingExercise = true } label: {
                        HStack { Text(V2Presentation.exerciseName(exerciseID)); Spacer(); Image(systemName: "magnifyingglass") }
                    }
                    .accessibilityIdentifier("strength.exercise")
                    if let exercise = ExerciseCatalog.exercises.first(where: { $0.id == exerciseID }) {
                        Text("Typical involvement: " + exercise.regions.map(\.label).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Custom exercise: select at least one region below. This is a low-confidence user-specified model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Set details") {
                    if existing == nil { Stepper("Sets: \(count)", value: $count, in: 1...20) }
                    Stepper("Repetitions: \(reps)", value: $reps, in: 1...200)
                        .accessibilityIdentifier("strength.reps")
                    TextField("Weight in kg (optional)", text: $weight).keyboardType(.decimalPad)
                        .accessibilityIdentifier("strength.weight")
                    Text("Use external load in kilograms. Blank means unknown; 0 means no external load.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("RIR (optional, 0 = no reps left)", text: $rir).keyboardType(.numberPad)
                        .accessibilityIdentifier("strength.rir")
                    Picker("Effort if RIR unknown", selection: $effort) {
                        Text("Not recorded").tag("unknown")
                        Text("Easy").tag("easy")
                        Text("Moderate").tag("moderate")
                        Text("Hard").tag("hard")
                    }
                    Text("Repetitions in reserve (RIR) is optional. 0 is a valid report, not missing data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Additional regions you felt") {
                    ForEach(Region.allCases) { region in
                        Toggle(region.label, isOn: Binding(
                            get: { manualRegions.contains(region.rawValue) },
                            set: { selected in
                                if selected { manualRegions.insert(region.rawValue) }
                                else { manualRegions.remove(region.rawValue) }
                            }
                        ))
                    }
                    Text("Participation hints are not precise force shares. Soreness is recorded separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { V2ErrorMessage(message: error) }
                if existing != nil {
                    Section {
                        Button("Delete set", role: .destructive) {
                            do {
                                if let existing { try V2Store(context: context).deleteSet(existing) }
                                dismiss()
                            } catch { context.rollback(); self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add sets" : "Edit set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("strength.save")
                }
            }
            .sheet(isPresented: $choosingExercise) { ExercisePickerView(selection: $exerciseID) }
        }
    }

    private func save() {
        let weightText = weight.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let rirText = rir.trimmingCharacters(in: .whitespacesAndNewlines)
        let weightValue = weightText.isEmpty ? nil : Double(weightText)
        let rirValue = rirText.isEmpty ? nil : Int(rirText)
        guard weightText.isEmpty || (weightValue != nil && weightValue!.isFinite && weightValue! >= 0 && weightValue! <= 1000) else {
            error = "Enter a weight from 0 to 1000 kg, or leave it blank."; return
        }
        guard rirText.isEmpty || (rirValue != nil && (0...10).contains(rirValue!)) else {
            error = "Enter RIR from 0 to 10, or leave it blank."; return
        }
        guard exerciseID != "custom" || !manualRegions.isEmpty else {
            error = "Choose at least one region for a custom exercise."; return
        }
        do {
            var records: [StrengthSetRecord] = []
            for _ in 0..<(existing == nil ? count : 1) {
                let set = existing ?? StrengthSetRecord(sessionID: sessionID, exerciseID: exerciseID, reps: reps)
                set.exerciseID = exerciseID
                set.reps = reps
                set.weightKG = weightValue
                set.rir = rirValue
                set.effortRaw = effort == "unknown" ? nil : effort
                set.manualRegionsRaw = manualRegions.sorted()
                records.append(set)
            }
            try V2Store(context: context).saveSets(records)
            dismiss()
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}

private struct ExercisePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var search = ""
    @State private var region = "all"

    var body: some View {
        NavigationStack {
            List {
                Picker("Region", selection: $region) {
                    Text("All regions").tag("all")
                    ForEach(Region.allCases) { Text($0.label).tag($0.rawValue) }
                }
                ForEach(ExerciseCatalog.exercises.filter {
                    (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
                    (region == "all" || $0.regions.contains { $0.rawValue == region })
                }) { exercise in
                    Button {
                        selection = exercise.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(exercise.name)
                            Text(exercise.regions.map(\.label).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Custom exercise / manual regions") { selection = "custom"; dismiss() }
            }
            .searchable(text: $search, prompt: "Search exercises")
            .navigationTitle("Choose exercise")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
