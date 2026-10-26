import SwiftUI
import SwiftData

struct MuscleSelection: Identifiable {
    let region: Region
    let side: BodySide
    var id: String { "\(region.rawValue).\(side.rawValue)" }
}

extension MuscleEffortGrade {
    var color: Color {
        switch self {
        case .easy: return .teal
        case .moderate: return .blue
        case .hard: return .orange
        case .veryHard: return .pink
        }
    }
}

struct MuscleRPECard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let workouts: [Workout]
    @Query private var records: [MuscleRPERecord]
    @Query private var sets: [StrengthSetRecord]
    @State private var selection: MuscleSelection?
    @State private var showingInfo = false

    init(workouts: [Workout], now: Date) {
        self.workouts = workouts
        let cutoff = MuscleRPESummary.cutoff(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        _records = Query(filter: #Predicate<MuscleRPERecord> { $0.observedAt >= cutoff && $0.observedAt < end },
                         sort: \.observedAt, order: .reverse)
        let ids = workouts.map(\.id)
        _sets = Query(filter: #Predicate<StrengthSetRecord> { ids.contains($0.sessionID) })
    }

    var body: some View {
        // SwiftData invalidates this view immediately after Save. Use that
        // render's time, so a new rating does not wait for the minute timer.
        let summary = MuscleRPESummary(records: records, workouts: workouts, sets: sets, now: Date())
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Muscle load").font(.title3.bold())
                    Text("Last 7 days · latest per side").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("About muscle RPE", systemImage: "info.circle") { showingInfo = true }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            BodyMapView(summary: summary) { region, side in
                selection = MuscleSelection(region: region, side: side)
            }
            if !summary.ratedRegions.isEmpty {
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                          ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 10) {
                    ForEach(summary.ratedRegions) { region in
                        Button {
                            selection = MuscleSelection(region: region, side: .both)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(region.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                ratingDetails(region, summary: summary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("muscle.summary.\(region.rawValue)")
                    }
                }
            }
        }
        .sheet(item: $selection) { selection in
            MuscleRPEEditor(selection: selection,
                            reading: selection.side == .both ? summary.latest(selection.region)
                                : summary.reading(selection.region, side: selection.side))
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("How hard did that muscle work?").font(.title2.bold())
                        Text("RPE runs from 1 (very easy) to 10 (maximum effort). The map shows the most recent rating for each side within seven days, with its date.")
                        Text("Recorded sets with RIR 0–4 provide a starting point for the muscles involved. Tap a muscle to adjust it. No rating stays gray.")
                        Text("This is perceived effort, not measured muscle force, soreness, or a recovery countdown.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
                .navigationTitle("Muscle RPE").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingInfo = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func ratingDetails(_ region: Region, summary: MuscleRPESummary) -> some View {
        let left = summary.reading(region, side: .left)
        let right = summary.reading(region, side: .right)
        if let left, let right, left.rpe == right.rpe,
           Calendar.current.isDate(left.observedAt, inSameDayAs: right.observedAt) {
            Text("\(left.grade.label) · RPE \(left.rpe)").font(.caption.weight(.semibold)).foregroundStyle(left.grade.color)
            Text(left.observedAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
        } else {
            sideRating("L", reading: left)
            sideRating("R", reading: right)
        }
    }

    private func sideRating(_ side: String, reading: MuscleRPESummary.Reading?) -> some View {
        HStack(spacing: 4) {
            Text("\(side) \(reading.map { "RPE \($0.rpe)" } ?? "—")")
                .foregroundStyle(reading?.grade.color ?? .secondary)
            if let reading {
                Text(reading.observedAt, format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

struct MuscleRPEEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: MuscleSelection
    let reading: MuscleRPESummary.Reading?
    @State private var side: BodySide
    @State private var rpe: Int?
    @State private var observedAt: Date
    @State private var error: String?

    init(selection: MuscleSelection, reading: MuscleRPESummary.Reading?) {
        self.selection = selection
        self.reading = reading
        _side = State(initialValue: selection.side)
        _rpe = State(initialValue: reading?.rpe)
        _observedAt = State(initialValue: reading?.observedAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("How hard did it work?").font(.title2.bold())
                    Picker("Side", selection: $side) {
                        Text("Left").tag(BodySide.left)
                        Text("Both").tag(BodySide.both)
                        Text("Right").tag(BodySide.right)
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("rpe.side")
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                              ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(MuscleEffortGrade.allCases) { grade in
                            let selected = rpe.flatMap(MuscleEffortGrade.init(rpe:)) == grade
                            Button {
                                if !selected { rpe = grade.defaultRPE }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(grade.label).font(.headline)
                                        Spacer(minLength: 2)
                                        if selected { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                                    }
                                    Text("RPE \(grade.rangeLabel)").font(.caption)
                                }
                                .foregroundStyle(selected ? Color.primary : .secondary)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(14)
                                .background(grade.color.opacity(selected ? 0.17 : 0.06), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(grade.color.opacity(selected ? 0.8 : 0.15), lineWidth: selected ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("rpe.grade.\(grade.rawValue)")
                        }
                    }
                    if let value = rpe {
                        Stepper(value: Binding(get: { rpe ?? value }, set: { rpe = $0 }), in: 1...10) {
                            Text("RPE \(value)").font(.headline).monospacedDigit()
                        }
                        .accessibilityIdentifier("rpe.fineTune")
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Date").font(.subheadline)
                            DatePicker("Date", selection: $observedAt, in: dateRange, displayedComponents: .date)
                                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        DatePicker("Date", selection: $observedAt, in: dateRange, displayedComponents: .date)
                            .font(.subheadline)
                    }
                    if reading?.source == .sets {
                        Text("Starting from your recorded sets.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { V2ErrorMessage(message: error) }
                    Button("Save RPE") { save() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(rpe == nil)
                        .accessibilityIdentifier("rpe.save")
                }
                .padding(24)
            }
            .navigationTitle(selection.region.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("rpe.cancel")
                }
            }
        }
        .presentationDetents([.height(570), .large])
        .presentationDragIndicator(.visible)
    }

    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let lower = MuscleRPESummary.cutoff(for: now)
        return lower...now
    }

    private func save() {
        guard let rpe else { return }
        do {
            try MuscleRPEStore(context: context).save(region: selection.region, side: side,
                                                     rpe: rpe, observedAt: min(observedAt, Date()))
            dismiss()
        } catch {
            context.rollback()
            self.error = "Could not save your rating. Try again."
        }
    }
}
