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

@Observable @MainActor
final class AppState {
    // Navigation
    var currentScreen: AppScreen = .home
    var currentBook: Book?
    var currentChapterIndex: Int = 0

    // Chat Handoff
    struct ChatReference: Equatable {
        let title: String
        let content: String
        let type: AnnotationType?
    }
    var chatContextReference: ChatReference?

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

    // Processing State
    var isProcessingBook = false
    var processingProgress: Double = 0
    var processingChapter: String = ""
    var processingBookId: Int64?
    var processingTotalChapters: Int = 0
    var processingCompletedChapters: Int = 0
    var processingTask: Task<Void, Never>?
    var processingCostEstimate: Double = 0

    // Services
    let database: DatabaseService
    let llmService: LLMService
    let imageService: ImageService
    let readingSpeedTracker: ReadingSpeedTracker

    // Settings
    var settings: UserSettings

    // Reading Stats
    var readingStats: ReadingStats
    
    // Throttled Progress Save
    private var pendingProgressSaveTask: Task<Void, Never>?
    private var maxScrollCache: [Int64: Double] = [:]
    private var bookProgressCache: [Int64: BookProgressCache] = [:]

    private struct BookProgressCache {
        var totalWords: Int
        var wordsRead: Int
        var chapterWordCounts: [Int64: Int]
    }

