import Foundation

// MARK: - Density Level

enum DensityLevel: String, Codable, CaseIterable {
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"

    var insightGuidance: String {
        switch self {
        case .minimal: return "Only the most essential insights. Skip minor points."
        case .low: return "A few high-value insights. Avoid filler."
        case .medium: return "A balanced set of meaningful insights."
        case .high: return "Many insights covering most notable moments."
        case .xhigh: return "Dense, near-exhaustive insights. Avoid redundancy."
        }
    }

    var imageGuidance: String {
        switch self {
        case .minimal: return "Only the most visually striking moments."
        case .low: return "A few strong illustration-worthy scenes."
        case .medium: return "Balanced visual coverage of key scenes."
        case .high: return "Many visual moments, but avoid filler."
        case .xhigh: return "Very visual and rich. Capture nearly all strong scenes."
        }
    }

    var description: String {
        switch self {
        case .minimal: return "Only essentials"
        case .low: return "Few highlights"
        case .medium: return "Balanced"
        case .high: return "Deep coverage"
        case .xhigh: return "Exhaustive"
        }
    }

    var imageDescription: String {
        switch self {
        case .minimal: return "Very selective"
        case .low: return "Selective"
        case .medium: return "Balanced"
        case .high: return "Illustration-heavy"
        case .xhigh: return "Maximal"
        }
    }

    /// Words per insight target for each density level
    private var wordsPerInsight: Int {
        switch self {
        case .minimal: return 2000
        case .low: return 1200
        case .medium: return 800
        case .high: return 500
        case .xhigh: return 300
        }
    }

    /// A soft ceiling, never a quota: short or unilluminating text may merit none.
    func suggestedInsightLimit(wordCount: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return wordCount / wordsPerInsight + (wordCount % wordsPerInsight == 0 ? 0 : 1)
    }

    func proportionalGuidance(wordCount: Int) -> String {
        """
        This chapter is ~\(max(0, wordCount)) words. For \(rawValue) density, consider up to roughly \(suggestedInsightLimit(wordCount: wordCount)) distinct insights when supported. This is not a target to fill: no minimum, no padding, and no forced category coverage. Develop the strongest explanations instead of splitting one idea into several items.
        """
    }
}
