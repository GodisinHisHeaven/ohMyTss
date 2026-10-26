import SwiftUI

struct BodyMapView: View {
    let summary: MuscleRPESummary
    var onSelect: (Region, BodySide) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var back = false
    @State private var selectedZone: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Body view", selection: $back) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("bodyMap.face")
            .onChange(of: back) { selectedZone = nil }

            figure(summary)
                .frame(height: 350)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
                        }
                }

            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { legend }
                } else {
                    HStack(alignment: .top, spacing: 12) { legend }
                }
                Text("Gray = not rated. Tap a muscle to adjust.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("All muscles") {
                VStack(spacing: 0) {
                    ForEach(Region.allCases) { region in
                        Button { onSelect(region, .both) } label: {
                            HStack(spacing: 12) {
                                Text(region.label).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bodyMap.list.\(region.rawValue)")
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
            .tint(.primary)
        }
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: selectedZone)
    }

    private var neutral: Color {
        colorScheme == .dark ? Color(red: 0.36, green: 0.46, blue: 0.49) : Color(red: 0.68, green: 0.77, blue: 0.79)
    }

    @ViewBuilder private var legend: some View {
        ForEach(MuscleEffortGrade.allCases) { grade in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle().fill(grade.color).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(grade.label).foregroundStyle(.secondary)
            }
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ summary: MuscleRPESummary) -> some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.height - 16) / BodyMapArtwork.size.height,
                            geometry.size.width / BodyMapArtwork.size.width)
            let size = CGSize(width: BodyMapArtwork.size.width * scale, height: BodyMapArtwork.size.height * scale)
            let origin = CGPoint(x: (geometry.size.width - size.width) / 2, y: 8)
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Color.teal.opacity(0.05), .clear],
                               center: .center, startRadius: 20, endRadius: 190)
                    .allowsHitTesting(false)
                Text(back ? "BACK" : "FRONT")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.6).foregroundStyle(.tertiary)
                    .padding(16)
                    .accessibilityHidden(true)

                BodyMapPath(path: BodyMapArtwork.silhouette)
                    .fill(LinearGradient(colors: [neutral.opacity(0.20), neutral.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        BodyMapPath(path: BodyMapArtwork.silhouette)
                            .stroke(neutral.opacity(0.38), lineWidth: 0.8)
                    }
                    .frame(width: size.width, height: size.height)
                    .offset(x: origin.x, y: origin.y)
                    .accessibilityHidden(true)

                ForEach(BodyMapArtwork.zones(back: back)) { zone in
                    zoneButton(zone, summary: summary, scale: scale)
                        .position(x: origin.x + zone.bounds.midX * scale,
                                  y: origin.y + zone.bounds.midY * scale)
                }

                BodyMapPath(path: BodyMapArtwork.contours(back: back))
                    .stroke(neutral.opacity(0.55), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    .frame(width: size.width, height: size.height)
                    .offset(x: origin.x, y: origin.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                sideBadge(back ? "L" : "R")
                    .position(x: origin.x + 53 * scale, y: 46)
                sideBadge(back ? "R" : "L")
                    .position(x: origin.x + 187 * scale, y: 46)
            }
        }
    }

    private func sideBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 23, height: 23)
            .background(Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func zoneButton(_ zone: BodyMapArtwork.Zone, summary: MuscleRPESummary, scale: CGFloat) -> some View {
        let reading = summary.reading(zone.region, side: zone.side)
        let tint = reading?.grade.color ?? neutral
        let outline = reading == nil
            ? (colorScheme == .dark ? Color(red: 0.52, green: 0.65, blue: 0.68) : Color(red: 0.43, green: 0.56, blue: 0.59))
            : tint
        let selected = selectedZone == zone.id
        let shape = BodyMapPath(path: zone.outline, sourceBounds: zone.bounds)
        let width = zone.bounds.width * scale
        let height = zone.bounds.height * scale
        return Button {
            selectedZone = zone.id
            onSelect(zone.region, zone.side)
        } label: {
            shape
                .fill(LinearGradient(colors: [tint.opacity(0.68), tint.opacity(0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    shape.stroke(selected ? Color.primary.opacity(0.85) : outline,
                                 style: StrokeStyle(lineWidth: selected ? 2 : 1, lineJoin: .round))
                }
                .overlay {
                    BodyMapPath(path: zone.detail, sourceBounds: zone.bounds)
                        .stroke(Color(uiColor: .systemBackground).opacity(0.45),
                                style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                }
                .overlay(alignment: .topLeading) {
                    if let reading {
                        Text("\(reading.rpe)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .frame(width: 19, height: 19)
                            .background(Color(uiColor: .systemBackground).opacity(0.94), in: Circle())
                            .accessibilityHidden(true)
                            .position(x: (zone.marker.x - zone.bounds.minX) * scale,
                                      y: (zone.marker.y - zone.bounds.minY) * scale)
                    }
                }
                .contentShape(shape)
        }
        .frame(width: width, height: height)
        .buttonStyle(BodyMapPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("\(zone.region.label), \(zone.side.label.lowercased())")
        .accessibilityValue(readingLabel(reading))
        .accessibilityHint("Adjust this muscle's RPE.")
        .accessibilityIdentifier("bodyMap.\(back ? "back" : "front").\(zone.region.rawValue)")
    }

    private func readingLabel(_ reading: MuscleRPESummary.Reading?) -> String {
        guard let reading else { return "Not rated in the last 7 days" }
        return "\(reading.grade.label), RPE \(reading.rpe), \(reading.observedAt.formatted(date: .abbreviated, time: .omitted)), \(reading.sourceLabel)"
    }
}

private struct BodyMapPressStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.08 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