    @MainActor
    init(database: DatabaseService? = nil) {
        let db = database ?? DatabaseService.shared
        self.database = db
        self.imageService = ImageService()
        self.readingSpeedTracker = ReadingSpeedTracker()
        self.settings = UserSettings.load()
        
        // Load stats from Database instead of UserDefaults
        self.readingStats = (try? db.fetchLifetimeStats()) ?? ReadingStats()
        
        let llm = LLMService()
        self.llmService = llm
        
        // Setup weak reference back to self for stats reporting
        llm.setAppState(self)

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

    // MARK: - Journey Tracking (Database Backed)

    func recordQuizAnswer(quiz: Quiz, correct: Bool) {
        var updatedQuiz = quiz
        updatedQuiz.userAnswered = true
        updatedQuiz.userCorrect = correct
        
        do {
            try database.saveQuiz(&updatedQuiz)
        } catch {
            print("Failed to save quiz answer: \(error)")
        }
    }

    func recordQuizQuality(quiz: Quiz, feedback: Quiz.QualityFeedback?) {
        var updatedQuiz = quiz
        updatedQuiz.qualityFeedback = feedback
        
        do {
            try database.saveQuiz(&updatedQuiz)
        } catch {
            print("Failed to save quiz quality feedback: \(error)")
        }
    }

    func toggleBookFinished(_ book: Book) {
        var updatedBook = book
        updatedBook.isFinished.toggle()
        
        do {
            try database.saveBook(&updatedBook)
            if self.currentBook?.id == book.id {
                self.currentBook = updatedBook
            }
            readingStats.recordBookFinished(finished: updatedBook.isFinished)
            saveStats()
        } catch {
            print("Failed to toggle book finished: \(error)")
        }
    }

    func recordAnnotationSeen(_ annotation: Annotation) {
        guard !annotation.isSeen else { return }
        
        var updated = annotation
        updated.isSeen = true
        
        do {
            try database.saveAnnotation(&updated)
            readingStats.recordInsightSeen()
            saveStats()
        } catch {
            print("Failed to record annotation seen: \(error)")
        }
    }

    func updateAnnotation(_ annotation: Annotation) {
        var updated = annotation
        do {
            try database.saveAnnotation(&updated)
        } catch {
            print("Failed to update annotation: \(error)")
        }
    }

    func refreshReadingStats() {
        readingStats.resetCheck()
        saveStats()
    }

    func addReadingTime(seconds: Double) {
        readingStats.addReadingTime(seconds)
        saveStats()
    }

    func addWords(_ count: Int) {
        readingStats.addWords(count)
        saveStats()
    }

    func addTokens(input: Int, reasoning: Int, output: Int) {
        readingStats.addTokens(input: input, reasoning: reasoning, output: output)
        saveStats()
    }

    func updateProcessingCost(inputTokens: Int, outputTokens: Int, model: String) {
        guard let pricing = PricingCatalog.textPricing(for: model) else { return }
        let inputCost = (Double(inputTokens) / 1_000_000) * pricing.inputPerMToken
        let outputCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMToken
        processingCostEstimate += inputCost + outputCost
    }

    func recordFollowup() {
        readingStats.recordFollowup()
        saveStats()
    }

    func recordImage() {
        readingStats.recordImage()
        saveStats()
    }

    func resetReadingSpeed() {
        readingSpeedTracker.reset()
    }

    func saveStats() {
        do {
            try database.saveLifetimeStats(readingStats)
        } catch {
            print("Failed to save lifetime stats: \(error)")
        }
    }

    // MARK: - Progress Tracking (Throttled)

    func updateBookProgressCache(book: Book, chapters: [Chapter]) {
        guard let bookId = book.id else { return }

        var totalWords = 0
        var wordsRead = 0
        var wordCounts: [Int64: Int] = [:]

        for chapter in chapters {
            guard let chapterId = chapter.id else { continue }
            let wordCount = max(0, chapter.wordCount)
            totalWords += wordCount

            let maxPercent = min(max(chapter.maxScrollReached, 0), 1)
            let readWords = Int((Double(wordCount) * maxPercent).rounded())
            wordsRead += readWords
            wordCounts[chapterId] = wordCount

            let cachedMax = maxScrollCache[chapterId] ?? 0
            if maxPercent > cachedMax {
                maxScrollCache[chapterId] = maxPercent
            }
        }

        if totalWords > 0 {
            wordsRead = min(wordsRead, totalWords)
        }

        bookProgressCache[bookId] = BookProgressCache(
            totalWords: totalWords,
            wordsRead: wordsRead,
            chapterWordCounts: wordCounts
        )
    }

    func updateChapterProgress(chapter: Chapter, scrollPercent: Double, scrollOffset: Double) {
        guard let book = currentBook else { return }
        let bookId = book.id
        
        pendingProgressSaveTask?.cancel()
        pendingProgressSaveTask = Task { @MainActor in
            // Debounce for 1 second to avoid DB thrashing
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let chapterCount = max(1, book.chapterCount)
            let chapterIndex = min(max(chapter.index, 0), chapterCount - 1)
            
            // 1. Calculate words read delta
            let clampedPercent = max(0, min(scrollPercent, 1))
            let previousMax = min(max(chapter.id.flatMap { maxScrollCache[$0] } ?? chapter.maxScrollReached, 0), 1)
            if clampedPercent > previousMax {
                let chapterId = chapter.id
                let cachedWordCount: Int? = {
                    guard let bookId, let chapterId else { return nil }
                    return bookProgressCache[bookId]?.chapterWordCounts[chapterId]
                }()
                let wordCount = cachedWordCount ?? chapter.wordCount
                let previousWords = Int((Double(wordCount) * previousMax).rounded())
                let currentWords = Int((Double(wordCount) * clampedPercent).rounded())
                let wordDelta = currentWords - previousWords
                if wordDelta > 0 {
                    self.addWords(wordDelta)
                    if let bookId, var cache = bookProgressCache[bookId], cache.totalWords > 0 {
                        cache.wordsRead = min(cache.totalWords, cache.wordsRead + wordDelta)
                        bookProgressCache[bookId] = cache
                    }
                }
                
                var updatedChapter = chapter
                updatedChapter.maxScrollReached = clampedPercent
                try? database.saveChapter(&updatedChapter)
                if let chapterId = chapter.id {
                    maxScrollCache[chapterId] = clampedPercent
                }
            }
            
            // 2. Save book progress
            let overallProgress: Double
            if let bookId, let cache = bookProgressCache[bookId], cache.totalWords > 0 {
                overallProgress = min(max(Double(cache.wordsRead) / Double(cache.totalWords), 0), 1)
            } else {
                let chapterProgress = Double(chapterIndex) + clampedPercent
                overallProgress = min(max(chapterProgress / Double(chapterCount), 0), 1)
            }

            var updatedBook = book
            updatedBook.currentChapter = chapterIndex
            updatedBook.currentScrollPercent = clampedPercent
            updatedBook.currentScrollOffset = scrollOffset
            updatedBook.progressPercent = overallProgress
            updatedBook.lastReadAt = Date()

            do {
                try database.saveBook(&updatedBook)
                self.currentBook = updatedBook
            } catch {
                print("Failed to save book progress: \(error)")
            }
        }
    }

    func recordReadingProgress(
        chapter: Chapter,
        currentPercent: Double,
        furthestPercent: Double,
        scrollOffset: Double
    ) {
        guard let book = currentBook, let chapterId = chapter.id else { return }
        let bookId = book.id

        let clampedCurrent = max(0, min(currentPercent, 1))
        let clampedFurthest = max(0, min(furthestPercent, 1))
        let effectiveFurthest = max(clampedFurthest, clampedCurrent)

        pendingProgressSaveTask?.cancel()
        pendingProgressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let chapterCount = max(1, book.chapterCount)
            let chapterIndex = min(max(chapter.index, 0), chapterCount - 1)

            let previousMax = min(max(maxScrollCache[chapterId] ?? chapter.maxScrollReached, 0), 1)
            if effectiveFurthest > previousMax {
                let cachedWordCount = bookId.flatMap { bookProgressCache[$0]?.chapterWordCounts[chapterId] }
                let wordCount = cachedWordCount ?? chapter.wordCount
                let previousWords = Int((Double(wordCount) * previousMax).rounded())
                let currentWords = Int((Double(wordCount) * effectiveFurthest).rounded())
                let wordDelta = currentWords - previousWords
                if wordDelta > 0 {
                    self.addWords(wordDelta)
                    if let bookId, var cache = bookProgressCache[bookId], cache.totalWords > 0 {
                        cache.wordsRead = min(cache.totalWords, cache.wordsRead + wordDelta)
                        bookProgressCache[bookId] = cache
                    }
                }

                var updatedChapter = chapter
                updatedChapter.maxScrollReached = effectiveFurthest
                try? database.saveChapter(&updatedChapter)
                maxScrollCache[chapterId] = effectiveFurthest
            }

            let overallProgress: Double
            if let bookId, let cache = bookProgressCache[bookId], cache.totalWords > 0 {
                overallProgress = min(max(Double(cache.wordsRead) / Double(cache.totalWords), 0), 1)
            } else {
                let chapterProgress = Double(chapterIndex) + effectiveFurthest
                overallProgress = min(max(chapterProgress / Double(chapterCount), 0), 1)
            }

            var updatedBook = book
            updatedBook.currentChapter = chapterIndex
            updatedBook.currentScrollPercent = clampedCurrent
            updatedBook.currentScrollOffset = scrollOffset
            updatedBook.progressPercent = overallProgress
            updatedBook.lastReadAt = Date()

            do {
                try database.saveBook(&updatedBook)
                self.currentBook = updatedBook
            } catch {
                print("Failed to save book progress: \(error)")
            }
        }
    }

