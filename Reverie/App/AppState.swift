import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - App State

@Observable @MainActor
final class AppState {
    static let splitRatioDefaultsKey = "splitRatio"

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

    private(set) var libraryRefreshTrigger = 0

    // UI State
    var showImportSheet = false
    var splitRatio: CGFloat = 0.65 {  // Persisted
        didSet {
            saveSplitRatio()
        }
    }

    // Processing State
    var isProcessingBook = false
    var processingProgress: Double = 0
    var processingChapter: String = ""
    var processingBookId: Int64?
    var processingTotalChapters: Int = 0
    var processingCompletedChapters: Int = 0
    var processingTask: Task<Void, Never>?
    var processingCostTracker = ProcessingCostTracker()
    var processingCostEstimate: Double {
        get { processingCostTracker.processingCostEstimate }
        set { processingCostTracker.processingCostEstimate = newValue }
    }
    var processingInFlightSummaries: Int = 0
    var processingInFlightInsights: Int = 0
    var processingInFlightImages: Int = 0

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

    // Progress Tracking
    let progressTracker: ProgressTracker

    @MainActor
    init(database: DatabaseService? = nil) {
        let db = database ?? DatabaseService.shared
        self.database = db
        // Initialize progressTracker early (it's a let property), then set up
        // the callback later once self is fully initialized.
        self.progressTracker = ProgressTracker(database: db)
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
        if let ratio = UserDefaults.standard.object(forKey: Self.splitRatioDefaultsKey) as? Double {
            self.splitRatio = CGFloat(ratio)
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
        
        // Set up the words-read callback now that self is fully initialized.
        self.progressTracker.onWordsRead = { [weak self] wordDelta in
            self?.addWords(wordDelta)
        }
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
        triggerLibraryRefresh()
    }

    func openSettings() {
        currentScreen = .settings
    }

    func openStats() {
        currentScreen = .stats
    }

    func goHome() {
        currentScreen = .home
        triggerLibraryRefresh()
    }

    func triggerLibraryRefresh() {
        libraryRefreshTrigger += 1
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

    func updateProcessingCost(inputTokens: Int, outputTokens: Int, reasoningTokens: Int = 0, cachedTokens: Int = 0, cacheWriteTokens: Int = 0, model: String) {
        processingCostTracker.updateProcessingCost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cachedTokens: cachedTokens,
            cacheWriteTokens: cacheWriteTokens,
            model: model
        )
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
        if let updatedBook = progressTracker.flushPendingProgress(currentBook: currentBook) {
            currentBook = updatedBook
        }
    }

    // MARK: - Progress Tracking (Throttled)

    func updateBookProgressCache(book: Book, chapters: [Chapter]) {
        progressTracker.updateBookProgressCache(book: book, chapters: chapters)
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
        progressTracker.recordReadingProgress(
            chapter: chapter,
            currentPercent: currentPercent,
            furthestPercent: furthestPercent,
            scrollOffset: scrollOffset,
            bookId: bookId,
            whenReadyToFlush: { [weak self] in
                self?.flushPendingProgress()
            }
        )
    }

    // MARK: - Persistence

    func saveSplitRatio() {
        UserDefaults.standard.set(Double(splitRatio), forKey: Self.splitRatioDefaultsKey)
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
            try database.updateBookImportStatus(id: bookId, status: .complete)

            if let updatedBook = try? database.fetchBook(id: bookId) {
                await MainActor.run {
                    if self.currentBook?.id == bookId {
                        self.currentBook = updatedBook
                    }
                    self.triggerLibraryRefresh()
                }
            } else {
                await MainActor.run {
                    self.triggerLibraryRefresh()
                }
            }
        } catch {
            print("Failed to finalize chapter import: \(error)")
            _ = try? database.updateBookImportStatus(id: bookId, status: .failed)

            await MainActor.run {
                self.triggerLibraryRefresh()
            }
        }
    }
}


