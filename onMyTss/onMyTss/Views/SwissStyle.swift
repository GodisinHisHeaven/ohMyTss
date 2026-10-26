import SwiftUI

private struct SwissReducedEffectsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var swissReducedEffects: Bool {
        get { self[SwissReducedEffectsKey.self] }
        set { self[SwissReducedEffectsKey.self] = newValue }
    }
}

/// Quiet content surfaces keep the system's glass navigation legible.
enum SwissStyle {
    static let accent = Color.accentColor
    static let action = Color("ActionColor")
    static let canvas = Color("CanvasColor")
    static let surface = Color("SurfaceColor")
    static let inset = Color("InsetColor")
    static let positive = Color("PositiveColor")
    static let caution = Color("CautionColor")
    static let critical = Color("CriticalColor")
    static let rule = Color.primary.opacity(0.14)
}

struct SwissList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowBackground(SwissStyle.surface)
                .listRowSeparatorTint(SwissStyle.rule)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .background(SwissStyle.canvas)
        .environment(\.defaultMinListRowHeight, 52)
    }
}

struct SwissForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(SwissStyle.surface)
                .listRowSeparatorTint(SwissStyle.rule)
        }
        .formStyle(.grouped)
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .background(SwissStyle.canvas)
        .environment(\.defaultMinListRowHeight, 52)
    }
}

struct SwissSectionHeading: View {
    let number: String
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold)).tracking(0.3)
        }
        .textCase(nil)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SwissGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

private struct SwissGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.swissReducedEffects) private var reducedEffects

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || reducedEffects {
            content.background(SwissStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SwissStyle.rule, lineWidth: 1))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct SwissActionStyle: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.swissReducedEffects) private var reducedEffects

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency, contrast != .increased, !reducedEffects {
            if prominent { content.buttonStyle(.glassProminent).tint(SwissStyle.action) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).tint(SwissStyle.action) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func swissCanvas() -> some View {
        background(SwissStyle.canvas)
    }

    func swissPanel() -> some View {
        background(SwissStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SwissStyle.rule, lineWidth: 0.5))
    }

    func swissGlass() -> some View { modifier(SwissGlassSurface()) }

    func swissAction(prominent: Bool = false) -> some View {
        modifier(SwissActionStyle(prominent: prominent))
    }
}

#if DEBUG
/// Exercises our opaque-control fallback without changing device settings.
struct SwissAccessibilityFixture: ViewModifier {
    func body(content: Content) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        Group {
            if arguments.contains("--v2-ui-tests") && arguments.contains("--swiss-reduced-effects") {
                content.environment(\.swissReducedEffects, true)
            } else {
                content
            }
        }
        .preferredColorScheme(appearance(arguments))
    }

    private func appearance(_ arguments: [String]) -> ColorScheme? {
        guard arguments.contains("--v2-ui-tests"),
              let index = arguments.firstIndex(of: "-AppleInterfaceStyle"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1] == "Dark" ? .dark : .light
    }
}
#endif
