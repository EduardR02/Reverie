import SwiftUI
import GRDB

// MARK: - Navigation

enum AppScreen {
    case home
    case settings
    case stats
    case reader(Book)
}

// MARK: - App State

@Observable
final class AppState {
    // Navigation
    var currentScreen: AppScreen = .home
    var currentBook: Book?
    var currentChapterIndex: Int = 0

    // UI State
    var showImportSheet = false
    var showSettings: Bool {
        get {
            if case .settings = currentScreen { return true }
            return false
        }
        set {
            if newValue {
                currentScreen = .settings
            } else {
                currentScreen = .home
            }
        }
    }
    var splitRatio: CGFloat = 0.65  // Persisted

    // Services
    let database: DatabaseService
    let llmService: LLMService
    let imageService: ImageService
    let readingSpeedTracker: ReadingSpeedTracker

    // Settings
    var settings: UserSettings

    // Reading Stats
    var readingStats: ReadingStats

    init() {
        self.database = DatabaseService.shared
        self.llmService = LLMService()
        self.imageService = ImageService()
        self.readingSpeedTracker = ReadingSpeedTracker()
        self.settings = UserSettings.load()
        self.readingStats = ReadingStats.load()
        ThemeManager.shared.setTheme(settings.theme)
        if ThemeManager.shared.current.name != settings.theme {
            settings.theme = ThemeManager.shared.current.name
            settings.save()
        }

        // Load persisted split ratio
        if let ratio = UserDefaults.standard.object(forKey: "splitRatio") as? CGFloat {
            self.splitRatio = ratio
        }
    }

    // MARK: - Navigation

    func openBook(_ book: Book) {
        currentBook = book
        let maxIndex = max(0, book.chapterCount - 1)
        currentChapterIndex = min(max(book.currentChapter, 0), maxIndex)
        currentScreen = .reader(book)
    }

    func closeBook() {
        currentBook = nil
        currentScreen = .home
    }

    func openSettings() {
        currentScreen = .settings
    }

    func openStats() {
        currentScreen = .stats
    }

    func goHome() {
        currentScreen = .home
    }

    func nextChapter() {
        guard let book = currentBook else { return }
        if currentChapterIndex < book.chapterCount - 1 {
            currentChapterIndex += 1
        }
    }

    func previousChapter() {
        if currentChapterIndex > 0 {
            currentChapterIndex -= 1
        }
    }

    // MARK: - Persistence

    func saveSplitRatio() {
        UserDefaults.standard.set(splitRatio, forKey: "splitRatio")
    }
}

// MARK: - Density Level

enum DensityLevel: String, Codable, CaseIterable {
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"

    /// Returns a range guidance for the LLM - model decides within range
    var annotationRange: (min: Int, max: Int) {
        switch self {
        case .minimal: return (1, 3)
        case .low: return (3, 5)
        case .medium: return (4, 8)
        case .high: return (7, 12)
        case .xhigh: return (10, 20)
        }
    }

    var imageRange: (min: Int, max: Int) {
        switch self {
        case .minimal: return (0, 1)
        case .low: return (1, 2)
        case .medium: return (2, 4)
        case .high: return (3, 6)
        case .xhigh: return (5, 10)
        }
    }

    var description: String {
        let r = annotationRange
        return "\(r.min)-\(r.max) insights"
    }

    var imageDescription: String {
        let r = imageRange
        return "\(r.min)-\(r.max) images"
    }
}

// MARK: - Reasoning Level

enum ReasoningLevel: String, Codable, CaseIterable {
    case off = "Off"
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"

    /// Maps to Gemini 3 thinkingLevel (flash model has limited options)
    func gemini3Level(isFlash: Bool) -> String {
        switch self {
        case .off: return "none"
        case .minimal, .low: return isFlash ? "low" : "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return isFlash ? "high" : "high"  // Flash doesn't support xhigh
        }
    }

    /// Maps to OpenAI reasoning effort (GPT-5+)
    var openAIEffort: String {
        switch self {
        case .off: return "low"  // Minimum
        case .minimal, .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh: return "high"
        }
    }

    /// Whether Anthropic thinking should be enabled (toggle only)
    var anthropicEnabled: Bool {
        self != .off
    }

    /// Display description
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

// MARK: - Reading Stats

struct ReadingStats: Codable {
    var minutesToday: Int = 0
    var currentStreak: Int = 0
    var totalMinutes: Int = 0
    var totalBooks: Int = 0
    var lastReadDate: Date?

    // Extended stats
    var totalWords: Int = 0
    var insightsGenerated: Int = 0
    var followupsAsked: Int = 0
    var imagesGenerated: Int = 0

    // Token usage breakdown
    var tokensInput: Int = 0
    var tokensReasoning: Int = 0
    var tokensOutput: Int = 0

    // Quiz stats
    var quizzesAnswered: Int = 0
    var quizzesCorrect: Int = 0

    // Daily reading log (for GitHub-style graph) - stores date string -> minutes
    var dailyLog: [String: Int] = [:]

