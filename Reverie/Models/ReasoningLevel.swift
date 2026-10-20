import Foundation

// MARK: - Reasoning Level

enum ReasoningLevel: String, Codable, CaseIterable, CustomStringConvertible {
    case off = "Off"
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"
    case max = "Max"

    var description: String { rawValue }

    func openAIEffort(for model: String) -> String {
        clampedEffort(supported: SupportedModels.capabilities(for: model)?.reasoningEfforts ?? [])
    }

    func geminiLevel(for model: String) -> String {
        clampedEffort(supported: SupportedModels.capabilities(for: model)?.geminiThinkingLevels ?? [])
    }

    func anthropicEffort(for model: String) -> String {
        clampedEffort(supported: SupportedModels.capabilities(for: model)?.reasoningEfforts ?? [])
    }

    private func clampedEffort(supported: [String]) -> String {
        let requested = Self.effortOrder.firstIndex(of: apiEffort)!
        for effort in Self.effortOrder[requested...] where supported.contains(effort) {
            return effort
        }
        return Self.effortOrder.last(where: supported.contains) ?? "low"
    }

    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    private var apiEffort: String {
        switch self {
        case .off: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }

    var displayDescription: String {
        switch self {
        case .off: return "No reasoning"
        case .minimal: return "Quick thinking"
        case .low: return "Light reasoning"
        case .medium: return "Balanced"
        case .high: return "Deep thinking"
        case .xhigh: return "Extra-deep reasoning"
        case .max: return "Maximum supported depth"
        }
    }
}
