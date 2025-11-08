import SwiftUI

extension Color {
    /// Initializes a Color from a hex string
    /// - Parameter hex: Hex color string (e.g., "#FF5733" or "FF5733")
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }

    /// Zone colors for Body Battery readiness levels
    public static let zoneRecovery = Color(hex: "#E53E3E")      // Red
    public static let zoneEasy = Color(hex: "#DD6B20")          // Orange
    public static let zoneModerate = Color(hex: "#D69E2E")      // Yellow
    public static let zoneHard = Color(hex: "#38A169")          // Green
    public static let zonePeak = Color(hex: "#3182CE")          // Blue
}
