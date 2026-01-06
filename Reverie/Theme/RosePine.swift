import SwiftUI

// MARK: - Rose Pine (Main Dark Theme)

struct RosePineTheme: Theme {
    let name = "Rose Pine"

    // Backgrounds - deep, warm darkness
    let base = Color(hex: "#191724")
    let surface = Color(hex: "#1f1d2e")
    let overlay = Color(hex: "#26233a")

    // Text hierarchy
    let text = Color(hex: "#e0def4")
    let subtle = Color(hex: "#908caa")
    let muted = Color(hex: "#6e6a86")

    // Accents - the soul of Rose Pine
    let rose = Color(hex: "#ebbcba")      // The signature pastel pink
    let love = Color(hex: "#eb6f92")      // Warm red-pink
    let gold = Color(hex: "#f6c177")      // Soft amber
    let pine = Color(hex: "#31748f")      // Deep teal
    let foam = Color(hex: "#9ccfd8")      // Light cyan
    let iris = Color(hex: "#c4a7e7")      // Soft lavender

    // Highlights
    let highlightLow = Color(hex: "#21202e")
    let highlightMed = Color(hex: "#403d52")
    let highlightHigh = Color(hex: "#524f67")
}

// MARK: - Rose Pine Moon (Darker Variant)

struct RosePineMoonTheme: Theme {
    let name = "Rose Pine Moon"

    let base = Color(hex: "#232136")
    let surface = Color(hex: "#2a273f")
    let overlay = Color(hex: "#393552")

    let text = Color(hex: "#e0def4")
    let subtle = Color(hex: "#908caa")
    let muted = Color(hex: "#6e6a86")

    let rose = Color(hex: "#ea9a97")
    let love = Color(hex: "#eb6f92")
    let gold = Color(hex: "#f6c177")
    let pine = Color(hex: "#3e8fb0")
    let foam = Color(hex: "#9ccfd8")
    let iris = Color(hex: "#c4a7e7")

    let highlightLow = Color(hex: "#2a283e")
    let highlightMed = Color(hex: "#44415a")
    let highlightHigh = Color(hex: "#56526e")
}

// MARK: - Rose Pine Dawn (Light Variant)

struct RosePineDawnTheme: Theme {
    let name = "Rose Pine Dawn"

    let base = Color(hex: "#faf4ed")
    let surface = Color(hex: "#fffaf3")
    let overlay = Color(hex: "#f2e9e1")

    let text = Color(hex: "#575279")
    let subtle = Color(hex: "#797593")
    let muted = Color(hex: "#9893a5")

    let rose = Color(hex: "#d7827e")
    let love = Color(hex: "#b4637a")
    let gold = Color(hex: "#ea9d34")
    let pine = Color(hex: "#286983")
    let foam = Color(hex: "#56949f")
    let iris = Color(hex: "#907aa9")

    let highlightLow = Color(hex: "#f4ede8")
    let highlightMed = Color(hex: "#dfdad9")
    let highlightHigh = Color(hex: "#cecacd")
}

// MARK: - Color Hex Extension

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
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
