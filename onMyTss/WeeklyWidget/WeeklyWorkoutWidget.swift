import SwiftUI
import WidgetKit

private struct WeeklyWorkoutEntry: TimelineEntry {
    let date: Date
    let snapshot: WeeklyWorkoutSnapshot?
}

private struct WeeklyWorkoutProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeeklyWorkoutEntry {
        let now = Date()
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return WeeklyWorkoutEntry(date: now, snapshot: nil)
        }
        let sample = ["Run", "Ride", "Strength", "Swim", "Run"]
        let records = sample.enumerated().compactMap { index, type -> WeeklyWorkoutRecord? in
            guard let day = calendar.date(byAdding: .day, value: index, to: week.start) else { return nil }
            return WeeklyWorkoutRecord(date: day, workoutType: type)
        }
        return WeeklyWorkoutEntry(date: now, snapshot: WeeklyWorkoutSnapshot(
            weekStart: week.start, weekEnd: week.end, generatedAt: now, records: records
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (WeeklyWorkoutEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : WeeklyWorkoutEntry(date: .now, snapshot: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeeklyWorkoutEntry>) -> Void) {
        let now = Date()
        let snapshot = WeeklyWorkoutSnapshot.load()
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
            ?? now.addingTimeInterval(3600)
        // The second entry switches the highlighted day even if a reload is delayed.
        completion(Timeline(entries: [
            WeeklyWorkoutEntry(date: now, snapshot: snapshot),
            WeeklyWorkoutEntry(date: nextDay, snapshot: snapshot)
        ], policy: .after(nextDay)))
    }
}

private struct Activity: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let color: Color

    init(type: String) {
        let value = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch WeeklyWorkoutCategory(type: type) {
        case .running:
            (id, label, symbol, color) = ("run", "Running", "figure.run", Color(red: 0.25, green: 0.46, blue: 0.59))
        case .cycling:
            (id, label, symbol, color) = ("cycle", "Cycling", "figure.outdoor.cycle", Color(red: 0.36, green: 0.49, blue: 0.37))
        case .swimming:
            (id, label, symbol, color) = ("swim", "Swimming", "figure.pool.swim", Color(red: 0.25, green: 0.46, blue: 0.59))
        case .strength:
            (id, label, symbol, color) = ("strength", "Strength", "dumbbell", Color(red: 0.72, green: 0.43, blue: 0.34))
        case .walking:
            (id, label, symbol, color) = ("walk", "Walking", "figure.walk", Color(red: 0.48, green: 0.52, blue: 0.41))
        case .other:
            (id, label, symbol, color) = ("other:" + value, type.isEmpty ? "Workout" : type, "figure.mixed.cardio", Color(red: 0.46, green: 0.46, blue: 0.48))
        }
    }
}

private struct WorkoutDay: Identifiable {
    let date: Date
    let isToday: Bool
    let isFuture: Bool
    let isCovered: Bool
    let activities: [Activity]
    var id: Date { date }

    var accessibilityDescription: String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let status: String
        if !isCovered { status = "Not synced" }
        else if activities.isEmpty { status = isFuture ? "Upcoming" : "No workouts" }
        else { status = activities.map(\.label).joined(separator: ", ") }
        return "\(day), \(status)\(isToday ? ", today" : "")"
    }
}

private struct WeeklyWorkoutView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeeklyWorkoutEntry

    private var days: [WorkoutDay] {
        let calendar = Calendar.current
        guard let week = calendar.dateInterval(of: .weekOfYear, for: entry.date) else { return [] }
        // Matching the whole interval prevents stale results after a timezone or first-weekday change.
        let snapshot = entry.snapshot.flatMap { $0.weekStart == week.start && $0.weekEnd == week.end ? $0 : nil }
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            var seen = Set<String>()
            let activities = (snapshot?.records ?? [])
                .filter { calendar.isDate($0.date, inSameDayAs: date) }
                .sorted { $0.date < $1.date }
                .map { Activity(type: $0.workoutType) }
                .filter { seen.insert($0.id).inserted }
            return WorkoutDay(date: date, isToday: calendar.isDate(date, inSameDayAs: entry.date),
                              isFuture: date > calendar.startOfDay(for: entry.date),
                              isCovered: snapshot?.covers(day: date, asOf: entry.date, calendar: calendar) ?? false,
                              activities: activities)
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            strip(compact: true)
        default:
            home
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack {
                Text("This week").font(.system(.headline, design: .rounded))
                Spacer(minLength: 0)
                if days.contains(where: { !$0.isCovered }) {
                    Text("Open app to sync").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            strip(compact: false)
        }
        .foregroundStyle(Color(red: 0.22, green: 0.23, blue: 0.25))
    }

    private func strip(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: compact ? 3 : 7) {
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: compact ? 9 : 11, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(.secondary)
                    dayContents(day, compact: compact)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if day.isToday {
                        RoundedRectangle(cornerRadius: compact ? 5 : 9)
                            .fill(.primary.opacity(compact ? 0.12 : 0.055))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.accessibilityDescription)
            }
        }
    }

    @ViewBuilder
    private func dayContents(_ day: WorkoutDay, compact: Bool) -> some View {
        if !day.isCovered {
            Text("–").font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary)
        } else if day.activities.isEmpty {
            if day.isFuture {
                Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Circle().fill(.secondary.opacity(0.5)).frame(width: 4, height: 4)
            }
        } else {
            let limit = compact ? 1 : 2
            VStack(spacing: compact ? 0 : 2) {
                ForEach(Array(day.activities.prefix(limit))) { activity in
                    Image(systemName: activity.symbol)
                        .font(.system(size: compact ? 12 : (family == .systemSmall ? 13 : 17), weight: .medium))
                        .foregroundStyle(compact ? Color.primary : activity.color)
                }
                if day.activities.count > limit {
                    Text("+\(day.activities.count - limit)")
                        .font(.system(size: compact ? 8 : 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inline: some View {
        let content = days.reduce(Text("Week ")) { text, day in
            let mark: Text
            if !day.isCovered { mark = Text("–") }
            else if let first = day.activities.first {
                mark = Text(Image(systemName: first.symbol)) + (day.activities.count > 1 ? Text("+") : Text(""))
            } else { mark = Text("·") }
            return text + mark + Text(" ")
        }
        return content
            .accessibilityLabel(days.map(\.accessibilityDescription).joined(separator: "; "))
    }
}

@main
struct WeeklyWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WeeklyWorkoutSnapshot.kind, provider: WeeklyWorkoutProvider()) { entry in
            WeeklyWorkoutView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.97, green: 0.96, blue: 0.94)
                }
        }
        .configurationDisplayName("Weekly workouts")
        .description("See each day's workout types at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
