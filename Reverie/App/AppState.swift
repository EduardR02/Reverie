import SwiftUI
import GRDB
#if os(macOS)
import AppKit
#endif

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

    var libraryNeedsRefresh = false

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
                libraryNeedsRefresh = true
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
    nonisolated let database: DatabaseService
    var databaseError: Error?
    var llmService: LLMService
    var imageService: ImageService
    let readingSpeedTracker: ReadingSpeedTracker

    // Settings
    var settings: UserSettings

    // Reading Stats
    var readingStats: ReadingStats
    
    // Throttled Progress Save
    private struct PendingProgress {
        let bookId: Int64
        let chapter: Chapter
        let currentPercent: Double
        let furthestPercent: Double
        let scrollOffset: Double
    }
    private var pendingProgress: PendingProgress?
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

        #if os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingProgress()
            }
        }
        #endif
    }

    // MARK: - Navigation

    func openBook(_ book: Book) {
        flushPendingProgress()
        currentBook = book
        let maxIndex = max(0, book.chapterCount - 1)
        currentChapterIndex = min(max(book.currentChapter, 0), maxIndex)
        currentScreen = .reader(book)
    }

    func closeBook() {
        flushPendingProgress()
        currentBook = nil
        currentScreen = .home
        libraryNeedsRefresh = true
    }

    func openSettings() {
        currentScreen = .settings
    }

    func openStats() {
        currentScreen = .stats
    }

    func goHome() {
        currentScreen = .home
        libraryNeedsRefresh = true
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

    func addTokens(input: Int, reasoning: Int, output: Int, cached: Int) {
        readingStats.addTokens(input: input, reasoning: reasoning, output: output, cached: cached)
        saveStats()
    }

    func updateProcessingCost(inputTokens: Int, outputTokens: Int, reasoningTokens: Int = 0, cachedTokens: Int = 0, model: String) {
        guard let pricing = PricingCatalog.textPricing(for: model) else { return }
        
        let uncachedTokens = max(0, inputTokens - cachedTokens)
        let uncachedCost = (Double(uncachedTokens) / 1_000_000) * pricing.inputPerMToken
        let cachedCost = (Double(cachedTokens) / 1_000_000) * (pricing.inputPerMToken * pricing.cachedInputMultiplier)
        
        let inputCost = uncachedCost + cachedCost
        
        // Reasoning tokens are billed as output for Gemini
        let totalOutput = outputTokens + reasoningTokens
        let outputCost = (Double(totalOutput) / 1_000_000) * pricing.outputPerMToken
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

    func flushPendingProgress() {
        guard let pending = pendingProgress,
              let chapterId = pending.chapter.id else { return }
        
        let bookId = pending.bookId
        self.pendingProgress = nil
        self.pendingProgressSaveTask?.cancel()
        self.pendingProgressSaveTask = nil

        var book: Book?
        let isCurrentBook = currentBook?.id == bookId
        if isCurrentBook {
            book = currentBook
        } else {
            book = try? database.fetchBook(id: bookId)
        }
        
        guard var updatedBook = book else { return }

        let chapterCount = max(1, updatedBook.chapterCount)
        let chapterIndex = min(max(pending.chapter.index, 0), chapterCount - 1)

        let currentPercent = min(max(pending.currentPercent, 0), 1)
        let furthestPercent = min(max(pending.furthestPercent, 0), 1)
        let effectiveFurthest = max(furthestPercent, currentPercent)
        let previousMax = min(max(maxScrollCache[chapterId] ?? pending.chapter.maxScrollReached, 0), 1)
        
        if effectiveFurthest > previousMax {
            let cachedWordCount = bookProgressCache[bookId]?.chapterWordCounts[chapterId]
            let wordCount = cachedWordCount ?? pending.chapter.wordCount
            let previousWords = Int((Double(wordCount) * previousMax).rounded())
            let currentWords = Int((Double(wordCount) * effectiveFurthest).rounded())
            let wordDelta = currentWords - previousWords
            if wordDelta > 0 {
                self.addWords(wordDelta)
                if var cache = bookProgressCache[bookId], cache.totalWords > 0 {
                    cache.wordsRead = min(cache.totalWords, cache.wordsRead + wordDelta)
                    bookProgressCache[bookId] = cache
                }
            }

            var updatedChapter = pending.chapter
            updatedChapter.maxScrollReached = effectiveFurthest
            try? database.saveChapter(&updatedChapter)
            maxScrollCache[chapterId] = effectiveFurthest
        }

        let overallProgress: Double
        if let cache = bookProgressCache[bookId], cache.totalWords > 0 {
            overallProgress = min(max(Double(cache.wordsRead) / Double(cache.totalWords), 0), 1)
        } else {
            let chapterProgress = Double(chapterIndex) + effectiveFurthest
            overallProgress = min(max(chapterProgress / Double(chapterCount), 0), 1)
        }

        updatedBook.currentChapter = chapterIndex
        updatedBook.currentScrollPercent = currentPercent
        updatedBook.currentScrollOffset = pending.scrollOffset
        updatedBook.progressPercent = overallProgress
        updatedBook.lastReadAt = Date()

        do {
            try database.saveBook(&updatedBook)
            if isCurrentBook {
                self.currentBook = updatedBook
            }
        } catch {
            print("Failed to save book progress: \(error)")
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
        recordReadingProgress(
            chapter: chapter,
            currentPercent: scrollPercent,
            furthestPercent: scrollPercent,
            scrollOffset: scrollOffset
        )
    }

    func recordReadingProgress(
        chapter: Chapter,
        currentPercent: Double,
        furthestPercent: Double,
        scrollOffset: Double
    ) {
        guard let bookId = currentBook?.id, chapter.id != nil else { return }

        pendingProgress = PendingProgress(
            bookId: bookId,
            chapter: chapter,
            currentPercent: currentPercent,
            furthestPercent: furthestPercent,
            scrollOffset: scrollOffset
        )

        pendingProgressSaveTask?.cancel()
        pendingProgressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                flushPendingProgress()
            }
        }
    }

    // MARK: - Persistence

    func saveSplitRatio() {
        UserDefaults.standard.set(splitRatio, forKey: "splitRatio")
    }

    // MARK: - Import

    nonisolated func finalizeChapterImport(book: Book, metadata: EPUBParser.ParsedMetadata, opfPath: String) async {
        let parser = EPUBParser()
        guard let bookId = book.id else { return }
        
        let rootURL = LibraryPaths.publicationDirectory(for: bookId)
        let opfURL = rootURL.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        do {
            var importItems: [(chapter: Chapter, footnotes: [Footnote])] = []

            for skeleton in metadata.chapters {
                do {
                    let parsed = try parser.parseChapter(skeleton, opfDir: opfDir, rootURL: rootURL)

                    let chapter = Chapter(
                        bookId: bookId,
                        index: parsed.index,
                        title: parsed.title,
                        contentHTML: parsed.htmlContent,
                        resourcePath: parsed.resourcePath,
                        wordCount: parsed.wordCount
                    )

                    let footnotes = parsed.footnotes.map { parsedFootnote in
                        Footnote(
                            chapterId: 0,
                            marker: parsedFootnote.marker,
                            content: parsedFootnote.content,
                            refId: parsedFootnote.refId,
                            sourceBlockId: parsedFootnote.sourceBlockId
                        )
                    }

                    importItems.append((chapter, footnotes))
                } catch {
                    print("Skipping malformed chapter: \(skeleton.title) - \(error)")
                }
            }

            if importItems.isEmpty {
                throw EPUBParser.ParseError.invalidStructure
            }

            try database.importChapters(importItems)

            // Update book status
            if var updatedBook = try database.fetchBook(id: bookId) {
                updatedBook.importStatus = .complete
                try database.saveBook(&updatedBook)
                
                let finalUpdatedBook = updatedBook
                await MainActor.run {
                    if self.currentBook?.id == bookId {
                        self.currentBook = finalUpdatedBook
                    }
                    
                    self.libraryNeedsRefresh = true
                }
            }
        } catch {
            print("Failed to finalize chapter import: \(error)")
            if var failedBook = try? database.fetchBook(id: bookId) {
                failedBook.importStatus = .failed
                try? database.saveBook(&failedBook)
                
                await MainActor.run {
                    self.libraryNeedsRefresh = true
                }
            }
        }
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
    var smartAutoScrollEnabled: Bool = false
    var autoScrollHighlightEnabled: Bool = true
    var activeContentBorderEnabled: Bool = false
    var showReadingSpeedFooter: Bool = true
    var useCheapestModelForClassification: Bool = true
    var autoAIProcessingEnabled: Bool = true

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
