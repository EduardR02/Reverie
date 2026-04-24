import Foundation
import CoreGraphics

// MARK: - User Settings

struct UserSettings: Codable, Equatable {
    var googleAPIKey: String = ""
    var openAIAPIKey: String = ""
    var anthropicAPIKey: String = ""
    var llmProvider: LLMProvider = .google
    var llmModel: String = "gemini-3-flash-preview"
    var imageModel: ImageModel = .gemini25Flash
    var fontSize: CGFloat = 15
    var fontFamily: String = "SF Pro Text"
    var lineSpacing: CGFloat = 1.2
    var theme: String = "Rose Pine"
    var insightDensity: DensityLevel = .medium
    var imageDensity: DensityLevel = .low
    var imagesEnabled: Bool = false
    var inlineAIImages: Bool = false
    var rewriteImageExcerpts: Bool = false
    var chatReasoningLevel: ReasoningLevel = .medium
    var insightReasoningLevel: ReasoningLevel = .high
    var temperature: Double = 1.0
    var webSearchEnabled: Bool = true
    var autoSwitchToQuiz: Bool = true
    var autoSwitchContextTabs: Bool = true
    var autoSwitchFromChatOnScroll: Bool = true
    var smartAutoScrollEnabled: Bool = false
    var autoScrollHighlightEnabled: Bool = true
    var activeContentBorderEnabled: Bool = false
    var showReadingSpeedFooter: Bool = true
    var useCheapestModelForClassification: Bool = true
    var autoAIProcessingEnabled: Bool = true
    var useSimulationMode: Bool = false
    var rsvpEnabled: Bool = false      // Whether RSVP mode is the default when loading a chapter
    var rsvpFontSize: CGFloat = 48     // Font size for RSVP display (separate from regular reading)
    var maxConcurrentRequests: Int = 5

    static func load() -> UserSettings {
        guard let data = UserDefaults.standard.data(forKey: "userSettings"),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else {
            return UserSettings()
        }
        return settings.normalized()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "userSettings")
        }
    }

    func normalized() -> UserSettings {
        var normalized = self
        normalized.llmModel = SupportedModels.canonicalLLMModelID(llmModel)
        return normalized
    }
}
