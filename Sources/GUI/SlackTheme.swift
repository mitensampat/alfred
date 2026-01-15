import SwiftUI

// Slack-inspired design system with aubergine palette
struct SlackTheme {
    // Background colors - Slack's signature aubergine/plum tones
    static let primaryBackground = Color(hex: "4A154B")      // Deep aubergine (Slack's brand color)
    static let secondaryBackground = Color(hex: "611f69")    // Lighter aubergine
    static let tertiaryBackground = Color(hex: "732d7a")     // Hover state
    static let surfaceBackground = Color(hex: "FFFFFF")      // White cards/surfaces

    // Text colors
    static let primaryText = Color(hex: "1D1C1D")            // Almost black (Slack's text)
    static let secondaryText = Color(hex: "616061")          // Gray text
    static let tertiaryText = Color(hex: "868686")           // Muted text
    static let inverseText = Color.white                      // White text on dark backgrounds

    // Accent colors - Slack's vibrant palette
    static let accentPrimary = Color(hex: "1264A3")          // Slack blue
    static let accentSuccess = Color(hex: "2BAC76")          // Slack green
    static let accentWarning = Color(hex: "E8912D")          // Slack orange
    static let accentDanger = Color(hex: "E01E5A")           // Slack red/pink
    static let accentPurple = Color(hex: "611f69")           // Aubergine accent

    // Border colors
    static let border = Color(hex: "E0E0E0")                 // Light gray border
    static let borderDark = Color(hex: "8B6B8F")             // Purple-gray border

    // Spacing
    static let paddingSmall: CGFloat = 8
    static let paddingMedium: CGFloat = 16
    static let paddingLarge: CGFloat = 24

    // Corner radius - Slack uses subtle rounded corners
    static let cornerRadiusSmall: CGFloat = 4
    static let cornerRadiusMedium: CGFloat = 8
    static let cornerRadiusLarge: CGFloat = 12

    // Shadows
    static let shadowColor = Color.black.opacity(0.08)
}

// Keep the hex extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
