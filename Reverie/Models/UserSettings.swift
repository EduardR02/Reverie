import Foundation
import CoreGraphics

enum ReaderReadingMode: String, Codable, CaseIterable, Sendable {
    case scroll
    case pages
}

enum ReaderPageLayout: String, Codable, CaseIterable, Sendable {
    case single
    case spread
}

// MARK: - User Settings

struct UserSettings: Codable, Equatable {
    var googleAPIKey: String = ""
    var openAIAPIKey: String = ""
    var openAIAuthenticationMode: OpenAIAuthenticationMode = .apiKey
    var anthropicAPIKey: String = ""
    var llmProvider: LLMProvider = .google
    var llmModel: String = LLMProvider.google.defaultModel.id
    var imageModel: ImageModel = .gemini25Flash
    var fontSize: CGFloat = 15
    var fontFamily: String = "SF Pro Text"
    var lineSpacing: CGFloat = 1.2
    var readingMode: ReaderReadingMode = .scroll
    var pageLayout: ReaderPageLayout = .spread
    var theme: String = "Rose Pine Black"
    private var themeDefaultVersion = 1
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

    func hasAuthentication(for provider: LLMProvider) -> Bool {
        switch provider {
        case .google:
            return !googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .anthropic:
            return !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openai:
            switch openAIAuthenticationMode {
            case .apiKey:
                return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .chatGPTSubscription:
                return OpenAISubscriptionAuth.isConnected
            }
        }
    }

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

extension UserSettings {
    // Decode missing fields from their declared defaults, preserving older saved preferences.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        googleAPIKey = try values.decodeIfPresent(String.self, forKey: .googleAPIKey) ?? googleAPIKey
        openAIAPIKey = try values.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? openAIAPIKey
        openAIAuthenticationMode = try values.decodeIfPresent(OpenAIAuthenticationMode.self, forKey: .openAIAuthenticationMode) ?? openAIAuthenticationMode
        anthropicAPIKey = try values.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? anthropicAPIKey
        llmProvider = try values.decodeIfPresent(LLMProvider.self, forKey: .llmProvider) ?? llmProvider
        llmModel = try values.decodeIfPresent(String.self, forKey: .llmModel) ?? llmModel
        imageModel = try values.decodeIfPresent(ImageModel.self, forKey: .imageModel) ?? imageModel
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? fontSize
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? fontFamily
        lineSpacing = try values.decodeIfPresent(CGFloat.self, forKey: .lineSpacing) ?? lineSpacing
        readingMode = try values.decodeIfPresent(ReaderReadingMode.self, forKey: .readingMode) ?? readingMode
        pageLayout = try values.decodeIfPresent(ReaderPageLayout.self, forKey: .pageLayout) ?? pageLayout
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? theme
        // Move the former default once; later explicit selections of the original stay intact.
        if !values.contains(.themeDefaultVersion), theme == "Rose Pine" {
            theme = "Rose Pine Black"
        }
        insightDensity = try values.decodeIfPresent(DensityLevel.self, forKey: .insightDensity) ?? insightDensity
        imageDensity = try values.decodeIfPresent(DensityLevel.self, forKey: .imageDensity) ?? imageDensity
        imagesEnabled = try values.decodeIfPresent(Bool.self, forKey: .imagesEnabled) ?? imagesEnabled
        inlineAIImages = try values.decodeIfPresent(Bool.self, forKey: .inlineAIImages) ?? inlineAIImages
        rewriteImageExcerpts = try values.decodeIfPresent(Bool.self, forKey: .rewriteImageExcerpts) ?? rewriteImageExcerpts
        chatReasoningLevel = try values.decodeIfPresent(ReasoningLevel.self, forKey: .chatReasoningLevel) ?? chatReasoningLevel
        insightReasoningLevel = try values.decodeIfPresent(ReasoningLevel.self, forKey: .insightReasoningLevel) ?? insightReasoningLevel
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? webSearchEnabled
        autoSwitchToQuiz = try values.decodeIfPresent(Bool.self, forKey: .autoSwitchToQuiz) ?? autoSwitchToQuiz
        autoSwitchContextTabs = try values.decodeIfPresent(Bool.self, forKey: .autoSwitchContextTabs) ?? autoSwitchContextTabs
        autoSwitchFromChatOnScroll = try values.decodeIfPresent(Bool.self, forKey: .autoSwitchFromChatOnScroll) ?? autoSwitchFromChatOnScroll
        smartAutoScrollEnabled = try values.decodeIfPresent(Bool.self, forKey: .smartAutoScrollEnabled) ?? smartAutoScrollEnabled
        autoScrollHighlightEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoScrollHighlightEnabled) ?? autoScrollHighlightEnabled
        activeContentBorderEnabled = try values.decodeIfPresent(Bool.self, forKey: .activeContentBorderEnabled) ?? activeContentBorderEnabled
        showReadingSpeedFooter = try values.decodeIfPresent(Bool.self, forKey: .showReadingSpeedFooter) ?? showReadingSpeedFooter
        useCheapestModelForClassification = try values.decodeIfPresent(Bool.self, forKey: .useCheapestModelForClassification) ?? useCheapestModelForClassification
        autoAIProcessingEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoAIProcessingEnabled) ?? autoAIProcessingEnabled
        useSimulationMode = try values.decodeIfPresent(Bool.self, forKey: .useSimulationMode) ?? useSimulationMode
        rsvpEnabled = try values.decodeIfPresent(Bool.self, forKey: .rsvpEnabled) ?? rsvpEnabled
        rsvpFontSize = try values.decodeIfPresent(CGFloat.self, forKey: .rsvpFontSize) ?? rsvpFontSize
        maxConcurrentRequests = try values.decodeIfPresent(Int.self, forKey: .maxConcurrentRequests) ?? maxConcurrentRequests
    }
}
