import SwiftUI
import AppKit
import Foundation

// MARK: - Theme Protocol

protocol Theme {
    var name: String { get }

    // Backgrounds
    var base: Color { get }
    var surface: Color { get }
    var overlay: Color { get }

    // Text
    var text: Color { get }
    var subtle: Color { get }
    var muted: Color { get }

    // Accents
    var rose: Color { get }      // Primary accent (the signature pink)
    var love: Color { get }      // Errors, important
    var gold: Color { get }      // Warnings, highlights
    var pine: Color { get }      // Links, actions
    var foam: Color { get }      // Info, secondary actions
    var iris: Color { get }      // Special, annotations

    // Semantic
    var highlightLow: Color { get }
    var highlightMed: Color { get }
    var highlightHigh: Color { get }
}

// MARK: - Theme Manager

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    let defaultThemeName = "Rose Pine"

    var current: Theme = RosePineTheme()
    var availableThemes: [Theme] = []

    private let builtInThemes: [Theme] = [
        RosePineTheme(),
        RosePineMoonTheme(),
        RosePineDawnTheme()
    ]
    private var customThemes: [CustomTheme] = []
    private let customThemesKey = "customThemes"

    init() {
        loadCustomThemes()
        refreshThemes()
    }

    func setTheme(_ name: String) {
        if let theme = availableThemes.first(where: { $0.name == name }) {
            current = theme
        } else if let fallback = availableThemes.first {
            current = fallback
        }
    }

    func isCustomTheme(name: String) -> Bool {
        customThemes.contains(where: { $0.name == name })
    }

    func addCustomTheme(from json: String) throws -> CustomTheme {
        let data = json.data(using: .utf8)
        guard let data else { throw ThemeImportError.invalidJSON }

        let payload = try JSONDecoder().decode(TerminalTheme.self, from: data)
        try payload.validate()

        if builtInThemes.contains(where: { $0.name == payload.name }) {
            throw ThemeImportError.nameConflict(payload.name)
        }

        let customTheme = CustomTheme(terminalTheme: payload)
        customThemes.removeAll { $0.name == customTheme.name }
        customThemes.append(customTheme)
        saveCustomThemes()
        refreshThemes()
        return customTheme
    }

    func removeCustomTheme(name: String) {
        customThemes.removeAll { $0.name == name }
        saveCustomThemes()
        refreshThemes()
        if current.name == name {
            setTheme(defaultThemeName)
        }
    }

    private func refreshThemes() {
        availableThemes = builtInThemes + customThemes
    }

    private func loadCustomThemes() {
        guard let data = UserDefaults.standard.data(forKey: customThemesKey),
              let decoded = try? JSONDecoder().decode([CustomTheme].self, from: data) else {
            customThemes = []
            return
        }
        customThemes = decoded
    }

    private func saveCustomThemes() {
        if let data = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(data, forKey: customThemesKey)
        }
    }
}

// MARK: - Custom Themes

struct TerminalTheme: Codable {
    let name: String
    let black: String
    let red: String
    let green: String
    let yellow: String
    let blue: String
    let purple: String
    let cyan: String
    let white: String
    let brightBlack: String
    let brightRed: String
    let brightGreen: String
    let brightYellow: String
    let brightBlue: String
    let brightPurple: String
    let brightCyan: String
    let brightWhite: String
    let background: String
    let foreground: String

    func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ThemeImportError.emptyName
        }

        let colors = [
            black, red, green, yellow, blue, purple, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow,
            brightBlue, brightPurple, brightCyan, brightWhite,
            background, foreground
        ]

        for value in colors {
            guard Self.isValidHex(value) else {
                throw ThemeImportError.invalidColor(value)
            }
        }
    }

    private static func isValidHex(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let length = cleaned.count
        guard [3, 6, 8].contains(length) else { return false }
        return cleaned.allSatisfy { $0.isHexDigit }
    }
}

struct CustomTheme: Theme, Codable, Equatable {
    let name: String
    let black: String
    let red: String
    let green: String
    let yellow: String
    let blue: String
    let purple: String
    let cyan: String
    let white: String
    let brightBlack: String
    let brightRed: String
    let brightGreen: String
    let brightYellow: String
    let brightBlue: String
    let brightPurple: String
    let brightCyan: String
    let brightWhite: String
    let background: String
    let foreground: String

    init(terminalTheme: TerminalTheme) {
        name = terminalTheme.name
        black = terminalTheme.black
        red = terminalTheme.red
        green = terminalTheme.green
        yellow = terminalTheme.yellow
        blue = terminalTheme.blue
        purple = terminalTheme.purple
        cyan = terminalTheme.cyan
        white = terminalTheme.white
        brightBlack = terminalTheme.brightBlack
        brightRed = terminalTheme.brightRed
        brightGreen = terminalTheme.brightGreen
        brightYellow = terminalTheme.brightYellow
        brightBlue = terminalTheme.brightBlue
        brightPurple = terminalTheme.brightPurple
        brightCyan = terminalTheme.brightCyan
        brightWhite = terminalTheme.brightWhite
        background = terminalTheme.background
        foreground = terminalTheme.foreground
    }

    var base: Color { Color(hex: background) }
    var surface: Color { blend(background, foreground, 0.06) }
    var overlay: Color { blend(background, foreground, 0.12) }

    var text: Color { Color(hex: foreground) }
    var subtle: Color { blend(foreground, background, 0.35) }
    var muted: Color { blend(foreground, background, 0.55) }

    var rose: Color { Color(hex: brightCyan) }
    var love: Color { Color(hex: brightRed) }
    var gold: Color { Color(hex: brightYellow) }
    var pine: Color { Color(hex: brightBlue) }
    var foam: Color { Color(hex: brightGreen) }
    var iris: Color { Color(hex: brightPurple) }

    var highlightLow: Color { blend(background, foreground, 0.04) }
    var highlightMed: Color { blend(background, foreground, 0.08) }
    var highlightHigh: Color { blend(background, foreground, 0.14) }

    private func blend(_ hexA: String, _ hexB: String, _ fraction: CGFloat) -> Color {
        let colorA = NSColor(Color(hex: hexA)).usingColorSpace(.deviceRGB) ?? NSColor.black
        let colorB = NSColor(Color(hex: hexB)).usingColorSpace(.deviceRGB) ?? NSColor.white
        let clamped = min(max(fraction, 0), 1)

        let r = colorA.redComponent + (colorB.redComponent - colorA.redComponent) * clamped
        let g = colorA.greenComponent + (colorB.greenComponent - colorA.greenComponent) * clamped
        let b = colorA.blueComponent + (colorB.blueComponent - colorA.blueComponent) * clamped
        let a = colorA.alphaComponent + (colorB.alphaComponent - colorA.alphaComponent) * clamped

        return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
}

enum ThemeImportError: LocalizedError {
    case invalidJSON
    case emptyName
    case nameConflict(String)
    case invalidColor(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid theme JSON. Paste the full theme block."
        case .emptyName:
            return "Theme name is required."
        case .nameConflict(let name):
            return "A built-in theme named \"\(name)\" already exists."
        case .invalidColor(let value):
            return "Invalid color value: \(value)"
        }
    }
}

// MARK: - Environment Key

struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = RosePineTheme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    func themed() -> some View {
        self.environment(\.theme, ThemeManager.shared.current)
    }
}