    // MARK: - Persistence

    func saveSplitRatio() {
        UserDefaults.standard.set(splitRatio, forKey: "splitRatio")
    }
}

// MARK: - Enums & Models

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

    /// Returns proportional guidance string based on chapter word count
    func proportionalGuidance(wordCount: Int) -> String {
        let target = max(3, wordCount / wordsPerInsight)
        let minTarget = max(2, target - 2)
        let maxTarget = target + 3

        return """
        This chapter is ~\(wordCount) words. For \(rawValue) density, aim for roughly \(minTarget)-\(maxTarget) insights—but only if the content supports it. Fewer quality insights beats padding with generic observations.
        """
    }
}

enum ReasoningLevel: String, Codable, CaseIterable {
    case off = "Off"
    case minimal = "Minimal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "Extra High"

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
    var smartAutoScrollEnabled: Bool = true
    var autoScrollHighlightEnabled: Bool = true
    var activeContentBorderEnabled: Bool = false
    var showReadingSpeedFooter: Bool = true
    var useCheapestModelForClassification: Bool = true

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

struct LLMModel {
    let id: String
    let name: String
}

enum LLMProvider: String, Codable, CaseIterable {
    case google = "Google"
    case openai = "OpenAI"
    case anthropic = "Anthropic"

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

        var models: [LLMModel] {

            switch self {

            case .google:

                return [

                    LLMModel(id: "gemini-3-flash-preview", name: "Gemini 3 Flash"),

                    LLMModel(id: "gemini-3-pro-preview", name: "Gemini 3 Pro")

                ]

            case .openai:

                return [

                    LLMModel(id: "gpt-5.2", name: "GPT 5.2")

                ]

            case .anthropic:

                return [

                    LLMModel(id: "claude-haiku-4-5", name: "Claude 4.5 Haiku"),

                    LLMModel(id: "claude-sonnet-4-5", name: "Claude 4.5 Sonnet"),

                    LLMModel(id: "claude-opus-4-5", name: "Claude 4.5 Opus")

                ]

            }

        }

    }

    

    enum ImageModel: String, Codable, CaseIterable {

        case gemini3Pro = "Gemini 3 Pro"

        case gemini25Flash = "Gemini 2.5 Flash"

    

        var apiModel: String {

            switch self {

            case .gemini3Pro: return "gemini-3-pro-image-preview"

            case .gemini25Flash: return "gemini-2.5-flash-image"

            }

        }

    

        var description: String {

            switch self {

            case .gemini3Pro: return "Best quality, slower"

            case .gemini25Flash: return "Fast, good quality"

            }

        }

    }

    
