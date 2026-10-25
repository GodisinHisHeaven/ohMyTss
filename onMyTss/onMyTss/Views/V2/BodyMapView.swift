import SwiftUI

/// Nine coarse regions, mirrored visually. Side is chosen by the person, never inferred.
struct BodyMapView: View {
    var onSelect: (Region) -> Void
    @State private var back = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Body view", selection: $back) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("bodyMap.face")

            GeometryReader { geometry in
                let width = min(geometry.size.width, 280)
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.2))
                        .frame(width: 42, height: 42).position(x: width / 2, y: 24)
                    region(.shoulders, x: 0.30, y: 0.19, w: 0.18, h: 0.13, width: width)
                    region(.shoulders, x: 0.70, y: 0.19, w: 0.18, h: 0.13, width: width)
                    region(.arms, x: 0.22, y: 0.39, w: 0.13, h: 0.28, width: width)
                    region(.arms, x: 0.78, y: 0.39, w: 0.13, h: 0.28, width: width)
                    region(back ? .back : .chest, x: 0.50, y: 0.25, w: 0.34, h: 0.20, width: width)
                    region(back ? .back : .core, x: 0.50, y: 0.43, w: 0.29, h: 0.16, width: width)
                    if back {
                        region(.glutes, x: 0.50, y: 0.56, w: 0.34, h: 0.12, width: width)
                    }
                    region(back ? .hamstrings : .quads, x: 0.40, y: 0.68, w: 0.17, h: 0.22, width: width)
                    region(back ? .hamstrings : .quads, x: 0.60, y: 0.68, w: 0.17, h: 0.22, width: width)
                    region(.calves, x: 0.40, y: 0.88, w: 0.13, h: 0.18, width: width)
                    region(.calves, x: 0.60, y: 0.88, w: 0.13, h: 0.18, width: width)
                }
                .frame(width: width, height: 350)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 350)

            Text("Tap a region to record how it feels. Choose left or right in the next step.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Choose from a list") {
                ForEach(Region.allCases) { region in
                    Button(region.label) { onSelect(region) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("bodyMap.list.\(region.rawValue)")
                }
            }
        }
    }

    private func region(_ region: Region, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, width: CGFloat) -> some View {
        Button { onSelect(region) } label: {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 1))
                .overlay {
                    if w >= 0.29 {
                        Text(region.label).font(.caption2).foregroundStyle(.primary).minimumScaleFactor(0.7)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(width: width * w, height: 350 * h)
        .position(x: width * x, y: 350 * y)
        .accessibilityLabel(region.label)
        .accessibilityHint("Record regional discomfort; side can be selected next")
        .accessibilityIdentifier("bodyMap.\(back ? "back" : "front").\(region.rawValue)")
    }
}
