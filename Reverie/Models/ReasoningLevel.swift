import Foundation

// MARK: - Reasoning Level

enum ReasoningLevel: String, Codable, CaseIterable, CustomStringConvertible {
    case off = "Off"
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"

    var description: String { rawValue }

    func gemini3Level(isFlash: Bool) -> String {
        let effort = apiEffort
        if isFlash {
            return effort == "xhigh" ? "high" : effort
        }
        return (effort == "minimal" || effort == "low") ? "low" : "high"
    }

    var openAIEffort: String {
        apiEffort
    }

    private var apiEffort: String {
        switch self {
        case .off: return "minimal"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        }
    }

    var anthropicEnabled: Bool {
        self != .off
    }

    var displayDescription: String {
        switch self {
        case .off: return "No reasoning"
        case .minimal: return "Quick thinking"
        case .low: return "Light reasoning"
        case .medium: return "Balanced"
        case .high: return "Deep thinking"
        case .xhigh: return "Maximum depth"
        }
    }
}