    static func load() -> ReadingStats {
        guard let data = UserDefaults.standard.data(forKey: "readingStats"),
              let stats = try? JSONDecoder().decode(ReadingStats.self, from: data) else {
            return ReadingStats()
        }
        return stats
    }

    mutating func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "readingStats")
        }
    }

    mutating func addReadingTime(_ minutes: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Reset today's minutes if it's a new day
        if let lastDate = lastReadDate, !calendar.isDate(lastDate, inSameDayAs: Date()) {
            // Check if we broke the streak
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if calendar.isDate(lastDate, inSameDayAs: yesterday) {
                currentStreak += 1
            } else {
                currentStreak = 1
            }
            minutesToday = 0
        }

        minutesToday += minutes
        totalMinutes += minutes
        lastReadDate = Date()

        // Update daily log
        let dateKey = Self.dateKey(for: Date())
        dailyLog[dateKey, default: 0] += minutes

        save()
    }

    mutating func addTokens(input: Int, reasoning: Int, output: Int) {
        tokensInput += input
        tokensReasoning += reasoning
        tokensOutput += output
        save()
    }

    mutating func recordQuizAnswer(correct: Bool) {
        quizzesAnswered += 1
        if correct {
            quizzesCorrect += 1
        }
        save()
    }

    mutating func recordInsight() {
        insightsGenerated += 1
        save()
    }

    mutating func recordFollowup() {
        followupsAsked += 1
        save()
    }

    mutating func recordImage() {
        imagesGenerated += 1
        save()
    }

    mutating func addWords(_ count: Int) {
        totalWords += count
        save()
    }

    var quizAccuracy: Double {
        guard quizzesAnswered > 0 else { return 0 }
        return Double(quizzesCorrect) / Double(quizzesAnswered)
    }

    var totalTokens: Int {
        tokensInput + tokensReasoning + tokensOutput
    }

    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func minutesFor(date: Date) -> Int {
        let key = Self.dateKey(for: date)
        return dailyLog[key] ?? 0
    }
}

// MARK: - User Settings

struct UserSettings: Codable, Equatable {
    // API Keys
    var googleAPIKey: String = ""
    var openAIAPIKey: String = ""
    var anthropicAPIKey: String = ""

    // Model Selection
    var llmProvider: LLMProvider = .google
    var llmModel: String = "gemini-3-flash-preview"
    var imageModel: ImageModel = .nanoBanana

    // Reading
    var fontSize: CGFloat = 18
    var fontFamily: String = "SF Pro Text"
    var lineSpacing: CGFloat = 1.6
    var theme: String = "Rose Pine"

    // AI Features
    var insightDensity: DensityLevel = .medium
    var imageDensity: DensityLevel = .low
    var imagesEnabled: Bool = false

    // Reasoning
    var chatReasoningLevel: ReasoningLevel = .medium
    var insightReasoningLevel: ReasoningLevel = .high

    // Temperature
    var temperature: Double = 1.0

    // Auto-scroll behavior
    var autoSwitchToQuiz: Bool = true
    var smartAutoScrollEnabled: Bool = true
    var showReadingSpeedFooter: Bool = true

    // MARK: - Persistence

    static func load() -> UserSettings {
        guard let data = UserDefaults.standard.data(forKey: "userSettings"),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data) else {
            return UserSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "userSettings")
        }
    }
}

// MARK: - Enums

struct LLMModel {
    let id: String
    let name: String
}

enum LLMProvider: String, Codable, CaseIterable {
    case google = "Google"
    case openai = "OpenAI"
    case anthropic = "Anthropic"

    var models: [LLMModel] {
        switch self {
        case .google:
            return [
                LLMModel(id: "gemini-3-flash-preview", name: "Gemini 3 Flash"),
                LLMModel(id: "gemini-3-pro-preview", name: "Gemini 3 Pro")
            ]
        case .openai:
            return [
                LLMModel(id: "gpt-5.2", name: "GPT-5.2"),
                LLMModel(id: "gpt-5.2-mini", name: "GPT-5.2 mini")
            ]
        case .anthropic:
            return [
                LLMModel(id: "claude-sonnet-4-5", name: "Claude 4.5 Sonnet"),
                LLMModel(id: "claude-4.5-opus", name: "Claude 4.5 Opus"),
                LLMModel(id: "claude-4.5-haiku", name: "Claude 4.5 Haiku")
            ]
        }
    }

    var modelIds: [String] {
        models.map { $0.id }
    }

    var displayName: String {
        switch self {
        case .google: return "Gemini"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        }
    }

    func modelName(for id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }
}

enum ImageModel: String, Codable, CaseIterable {
    case nanoBananaPro = "Nano Banana Pro"
    case nanoBanana = "Nano Banana"

    var apiModel: String {
        switch self {
        case .nanoBananaPro: return "gemini-3-pro-image-preview"
        case .nanoBanana: return "gemini-2.5-flash-image-preview"
        }
    }

    var description: String {
        switch self {
        case .nanoBananaPro: return "Best quality, slower"
        case .nanoBanana: return "Fast, good quality"
        }
    }
}
