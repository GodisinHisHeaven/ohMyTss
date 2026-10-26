import SwiftUI

struct BodyMapView: View {
    var observations: [LocalObservation] = []
    var onSelect: (Region) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var back = false
    @State private var selectedZone: String?

    var body: some View {
        let reports = BodyMapReports(observations: observations)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How are you feeling?").font(.headline)
                Text("Tap a region to check in.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Picker("Body view", selection: $back) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("bodyMap.face")
            .onChange(of: back) { selectedZone = nil }

            figure(reports)
                .frame(height: 410)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
                        }
                }

            VStack(alignment: .leading, spacing: 9) {
                Text("Your latest reports · 7 days")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { legend }
                } else {
                    HStack(alignment: .top, spacing: 12) { legend }
                }
                Text("Choose left, right, or both when you check in.")
                    .font(.caption).foregroundStyle(.secondary)
                if !reports.unspecifiedRegions.isEmpty {
                    Text("Reports without a side are listed in Report history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Choose from a list") {
                VStack(spacing: 0) {
                    ForEach(Region.allCases) { region in
                        Button { onSelect(region) } label: {
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

    private func color(_ status: BodyMapReports.Status) -> Color {
        switch status {
        case .unreported: return neutral
        case .noDiscomfort: return colorScheme == .dark ? Color(red: 0.32, green: 0.78, blue: 0.69) : Color(red: 0.13, green: 0.59, blue: 0.51)
        case .discomfort: return colorScheme == .dark ? Color(red: 1, green: 0.66, blue: 0.34) : Color(red: 0.89, green: 0.46, blue: 0.16)
        }
    }

    @ViewBuilder private var legend: some View {
        legendItem("No report", icon: "circle", status: .unreported)
        legendItem("No discomfort", icon: "checkmark.circle.fill", status: .noDiscomfort)
        legendItem("Discomfort", icon: "exclamationmark.circle.fill", status: .discomfort)
    }

    private func legendItem(_ title: String, icon: String, status: BodyMapReports.Status) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).foregroundStyle(color(status)).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ reports: BodyMapReports) -> some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.height - 16) / BodyMapArtwork.size.height,
                            geometry.size.width / BodyMapArtwork.size.width)
            let size = CGSize(width: BodyMapArtwork.size.width * scale, height: BodyMapArtwork.size.height * scale)
            let origin = CGPoint(x: (geometry.size.width - size.width) / 2, y: 8)
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [color(.noDiscomfort).opacity(0.06), .clear],
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
                    zoneButton(zone, reports: reports, scale: scale)
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

    private func zoneButton(_ zone: BodyMapArtwork.Zone, reports: BodyMapReports, scale: CGFloat) -> some View {
        let status = reports.status(zone.region, side: zone.side)
        let tint = color(status)
        let outline = status == .unreported
            ? (colorScheme == .dark ? Color(red: 0.52, green: 0.65, blue: 0.68) : Color(red: 0.43, green: 0.56, blue: 0.59))
            : tint
        let selected = selectedZone == zone.id
        let shape = BodyMapPath(path: zone.outline, sourceBounds: zone.bounds)
        let width = zone.bounds.width * scale
        let height = zone.bounds.height * scale
        return Button {
            selectedZone = zone.id
            onSelect(zone.region)
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
                    if status != .unreported {
                        Image(systemName: status == .noDiscomfort ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color(uiColor: .systemBackground), tint)
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
        .accessibilityValue(reportLabel(reports.report(zone.region, side: zone.side)))
        .accessibilityHint("Add a report. Choose which side in the next step.")
        .accessibilityIdentifier("bodyMap.\(back ? "back" : "front").\(zone.region.rawValue)")
    }

    private func reportLabel(_ report: LocalObservation?) -> String {
        guard let report else { return "No report in the last 7 days" }
        return "\(V2Presentation.observation(report)), \(report.observedAt.formatted(date: .abbreviated, time: .omitted))"
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
