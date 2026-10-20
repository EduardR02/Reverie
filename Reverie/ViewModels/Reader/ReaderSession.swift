import Foundation
import SwiftUI
import AppKit

@Observable @MainActor
final class ReaderSession {
    private struct ChapterContentSource: Equatable, Sendable {
        let text: String?
        let html: String

        init(_ chapter: Chapter) {
            text = chapter.contentText
            html = chapter.contentHTML
        }
    }

    private struct CachedChapterBaseContent {
        let source: ChapterContentSource
        let content: ChapterBaseContent
    }

    private struct ChapterBaseContent: Sendable {
        let blocks: [ContentBlock]
        let wordCounts: [Int]
        let normalizedBlockTexts: [String]

        static func build(contentText: String?, html: String) -> ChapterBaseContent {
            let blocks = ReaderSession.logicalBlocks(contentText: contentText, html: html)
            return ChapterBaseContent(
                blocks: blocks,
                wordCounts: blocks.map { ReaderSession.wordCount(in: $0.text) },
                normalizedBlockTexts: blocks.map { ReaderSession.normalizedText($0.text) }
            )
        }
    }

    private struct ChapterBaseContentTask {
        let id = UUID()
        let source: ChapterContentSource
        let task: Task<ChapterBaseContent, Never>
    }

    private struct AnalysisTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct PendingImages {
        let suggestions: [LLMService.ImageSuggestion]
        let book: Book
        let chapter: Chapter
        let existingImageIDs: Set<Int64>
    }

    private(set) var autoScroll = AutoScrollEngine()
    private(set) var rsvpEngine = RSVPEngine()
    private(set) var analyzer: ChapterAnalyzer?
    private weak var appState: AppState?
    
    var chapters: [Chapter] = [] {
        didSet { chaptersDidChange(from: oldValue) }
    }
    var currentChapter: Chapter?
    var annotations: [Annotation] = [] {
        didSet {
            orderedAnnotationItems = AIPanelListOrder.orderedAnnotationItems(annotations)
            chapterAssetsDidChange()
        }
    }
    var quizzes: [Quiz] = [] {
        didSet { orderedQuizItems = AIPanelListOrder.orderedQuizItems(quizzes) }
    }
    var footnotes: [Footnote] = []
    var images: [GeneratedImage] = [] {
        didSet {
            sortedImages = AIPanelListOrder.sortedImages(images)
            chapterAssetsDidChange()
        }
    }
    private(set) var orderedAnnotationItems: [AIPanelIndexedItem] = []
    private(set) var orderedQuizItems: [AIPanelIndexedItem] = []
    private(set) var sortedImages: [GeneratedImage] = []
    
    var currentAnnotationId: Int64?
    var currentImageId: Int64?
    var currentFootnoteRefId: String?
    var scrollToAnnotationId: Int64?
    var scrollToPercent: Double?
    var scrollToOffset: Double?
    var scrollToBlockId: (Int, Int64?, String?)?
    var scrollToQuote: String?
    var scrollByAmount: Double?
    var scrollToLocation: BlockLocation?
    private(set) var pageTurnRequests: [ReaderPageTurnRequest] = []
    private var nextPageTurnID = 1
    private(set) var pageIndex: Int?
    private(set) var pageCount: Int?
    private(set) var visiblePageCount = 1
    private(set) var pageCapacity = 1
    private(set) var visibleAnnotationIds: Set<Int64> = []
    private(set) var visibleImageIds: Set<Int64> = []
    private var bookPages: ReaderBookPages?
    private(set) var bookPaginationFailed = false
    private var lastPaginationMeasurement: ReaderPaginationMeasurement?
    private var bookPaginator: ReaderBookPaginator?
    // One compact geometry snapshot per chapter in the current book, never per viewport.
    // Store successful inline images even when disabled so toggling needs no DB sweep.
    private var paginationDecorationsByChapter: [Int64: BookContentDecorationState] = [:]
    private var finalPageChapterIndex: Int?
    private var pendingBoundaryPage: (chapterIndex: Int, finalScreen: Bool)?
    var pageLayout: ReaderPageLayout { appState?.settings.pageLayout ?? .spread }
    var bookPageCount: Int? { readingMode == .pages ? bookPages?.total : nil }
    var bookPageNumber: Int? {
        guard readingMode == .pages else { return nil }
        if let pending = pendingBoundaryPage, let pages = bookPages,
           pages.chapterCounts.indices.contains(pending.chapterIndex) {
            let screen = pending.finalScreen ? pages.chapterCounts[pending.chapterIndex] - 1 : 0
            return pages.position(chapterIndex: pending.chapterIndex, columnIndex: screen, columnsPerScreen: 1)
        }
        guard let pageIndex,
              let chapterIndex = chapters.firstIndex(where: { $0.id == currentChapter?.id }) else { return nil }
        return bookPages?.position(chapterIndex: chapterIndex, columnIndex: pageIndex, columnsPerScreen: pageCapacity)
    }
    var readingMode: ReaderReadingMode { appState?.settings.readingMode ?? .scroll }
    var isOnLastPage: Bool {
        guard let pageIndex, let pageCount else { return false }
        return pageIndex + visiblePageCount >= pageCount
    }
    var isQuizAvailable: Bool {
        readingMode != .pages || isRSVPMode || isOnLastPage
    }
    var canAdvancePage: Bool {
        guard pageIndex != nil, pageCount != nil else { return false }
        return !isOnLastPage || canOfferPageQuiz || (appState?.currentChapterIndex ?? 0) < chapters.count - 1
    }
    private var canOfferPageQuiz: Bool {
        isAIPanelVisible && appState?.settings.autoSwitchToQuiz == true && !quizzes.isEmpty &&
            !hasAutoSwitchedToQuiz && aiPanelSelectedTab != .quiz
    }
    var pendingAnchor: String?
    var pendingMarkerInjections: [MarkerInjection] = []
    var pendingImageMarkerInjections: [ImageMarkerInjection] = []
    var isAtChapterBottom: Bool = false
    var isRSVPMode = false
    var lastScrollPercent: Double = 0
    var lastScrollOffset: Double = 0
    var didRestoreInitialPosition = false
    var isProgrammaticScroll = false
    
    var savedScrollOffset: Double?
    private var savedLocation: BlockLocation?
    var showBackButton = false
    var backAnchorState: BackAnchorState = .inactive
    enum BackAnchorState { case inactive, pending, away }
    
    var externalTabSelection: AIPanel.Tab? {
        didSet {
            if externalTabSelection == .quiz && !isQuizAvailable { externalTabSelection = nil }
        }
    }
    var hasAutoSwitchedToQuiz = false
    var aiPanelSelectedTab: AIPanel.Tab = .insights {
        didSet {
            if pageIndex == nil { preserveInitialPageTabSelection = true }
            if aiPanelSelectedTab == .quiz && !isQuizAvailable { aiPanelSelectedTab = .insights }
        }
    }
    var pendingChatPrompt: String?
    var isChatInputFocused = false {
        didSet {
            if !isAIPanelVisible && isChatInputFocused { isChatInputFocused = false }
        }
    }
    private(set) var isAIPanelVisible = true
    var lastAutoSwitchAt: TimeInterval = 0
    var suppressContextAutoSwitchUntil: TimeInterval = 0
    private var preserveInitialPageTabSelection = false
    
    var calculatorCache = ProgressCalculatorCache()
    private var baseContentByChapter: [Int64: CachedChapterBaseContent] = [:]
    private var baseContentOrder: [Int64] = []
    private let baseContentCacheLimit = 20
    private var didLoadChapterAssets = false
    var currentLocation: BlockLocation?
    var furthestLocation: BlockLocation?
    var currentProgressPercent: Double = 0
    var furthestProgressPercent: Double = 0
    
    private var readingTickTask: Task<Void, Never>?
    private var autoScrollTickTask: Task<Void, Never>?
    private var chapterLoadTask: Task<Void, Never>?
    private var rsvpLoadTask: Task<Void, Never>?
    private var baseContentTasks: [Int64: ChapterBaseContentTask] = [:]
    private var analysisTasks: [Int64: AnalysisTask] = [:]
    private var aiTasks: [UUID: Task<Void, Never>] = [:]
    private var classificationTask: AnalysisTask?
    private var aiGeneration = UUID()
    private var forcedAnalysisChapterIDs: Set<Int64> = []
    private var resumeManualClassification = false
    private var pendingImages: [UUID: PendingImages] = [:]
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    
    #if DEBUG
    /// Number of tracked background tasks. For test inspection only.
    var backgroundTaskCount: Int { backgroundTasks.count }
    private(set) var baseContentBuildCount = 0
    private(set) var paginationAssetFetchCount = 0
    var cachedBaseContentChapterIDs: [Int64] { baseContentOrder }
    #endif
    private var isCleaningUp = false
    var showChapterList = false
    var expandedImage: GeneratedImage?
    var loadError: String?
    var isLoadingChapters = true
    private var loadedRSVPChapterId: Int64?

    func setup(with appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        self.analyzer = ChapterAnalyzer(llm: appState.llmService, imageService: appState.imageService, database: appState.database, settings: appState.settings)
        autoScroll.configure(speedTracker: appState.readingSpeedTracker, settings: appState.settings)
        rsvpEngine.setWPM(appState.readingSpeedTracker.manualAutoScrollWPM)
        if appState.settings.rsvpEnabled {
            isRSVPMode = true
            autoScroll.stop()
        }
        startAutoScrollTicker()
    }
    
    func startAutoScrollTicker() {
        autoScrollTickTask?.cancel()
        autoScrollTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !self.isCleaningUp else { break }
                guard self.readingMode == .scroll, !self.isRSVPMode, self.autoScroll.isActive else { continue }
                guard let chapterId = self.currentChapter?.id, let calculator = self.calculatorCache.get(for: chapterId) else { continue }
                if let amount = self.autoScroll.calculateScrollAmount(currentOffset: self.lastScrollOffset, currentLocation: self.currentLocation, calculator: calculator) {
                    self.scrollByAmount = amount
                }
            }
        }
    }
    
    /// Registers a background task that auto-removes from the registry on completion.
    /// Cancelled tasks are filtered out before adding the new task.
    func trackBackgroundTask(_ task: Task<Void, Never>) {
        backgroundTasks = backgroundTasks.filter { !$0.value.isCancelled }
        let id = UUID()
        backgroundTasks[id] = task
        // Schedule removal when the task completes
        Task { @MainActor [weak self, id] in
            _ = await task.value
            self?.backgroundTasks.removeValue(forKey: id)
        }
    }

    private var canRunAI: Bool {
        isAIPanelVisible && !isCleaningUp && !Task.isCancelled
    }

    private func canRunAI(generation: UUID) -> Bool {
        canRunAI && aiGeneration == generation
    }

    private func trackAITask(_ task: Task<Void, Never>) {
        let id = UUID()
        aiTasks[id] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.aiTasks.removeValue(forKey: id)
        }
    }

    func setAIPanelVisible(_ visible: Bool) {
        guard visible != isAIPanelVisible, !isCleaningUp else { return }
        isAIPanelVisible = visible
        if !visible {
            isChatInputFocused = false
            pendingChatPrompt = nil
            appState?.readingSpeedTracker.endPause(reason: .chatting)
            cancelReaderAI()
            if rsvpEngine.pendingPauseContent != nil { rsvpEngine.play() }
            return
        }

        refreshSavedAIContent()
        if aiPanelSelectedTab == .chat {
            appState?.readingSpeedTracker.startPause(reason: .chatting)
        }
        startClassification(force: resumeManualClassification)
        processCurrentChapter()
        for (id, images) in pendingImages { generateImages(id: id, pending: images) }
    }

    private func cancelReaderAI() {
        aiGeneration = UUID()
        classificationTask?.task.cancel()
        classificationTask = nil
        for (chapterId, work) in analysisTasks {
            work.task.cancel()
            invalidatePaginationAssets(for: chapterId)
        }
        analysisTasks.removeAll()
        for task in aiTasks.values { task.cancel() }
        aiTasks.removeAll()
        analyzer?.cancelAll()
    }

    private func refreshSavedAIContent() {
        guard let appState, let book = appState.currentBook, let bookId = book.id else { return }
        if let freshBook = try? appState.database.fetchBook(id: bookId) {
            appState.currentBook = freshBook
        }
        if let fresh = try? appState.database.fetchChapters(for: book) {
            chapters = fresh
            if let id = currentChapter?.id, let chapter = fresh.first(where: { $0.id == id }) {
                currentChapter = chapter
            }
        }
        guard let chapter = currentChapter else { return }
        if let saved = try? appState.database.fetchAnnotations(for: chapter) { annotations = saved }
        if let saved = try? appState.database.fetchQuizzes(for: chapter) { quizzes = saved }
        if let saved = try? appState.database.fetchImages(for: chapter) { images = saved }
        ensureProgressCalculator(for: chapter)
        if isRSVPMode {
            scheduleRSVPContentLoad(for: chapter, annotations: annotations, images: images, footnotes: footnotes)
        }
    }
    
    func cleanup() {
        isCleaningUp = true
        scrollByAmount = nil
        clearPageState()
        invalidateBookPagination()
        paginationDecorationsByChapter.removeAll()
        scrollToLocation = nil
        readingTickTask?.cancel()
        autoScrollTickTask?.cancel()
        readingTickTask = nil
        autoScrollTickTask = nil
        rsvpLoadTask?.cancel()
        chapterLoadTask?.cancel()
        chapterLoadTask = nil
        for task in baseContentTasks.values { task.task.cancel() }
        baseContentTasks.removeAll()
        cancelReaderAI()
        pendingImages.removeAll()
        baseContentByChapter.removeAll()
        baseContentOrder.removeAll()
        for task in backgroundTasks.values { task.cancel() }
        backgroundTasks.removeAll()
        autoScroll.stop()
        persistCurrentProgress()
        if let result = appState?.readingSpeedTracker.endSession() {
            appState?.readingStats.addReadingTime(result.seconds)
        }
    }

    func loadChapters() async {
        guard let appState = appState, let bookId = appState.currentBook?.id else { return }
        isLoadingChapters = true
        loadError = nil
        didRestoreInitialPosition = false

        // Always fetch fresh from DB to avoid stale data from HomeView's list
        guard var book = try? appState.database.fetchBook(id: bookId) else {
            loadError = "Failed to load book."
            isLoadingChapters = false
            return
        }
        appState.currentBook = book
        
        let start = Date()
        while book.importStatus == .metadataOnly {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(start) > 30 {
                loadError = "Import timed out."
                isLoadingChapters = false
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let fresh = try? appState.database.fetchBook(id: book.id!) {
                book = fresh
                appState.currentBook = fresh
            }
        }

        do {
            chapters = try appState.database.fetchChapters(for: book)
            appState.updateBookProgressCache(book: book, chapters: chapters)
            if chapters.isEmpty {
                loadError = "No chapters found."
                isLoadingChapters = false
                return
            }
            if appState.currentChapterIndex >= chapters.count {
                appState.currentChapterIndex = max(0, chapters.count - 1)
            }
            
            isLoadingChapters = false
            await loadChapter(at: appState.currentChapterIndex)
            
            startClassification()
        } catch {
            loadError = error.localizedDescription
            isLoadingChapters = false
        }
    }

    func loadChapter(at index: Int, force: Bool = false) async {
        guard let appState, appState.currentBook != nil, chapters.indices.contains(index) else { return }
        let requestedChapter = chapters[index]
        // SwiftUI can request the same chapter again after its index changes. A no-op
        // must not cancel a real load, end reading statistics, or reset navigation.
        guard currentChapter?.id != requestedChapter.id || pendingAnchor != nil || force else { return }
        chapterLoadTask?.cancel()
        chapterLoadTask = Task { @MainActor in
            guard let book = appState.currentBook, chapters.indices.contains(index), !isCleaningUp else { return }
            guard !Task.isCancelled else { return }
            let chapter = chapters[index]
            let sameChapter = currentChapter?.id == chapter.id
            guard !sameChapter || pendingAnchor != nil || force else { return }
            if !sameChapter, let result = appState.readingSpeedTracker.endSession() {
                appState.readingStats.addReadingTime(result.seconds)
            }
            guard !Task.isCancelled else { return }
            
            // The remaining load is synchronous on the main actor; chapter assets
            // become visible together before any detached parsing can complete.
            if !sameChapter {
                cancelAnalysis()
                pendingMarkerInjections.removeAll()
                pendingImageMarkerInjections.removeAll()
                rsvpLoadTask?.cancel()
                loadedRSVPChapterId = nil
                rsvpEngine.unloadChapter()
            }
            let boundaryPage = pendingBoundaryPage?.chapterIndex == index && pendingAnchor == nil ? pendingBoundaryPage : nil
            let preserveInitialTab = pageIndex == nil && preserveInitialPageTabSelection
            didLoadChapterAssets = false
            currentChapter = chapter
            clearPageState()
            preserveInitialPageTabSelection = preserveInitialTab
            pendingBoundaryPage = boundaryPage
            scrollByAmount = nil
            scrollToAnnotationId = nil
            scrollToBlockId = nil
            scrollToQuote = nil
            scrollToLocation = nil
            isAtChapterBottom = false
            autoScroll.updateMarkers([])
            hasAutoSwitchedToQuiz = false
            if readingMode == .scroll { externalTabSelection = .insights }
            currentAnnotationId = nil
            currentImageId = nil
            currentFootnoteRefId = nil
            showBackButton = false
            savedScrollOffset = nil
            savedLocation = nil
            backAnchorState = .inactive
            lastAutoSwitchAt = 0
            if readingMode == .scroll { suppressContextAutoSwitchUntil = 0 }
            let landingOnFinalPage = finalPageChapterIndex == index
            finalPageChapterIndex = nil
            
            if let anchor = pendingAnchor {
                scrollToOffset = nil
                scrollToPercent = nil
                scrollToQuote = anchor
                pendingAnchor = nil
                lastScrollPercent = 0; lastScrollOffset = 0
                didRestoreInitialPosition = true
            } else if sameChapter {
                if force {
                    if let currentLocation {
                        scrollToLocation = currentLocation
                        scrollToOffset = nil
                        scrollToPercent = nil
                    } else if lastScrollOffset > 0 { scrollToOffset = lastScrollOffset }
                    else { scrollToPercent = lastScrollPercent }
                    didRestoreInitialPosition = true
                }
            } else {
                let restoring = !landingOnFinalPage && !didRestoreInitialPosition && index == book.currentChapter
                if restoring {
                    if let blockId = book.currentBlockId {
                        scrollToLocation = BlockLocation(blockId: blockId, offset: book.currentBlockOffset ?? 0)
                        scrollToOffset = nil
                        scrollToPercent = nil
                    } else if book.currentScrollOffset > 0 {
                        scrollToOffset = book.currentScrollOffset
                    } else {
                        scrollToPercent = book.currentScrollPercent
                    }
                    lastScrollPercent = book.currentScrollPercent
                    lastScrollOffset = book.currentScrollOffset
                    didRestoreInitialPosition = true
                } else {
                    scrollToPercent = 0; scrollToOffset = nil; lastScrollPercent = 0; lastScrollOffset = 0
                    if landingOnFinalPage {
                        scrollToPercent = 1
                        lastScrollPercent = 1
                    }
                    if didRestoreInitialPosition {
                        appState.recordReadingProgress(chapter: chapter, currentPercent: lastScrollPercent, furthestPercent: max(chapter.maxScrollReached, lastScrollPercent), scrollOffset: 0)
                    } else { didRestoreInitialPosition = true }
                }
            }
            currentProgressPercent = lastScrollPercent
            furthestProgressPercent = max(chapter.maxScrollReached, currentProgressPercent)
            
            currentLocation = scrollToLocation; furthestLocation = nil
            
            do {
                let loadedAnnotations = try appState.database.fetchAnnotations(for: chapter)
                let loadedQuizzes = try appState.database.fetchQuizzes(for: chapter)
                let loadedFootnotes = try appState.database.fetchFootnotes(for: chapter)
                let loadedImages = try appState.database.fetchImages(for: chapter)
                annotations = loadedAnnotations
                quizzes = loadedQuizzes
                footnotes = loadedFootnotes
                images = loadedImages

                didLoadChapterAssets = true
                if isRSVPMode {
                    scheduleRSVPContentLoad(
                        for: chapter,
                        annotations: annotations,
                        images: images,
                        footnotes: footnotes
                    )
                }
            } catch {
                print("ReaderSession: Failed to load chapter assets: \(error)")
                annotations = []
                quizzes = []
                footnotes = []
                images = []
                didLoadChapterAssets = true
            }
            chapterAssetsDidChange()
            
            ensureProgressCalculator(for: chapter)
            autoScroll.stop()
            processCurrentChapter()
        }
        await chapterLoadTask?.value
    }

    func persistCurrentProgress() {
        guard let appState = appState, let chapter = currentChapter else { return }
        appState.recordReadingProgress(chapter: chapter, currentPercent: currentProgressPercent, furthestPercent: furthestProgressPercent, scrollOffset: lastScrollOffset, location: currentLocation)
    }

    func ensureProgressCalculator(for chapter: Chapter) {
        if let chapterId = chapter.id,
           baseContentByChapter[chapterId]?.source == ChapterContentSource(chapter) {
            refreshProgressCalculator(for: chapter)
            return
        }

        let task = Task { @MainActor in
            _ = await self.baseContent(for: chapter)
            guard !Task.isCancelled, !self.isCleaningUp,
                  self.currentChapter?.id == chapter.id,
                  self.currentChapter.map(ChapterContentSource.init) == ChapterContentSource(chapter) else { return }
            self.refreshProgressCalculator(for: chapter)
        }
        trackBackgroundTask(task)
    }

    private func refreshProgressCalculator(for chapter: Chapter) {
        guard let id = chapter.id, currentChapter?.id == id, didLoadChapterAssets,
              let cached = baseContentByChapter[id],
              cached.source == ChapterContentSource(chapter),
              !cached.content.wordCounts.isEmpty else { return }
        let baseContent = cached.content

        let combinedCounts = Self.combinedWordCounts(
            baseCounts: baseContent.wordCounts,
            normalizedBaseTexts: baseContent.normalizedBlockTexts,
            annotations: annotations,
            footnotes: footnotes,
            chapterWordCount: chapter.wordCount
        )
        let totalWords = combinedCounts.reduce(0, +)
        guard totalWords > 0 else { return }

        let calculator = ChapterProgressCalculator(wordCounts: combinedCounts, totalWords: totalWords)
        calculatorCache.insert(calculator, for: id, protecting: currentChapter?.id)

        if currentChapter?.id == id {
            if let loc = currentLocation { currentProgressPercent = calculator.percent(for: loc) }
            if let floc = furthestLocation { furthestProgressPercent = max(furthestProgressPercent, calculator.percent(for: floc)) }
            if isAtChapterBottom { currentProgressPercent = 1; furthestProgressPercent = 1 }
            lastScrollPercent = currentProgressPercent
        }

        guard let appState = appState else { return }
        let shouldTrack = !chapter.isGarbage || !appState.settings.autoAIProcessingEnabled
        guard shouldTrack else { return }

        if let session = appState.readingSpeedTracker.currentSession {
            if session.chapterId == id {
                appState.readingSpeedTracker.updateSessionWordCount(totalWords)
            }
        } else if didLoadChapterAssets && currentChapter?.id == id {
            appState.readingSpeedTracker.startSession(chapterId: id, wordCount: totalWords, startPercent: currentProgressPercent)
        }
    }

    private func baseContent(for chapter: Chapter) async -> ChapterBaseContent {
        guard let chapterId = chapter.id else {
            return Self.buildBaseContent(contentText: chapter.contentText, html: chapter.contentHTML)
        }

        let source = ChapterContentSource(chapter)
        if let cached = baseContentByChapter[chapterId], cached.source == source {
            return cached.content
        }

        if let loading = baseContentTasks[chapterId], loading.source == source {
            let content = await loading.task.value
            storeBaseContent(content, source: source, chapterId: chapterId, taskId: loading.id)
            return content
        }

        baseContentTasks[chapterId]?.task.cancel()
        #if DEBUG
        baseContentBuildCount += 1
        #endif
        let loading = ChapterBaseContentTask(source: source, task: Task.detached(priority: .utility) {
            Self.buildBaseContent(contentText: source.text, html: source.html)
        })
        baseContentTasks[chapterId] = loading

        let content = await loading.task.value
        storeBaseContent(content, source: source, chapterId: chapterId, taskId: loading.id)
        return content
    }

    private func storeBaseContent(_ content: ChapterBaseContent, source: ChapterContentSource, chapterId: Int64, taskId: UUID) {
        guard !Task.isCancelled, !isCleaningUp,
              baseContentTasks[chapterId]?.id == taskId else { return }
        baseContentTasks.removeValue(forKey: chapterId)
        if baseContentByChapter[chapterId] == nil { baseContentOrder.append(chapterId) }
        baseContentByChapter[chapterId] = .init(source: source, content: content)
        while baseContentOrder.count > baseContentCacheLimit,
              let index = baseContentOrder.firstIndex(where: { $0 != currentChapter?.id }) {
            baseContentByChapter.removeValue(forKey: baseContentOrder.remove(at: index))
        }
    }

    nonisolated private static func buildBaseContent(contentText: String?, html: String) -> ChapterBaseContent {
        ChapterBaseContent.build(contentText: contentText, html: html)
    }

    nonisolated static func combinedWordCounts(
        baseCounts: [Int],
        baseTexts: [String],
        annotations: [Annotation],
        footnotes: [Footnote],
        chapterWordCount: Int
    ) -> [Int] {
        combinedWordCounts(
            baseCounts: baseCounts,
            normalizedBaseTexts: baseTexts.map(normalizedText),
            annotations: annotations,
            footnotes: footnotes,
            chapterWordCount: chapterWordCount
        )
    }

    nonisolated private static func combinedWordCounts(
        baseCounts: [Int],
        normalizedBaseTexts: [String],
        annotations: [Annotation],
        footnotes: [Footnote],
        chapterWordCount: Int
    ) -> [Int] {
        guard !baseCounts.isEmpty else { return baseCounts }

        var counts = baseCounts
        var extraFootnoteWords = 0

        for annotation in annotations {
            let words = wordCount(in: annotation.title) + wordCount(in: annotation.content)
            guard words > 0 else { continue }
            let index = clampBlockIndex(annotation.sourceBlockId, count: counts.count)
            counts[index] += words
        }

        for footnote in footnotes {
            let normalizedFootnote = normalizedText(footnote.content)
            guard !normalizedFootnote.isEmpty else { continue }
            let isEmbedded = normalizedBaseTexts.contains { $0.contains(normalizedFootnote) }
            guard !isEmbedded else { continue }
            let words = wordCount(in: footnote.content)
            guard words > 0 else { continue }
            let index = clampBlockIndex(footnote.sourceBlockId, count: counts.count)
            counts[index] += words
            extraFootnoteWords += words
        }

        let baseTotal = baseCounts.reduce(0, +)
        if chapterWordCount > baseTotal {
            let residual = chapterWordCount - baseTotal
            let residualAfterFootnotes = max(0, residual - extraFootnoteWords)
            if residualAfterFootnotes > 0, !counts.isEmpty {
                counts[counts.count - 1] += residualAfterFootnotes
            }
        }

        return counts
    }

    nonisolated static func wordCount(in text: String) -> Int {
        let alphanumericCount = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return alphanumericCount / 5
    }

    nonisolated static func normalizedText(_ text: String) -> String {
        let collapsed = text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func clampBlockIndex(_ blockId: Int, count: Int) -> Int {
        let clampedId = min(max(blockId, 1), count)
        return max(0, clampedId - 1)
    }

    nonisolated static func logicalBlocks(contentText: String?, html: String) -> [ContentBlock] {
        if let contentText,
           let cachedBlocks = cachedBlocks(from: contentText),
           !cachedBlocks.isEmpty {
            return cachedBlocks
        }

        return ContentBlockParser().parse(html: html).blocks
    }

    nonisolated static func cachedBlocks(from contentText: String) -> [ContentBlock]? {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\[(\d+)\]\s"#) else {
            return nil
        }

        let nsRange = NSRange(contentText.startIndex..., in: contentText)
        let matches = regex.matches(in: contentText, options: [], range: nsRange)
        guard !matches.isEmpty else {
            let trimmed = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [ContentBlock(
                id: 1,
                text: trimmed,
                htmlStartOffset: 0,
                contentStartOffset: 0,
                contentEndOffset: 0,
                htmlEndOffset: 0
            )]
        }

        var blocks: [ContentBlock] = []
        blocks.reserveCapacity(matches.count)

        for (index, match) in matches.enumerated() {
            guard let markerRange = Range(match.range, in: contentText),
                  let idRange = Range(match.range(at: 1), in: contentText),
                  let blockId = Int(String(contentText[idRange])) else {
                continue
            }

            let contentStart = markerRange.upperBound
            let contentEnd: String.Index

            if index + 1 < matches.count,
               let nextMarkerRange = Range(matches[index + 1].range, in: contentText) {
                contentEnd = nextMarkerRange.lowerBound
            } else {
                contentEnd = contentText.endIndex
            }

            let text = contentText[contentStart..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            blocks.append(ContentBlock(
                id: blockId,
                text: text,
                htmlStartOffset: 0,
                contentStartOffset: 0,
                contentEndOffset: 0,
                htmlEndOffset: 0
            ))
        }

        return blocks
    }

    func startReadingTicker() {
        readingTickTask?.cancel()
        readingTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !self.isCleaningUp else { break }
                self.appState?.readingSpeedTracker.tick()
            }
        }
    }

    func setBackAnchor() {
        if savedScrollOffset == nil {
            savedScrollOffset = lastScrollOffset
            savedLocation = currentLocation
            showBackButton = true
            backAnchorState = .pending
        }
    }

    func dismissBackAnchor() {
        showBackButton = false; savedScrollOffset = nil; savedLocation = nil; backAnchorState = .inactive
    }

    func returnToBackAnchor() {
        if let savedLocation { scrollToLocation = savedLocation }
        else if let offset = savedScrollOffset { scrollToOffset = offset }
        dismissBackAnchor()
    }

    func handleScrollUpdate(context: ScrollContext, chapter: Chapter) {
        guard currentChapter?.id == chapter.id else { return }
        if let pending = pendingBoundaryPage,
           chapters.indices.contains(pending.chapterIndex),
           chapters[pending.chapterIndex].id != chapter.id { return }
        var isInitialPageContext = false
        if readingMode == .pages, let count = context.pageCount, count >= 1,
           let index = context.pageIndex, (0..<count).contains(index) {
            isInitialPageContext = pageIndex == nil
            pageCount = count
            pageIndex = index
            pendingBoundaryPage = nil
            visiblePageCount = min(max(1, context.visiblePageCount), count - index)
            pageCapacity = context.pageCapacity
            visibleAnnotationIds = context.visibleAnnotationIds
            visibleImageIds = context.visibleImageIds
            updateBookPagination(context: context)
        } else if readingMode == .scroll {
            pageCount = nil
            pageIndex = nil
            visiblePageCount = 1
            pageCapacity = 1
            visibleAnnotationIds = []
            visibleImageIds = []
        }
        if !isQuizAvailable {
            if aiPanelSelectedTab == .quiz { aiPanelSelectedTab = .insights }
            if externalTabSelection == .quiz { externalTabSelection = nil }
        }
        isProgrammaticScroll = context.isProgrammatic
        if readingMode == .scroll {
            autoScroll.updateScrollPosition(offset: context.scrollOffset, viewportHeight: context.viewportHeight, scrollHeight: context.scrollHeight, isProgrammatic: context.isProgrammatic)
        }
        
        if context.isProgrammatic && readingMode == .scroll {
            if let aid = context.annotationId { currentAnnotationId = aid }
            if let iid = context.imageId { currentImageId = iid }
            if let fid = context.footnoteRefId { currentFootnoteRefId = fid }
        } else {
            currentAnnotationId = context.annotationId; currentImageId = context.imageId; currentFootnoteRefId = context.footnoteRefId
        }

        var current = context.scrollPercent
        let atBottom = readingMode == .pages ? isOnLastPage : context.scrollPercent >= 1.0
        if isAtChapterBottom != atBottom { isAtChapterBottom = atBottom }
        
        var furthest = max(furthestProgressPercent, current)
        let reportedLocation = context.blockId.map { BlockLocation(blockId: $0, offset: context.blockOffset ?? 0) }
        currentLocation = reportedLocation
        if let location = reportedLocation {
            if let floc = furthestLocation { if floc < location { furthestLocation = location } } else { furthestLocation = location }
            if let id = chapter.id, let calculator = calculatorCache.get(for: id) {
                current = calculator.percent(for: location)
                if let floc = furthestLocation { furthest = max(furthest, calculator.percent(for: floc)) }
            }
        }
        if atBottom { current = 1; furthest = 1 }
        currentProgressPercent = min(max(current, 0), 1)
        furthestProgressPercent = min(max(max(furthest, current), 0), 1)
        lastScrollPercent = currentProgressPercent; lastScrollOffset = context.scrollOffset
        
        appState?.recordReadingProgress(chapter: chapter, currentPercent: currentProgressPercent, furthestPercent: furthestProgressPercent, scrollOffset: context.scrollOffset, location: reportedLocation)
        appState?.readingSpeedTracker.updateSession(scrollPercent: currentProgressPercent)
        if !context.isProgrammatic { appState?.readingSpeedTracker.endAllPauses() }
        
        if showBackButton, let savedLocation, let currentLocation {
            let distance = abs(Double(currentLocation.blockId - savedLocation.blockId) + currentLocation.offset - savedLocation.offset)
            if backAnchorState == .pending && distance > 0.05 { backAnchorState = .away }
            else if backAnchorState == .away && distance <= 0.02 { dismissBackAnchor() }
        } else if showBackButton, let saved = savedScrollOffset {
            let distance = abs(context.scrollOffset - saved)
            let leave = context.viewportHeight > 0 ? max(80, context.viewportHeight * 0.12) : 120
            let returned = context.viewportHeight > 0 ? max(48, context.viewportHeight * 0.06) : 72
            if backAnchorState == .pending && distance > leave { backAnchorState = .away }
            else if backAnchorState == .away && distance <= returned { dismissBackAnchor() }
        }

        if context.scrollPercent < 0.85 { hasAutoSwitchedToQuiz = false }
        handleAutoSwitch(context: context, isInitialPageContext: isInitialPageContext)
    }

    private func handleAutoSwitch(context: ScrollContext, isInitialPageContext: Bool) {
        guard isAIPanelVisible, let appState else { return }
        if isInitialPageContext &&
            (preserveInitialPageTabSelection || aiPanelSelectedTab == .chat || externalTabSelection != nil) { return }
        if appState.settings.autoSwitchFromChatOnScroll && aiPanelSelectedTab == .chat && !context.isProgrammatic {
            aiPanelSelectedTab = .insights
            return
        }
        guard appState.settings.autoSwitchContextTabs, Date().timeIntervalSinceReferenceDate >= suppressContextAutoSwitchUntil, aiPanelSelectedTab != .quiz, aiPanelSelectedTab != .chat else { return }

        // Restoring a page locks focus without a marker target, so its primary
        // type can be absent even though the page already reports visible images.
        let primary = context.primaryType ?? (
            isInitialPageContext && context.visibleAnnotationIds.isEmpty && !context.visibleImageIds.isEmpty
                ? "image" : nil
        )

        let target: AIPanel.Tab? = switch primary {
            case "annotation": .insights
            case "image": .images
            case "footnote": .footnotes
            default: nil
        }

        if let tab = target, tab != aiPanelSelectedTab, Date().timeIntervalSinceReferenceDate - lastAutoSwitchAt >= 0.2 {
            lastAutoSwitchAt = Date().timeIntervalSinceReferenceDate
            withAnimation(.easeOut(duration: 0.2)) { aiPanelSelectedTab = tab }
        }
    }

    func handleQuizAutoSwitchOnTug() {
        if readingMode == .pages {
            guard isOnLastPage else { return }
            if canOfferPageQuiz {
                showChapterQuiz()
            } else if let appState, appState.currentChapterIndex < chapters.count - 1 {
                clearPageState()
                pendingBoundaryPage = (appState.currentChapterIndex + 1, false)
                appState.nextChapter()
            }
            return
        }
        guard isAIPanelVisible, let appState, appState.settings.autoSwitchToQuiz, !quizzes.isEmpty, !hasAutoSwitchedToQuiz, aiPanelSelectedTab != .quiz else { return }
        showChapterQuiz()
    }

    private func showChapterQuiz() {
        guard isAIPanelVisible, isQuizAvailable else { return }
        hasAutoSwitchedToQuiz = true
        suppressContextAutoSwitchUntil = Date().timeIntervalSinceReferenceDate + 1.0
        withAnimation(.easeOut(duration: 0.3)) { self.aiPanelSelectedTab = .quiz }
    }

    func cycleAIPanelTab(direction: Int) {
        guard isAIPanelVisible else { return }
        let tabs = AIPanel.Tab.allCases.filter { $0 != .quiz || isQuizAvailable }
        guard let idx = tabs.firstIndex(of: aiPanelSelectedTab) else { return }
        aiPanelSelectedTab = tabs[(idx + direction + tabs.count) % tabs.count]
    }

    func suppressContextAutoSwitch(for duration: TimeInterval = 2.0) {
        suppressContextAutoSwitchUntil = max(suppressContextAutoSwitchUntil, Date().timeIntervalSinceReferenceDate + duration)
    }
    
    func setPageLayout(_ layout: ReaderPageLayout) {
        guard let appState, appState.settings.pageLayout != layout else { return }
        clearPageState()
        invalidateBookPagination()
        appState.settings.pageLayout = layout
        appState.settings.save()
    }

    private static func samePaginationContent(_ lhs: Chapter, _ rhs: Chapter) -> Bool {
        lhs.id == rhs.id && lhs.bookId == rhs.bookId && lhs.index == rhs.index &&
            lhs.contentHTML == rhs.contentHTML && lhs.resourcePath == rhs.resourcePath
    }

    private func chaptersDidChange(from previous: [Chapter]) {
        guard previous.count != chapters.count || zip(previous, chapters).contains(where: {
            !Self.samePaginationContent($0.0, $0.1) ||
                ChapterContentSource($0.0) != ChapterContentSource($0.1) ||
                $0.0.wordCount != $0.1.wordCount
        }) else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.compactMap { chapter in
            chapter.id.map { ($0, chapter) }
        })
        let currentByID = Dictionary(uniqueKeysWithValues: chapters.compactMap { chapter in
            chapter.id.map { ($0, chapter) }
        })
        paginationDecorationsByChapter = paginationDecorationsByChapter.filter { id, _ in
            guard let old = previousByID[id], let current = currentByID[id] else { return false }
            return Self.samePaginationContent(old, current)
        }
        if previous.count != chapters.count ||
            zip(previous, chapters).contains(where: { !Self.samePaginationContent($0.0, $0.1) }) {
            invalidateBookPagination()
        }
        baseContentByChapter = baseContentByChapter.filter { id, cached in
            currentByID[id].map { ChapterContentSource($0) == cached.source } ?? false
        }
        baseContentOrder.removeAll { baseContentByChapter[$0] == nil }
        for (id, loading) in baseContentTasks {
            if currentByID[id].map(ChapterContentSource.init) != loading.source {
                loading.task.cancel()
                baseContentTasks.removeValue(forKey: id)
            }
        }
        if previous.contains(where: { old in
            guard let id = old.id, let current = currentByID[id] else { return true }
            return ChapterContentSource(old) != ChapterContentSource(current) || old.wordCount != current.wordCount
        }) {
            calculatorCache = ProgressCalculatorCache()
        }
    }

    private func displayedPaginationDecorations(_ decorations: BookContentDecorationState) -> BookContentDecorationState {
        let enabled = appState?.settings.inlineAIImages ?? false
        return .init(
            annotationMarkers: decorations.annotationMarkers,
            imageMarkers: decorations.imageMarkers,
            inlineAIImagesEnabled: enabled,
            inlineImages: enabled ? decorations.inlineImages : []
        )
    }

    private func chapterAssetsDidChange() {
        guard didLoadChapterAssets, let id = currentChapter?.id else { return }
        let decorations = BookContentDecorationState(
            annotations: annotations, images: images, inlineAIImagesEnabled: true,
            pendingMarkers: [], pendingImageMarkers: []
        )
        if let previous = paginationDecorationsByChapter[id],
           displayedPaginationDecorations(previous) != displayedPaginationDecorations(decorations) {
            invalidateBookPagination()
        }
        paginationDecorationsByChapter[id] = decorations
    }

    private func paginationDecorations(for chapter: Chapter) throws -> BookContentDecorationState {
        if let id = chapter.id, let cached = paginationDecorationsByChapter[id] {
            return displayedPaginationDecorations(cached)
        }
        guard let appState else { return .empty }
        #if DEBUG
        paginationAssetFetchCount += 1
        #endif
        let decorations = BookContentDecorationState(
            annotations: try appState.database.fetchAnnotations(for: chapter),
            images: try appState.database.fetchImages(for: chapter),
            inlineAIImagesEnabled: true, pendingMarkers: [], pendingImageMarkers: []
        )
        if let id = chapter.id { paginationDecorationsByChapter[id] = decorations }
        return displayedPaginationDecorations(decorations)
    }

    private func invalidatePaginationAssets(for chapterId: Int64?) {
        guard let chapterId else { return }
        paginationDecorationsByChapter.removeValue(forKey: chapterId)
        invalidateBookPagination()
    }

    private func updateBookPagination(context: ScrollContext) {
        guard let appState else { return }
        if context.paginationFailed {
            invalidateBookPagination()
            bookPaginationFailed = true
            return
        }
        guard let measured = context.paginationMeasurement else {
            if let previous = lastPaginationMeasurement,
               previous.viewportWidth != context.viewportWidth ||
               previous.viewportHeight != context.viewportHeight ||
               (previous.state.document.chapterId == currentChapter?.id &&
                (previous.pageCount != context.pageCount || previous.pageCapacity != context.pageCapacity)) ||
               previous.state.style.fontSize != Double(appState.settings.fontSize) ||
               previous.state.style.fontFamily != appState.settings.fontFamily ||
               previous.state.style.lineSpacing != Double(appState.settings.lineSpacing) ||
               previous.state.pageLayout != appState.settings.pageLayout ||
               previous.state.decorations.inlineAIImagesEnabled != appState.settings.inlineAIImages {
                invalidateBookPagination()
            }
            return
        }
        guard measured != lastPaginationMeasurement else { return }
        lastPaginationMeasurement = measured
        do {
            let states = try chapters.map { chapter -> BookContentViewState in
                if chapter.id == measured.state.document.chapterId { return measured.state }
                let root = LibraryPaths.publicationDirectory(for: chapter.bookId)
                let directory = chapter.resourcePath.flatMap { $0.isEmpty ? nil : root.appendingPathComponent($0).deletingLastPathComponent() } ?? root
                let decorations = try paginationDecorations(for: chapter)
                return BookContentViewState(
                    document: .init(chapterId: chapter.id, chapterIndex: chapter.index,
                                    contentHTML: chapter.contentHTML, baseHref: directory.absoluteString),
                    style: measured.state.style, decorations: decorations,
                    readingMode: .pages, pageLayout: measured.state.pageLayout
                )
            }
            if bookPaginator == nil { bookPaginator = ReaderBookPaginator() }
            bookPaginator?.request(chapters: states, current: measured, onFailure: { [weak self] in
                self?.bookPages = nil
                self?.bookPaginationFailed = true
            }) { [weak self] pages in
                self?.bookPages = pages
                self?.bookPaginationFailed = false
            }
        } catch {
            bookPages = nil
            bookPaginator?.cancel()
            bookPaginationFailed = true
        }
    }

    func setReadingMode(_ mode: ReaderReadingMode) {
        guard let appState else { return }
        if isRSVPMode { setRSVPMode(false) }
        guard appState.settings.readingMode != mode else { return }
        clearPageState()
        invalidateBookPagination()
        scrollByAmount = nil
        if mode == .pages {
            autoScroll.stop()
            appState.settings.smartAutoScrollEnabled = false
        }
        appState.settings.readingMode = mode
        appState.settings.save()
    }

    func readingModeDidChange() {
        clearPageState()
        invalidateBookPagination()
        scrollByAmount = nil
        if readingMode == .pages { autoScroll.stop() }
    }

    private func invalidateBookPagination() {
        bookPages = nil
        bookPaginationFailed = false
        lastPaginationMeasurement = nil
        pendingBoundaryPage = nil
        bookPaginator?.cancel()
    }

    private func clearPageState() {
        preserveInitialPageTabSelection = false
        pageIndex = nil
        pendingBoundaryPage = nil
        pageCount = nil
        visiblePageCount = 1
        pageCapacity = 1
        visibleAnnotationIds = []
        visibleImageIds = []
        pageTurnRequests.removeAll()
        isAtChapterBottom = false
        isProgrammaticScroll = false
        if !isQuizAvailable {
            if aiPanelSelectedTab == .quiz { aiPanelSelectedTab = .insights }
            if externalTabSelection == .quiz { externalTabSelection = nil }
        }
    }

    func turnPage(_ delta: Int) {
        guard readingMode == .pages, !isRSVPMode, pageIndex != nil, delta != 0 else { return }
        if delta < 0, pageIndex == 0 {
            guard let appState, appState.currentChapterIndex > 0 else { return }
            finalPageChapterIndex = appState.currentChapterIndex - 1
            clearPageState()
            pendingBoundaryPage = (appState.currentChapterIndex - 1, true)
            appState.previousChapter()
            return
        }
        if delta > 0, isOnLastPage {
            handleQuizAutoSwitchOnTug()
            return
        }
        pageTurnRequests.append(.init(id: nextPageTurnID, delta: delta))
        nextPageTurnID += 1
    }

    func consumePageTurns(_ ids: [Int]) {
        let consumed = Set(ids)
        pageTurnRequests.removeAll { consumed.contains($0.id) }
    }

    func setAutoScrollEnabled(_ enabled: Bool) {
        guard let appState else { return }
        if enabled {
            setReadingMode(.scroll)
            isRSVPMode = false
            autoScroll.start()
        } else {
            autoScroll.stop()
        }
        appState.settings.smartAutoScrollEnabled = enabled
        appState.settings.save()
    }

    func setRSVPMode(_ enabled: Bool) {
        isRSVPMode = enabled
        if enabled {
            // Disable auto-scroll when entering RSVP
            appState?.settings.smartAutoScrollEnabled = false
            appState?.settings.save()
            autoScroll.stop()

            guard let chapter = currentChapter else { return }
            if loadedRSVPChapterId == chapter.id, !rsvpEngine.words.isEmpty {
                syncRSVPToCurrentPosition()
                return
            }

            scheduleRSVPContentLoad(
                for: chapter,
                annotations: annotations,
                images: images,
                footnotes: footnotes
            )
        } else {
            // Pause RSVP when exiting
            rsvpEngine.pause()
        }
    }

    private func scheduleRSVPContentLoad(
        for chapter: Chapter,
        annotations: [Annotation],
        images: [GeneratedImage],
        footnotes: [Footnote]
    ) {
        rsvpLoadTask?.cancel()

        let chapterId = chapter.id

        rsvpLoadTask = Task { @MainActor in
            let baseContent = await self.baseContent(for: chapter)

            guard !Task.isCancelled,
                  isRSVPMode,
                  currentChapter?.id == chapterId else {
                return
            }

            rsvpEngine.loadChapter(
                blocks: baseContent.blocks,
                annotations: annotations,
                images: images,
                footnotes: footnotes
            )
            loadedRSVPChapterId = chapterId
            syncRSVPToCurrentPosition()
        }
    }
    
    /// Synchronizes the RSVP engine's current word index to the user's current scroll position.
    func syncRSVPToCurrentPosition() {
        guard let blockId = currentLocation?.blockId, !rsvpEngine.words.isEmpty else { return }
        rsvpEngine.sync(toBlockId: blockId)
    }
    
    func handleRSVPPauseContentChange(_ content: PauseContent?) {
        guard let content = content else { return }
        guard isAIPanelVisible else {
            rsvpEngine.play()
            return
        }
        switch content {
        case .insight(let annotation):
            if let id = annotation.id {
                currentAnnotationId = id
                aiPanelSelectedTab = .insights
            }
        case .image(let image):
            if let id = image.id {
                currentImageId = id
                aiPanelSelectedTab = .images
            }
        case .footnote(let footnote):
            currentFootnoteRefId = footnote.refId
            aiPanelSelectedTab = .footnotes
        }
    }

    func handleSpaceBar() -> KeyPress.Result {
        guard !isChatInputFocused else { return .ignored }
        
        // RSVP mode: space toggles play/pause
        if isRSVPMode {
            rsvpEngine.toggle()
            return .handled
        }
        
        if readingMode == .pages {
            turnPage(1)
            return .handled
        }

        // Otherwise toggle auto-scroll (existing behavior)
        appState?.settings.smartAutoScrollEnabled.toggle()
        if let enabled = appState?.settings.smartAutoScrollEnabled, !enabled {
            autoScroll.cancelCountdown()
        }
        return .handled
    }

    func handleReaderKey(_ key: KeyEquivalent, modifiers: EventModifiers = []) -> KeyPress.Result {
        guard !isChatInputFocused else { return .ignored }

        if modifiers.contains(.shift) {
            if key == .leftArrow {
                cycleAIPanelTab(direction: -1)
                return .handled
            }
            if key == .rightArrow {
                cycleAIPanelTab(direction: 1)
                return .handled
            }
        }

        // RSVP mode: arrows skip words (override chapter navigation)
        if isRSVPMode {
            switch key {
            case .leftArrow:
                rsvpEngine.skip(words: -10)
                return .handled
            case .rightArrow:
                rsvpEngine.skip(words: 10)
                return .handled
            default:
                break
            }
        }

        if readingMode == .pages, !isRSVPMode {
            switch key {
            case .leftArrow, .upArrow:
                turnPage(-1)
                return .handled
            case .rightArrow, .downArrow:
                turnPage(1)
                return .handled
            default:
                return .ignored
            }
        }

        switch key {
        case .upArrow:
            scrollByAmount = -200
            return .handled
        case .downArrow:
            scrollByAmount = 200
            return .handled
        case .leftArrow:
            if let appState = appState, appState.currentChapterIndex > 0 {
                appState.currentChapterIndex -= 1
            }
            return .handled
        case .rightArrow:
            if let appState = appState, appState.currentChapterIndex < chapters.count - 1 {
                appState.currentChapterIndex += 1
            }
            return .handled
        default:
            return .ignored
        }
    }

    func handleTabChange(from oldTab: AIPanel.Tab, to newTab: AIPanel.Tab) {
        if newTab == .chat && isAIPanelVisible {
            appState?.readingSpeedTracker.startPause(reason: .chatting)
        } else if oldTab == .chat {
            appState?.readingSpeedTracker.endPause(reason: .chatting)
        }
        if oldTab == .quiz && newTab != .quiz {
            hasAutoSwitchedToQuiz = false
        }
    }

    func handleExpandedImageChange(from oldImage: GeneratedImage?, to newImage: GeneratedImage?) {
        if newImage != nil {
            appState?.readingSpeedTracker.startPause(reason: .viewingImage)
        } else if oldImage != nil {
            appState?.readingSpeedTracker.endPause(reason: .viewingImage)
        }
    }

    func processCurrentChapter(force: Bool = false) {
        guard canRunAI,
              let chapter = currentChapter, let chapterId = chapter.id,
              let analyzer, let book = appState?.currentBook,
              let settings = appState?.settings,
              settings.hasAuthentication(for: settings.llmProvider) else { return }
        guard !chapter.processed else {
            forcedAnalysisChapterIDs.remove(chapterId)
            return
        }
        let force = force || forcedAnalysisChapterIDs.contains(chapterId)
        if force {
            forcedAnalysisChapterIDs.insert(chapterId)
        } else {
            guard settings.autoAIProcessingEnabled || chapter.userOverride,
                  analyzer.shouldAutoProcess(chapter, in: chapters, book: book) else { return }
        }
        guard analysisTasks[chapterId] == nil else { return }

        let id = UUID()
        let generation = aiGeneration
        let task = Task {
            defer {
                if analysisTasks[chapterId]?.id == id {
                    analysisTasks.removeValue(forKey: chapterId)
                    if canRunAI(generation: generation) { forcedAnalysisChapterIDs.remove(chapterId) }
                }
            }
            guard canRunAI(generation: generation) else { return }
            do {
                for try await event in analyzer.analyzeChapter(chapter, book: book) {
                    guard canRunAI(generation: generation) else { break }
                    let isCurrent = currentChapter?.id == chapterId
                    switch event {
                    case .annotation(let annotation):
                        if isCurrent {
                            if !annotations.contains(where: { $0.id == annotation.id }) {
                                annotations.append(annotation)
                            }
                            refreshProgressCalculator(for: chapter)
                        } else {
                            invalidatePaginationAssets(for: chapterId)
                        }
                    case .quiz(let quiz):
                        if isCurrent && !quizzes.contains(where: { $0.id == quiz.id }) {
                            quizzes.append(quiz)
                        }
                    case .imageSuggestions(let suggestions):
                        generateImages(suggestions: suggestions, book: book, chapter: chapter)
                    case .complete(let summary):
                        forcedAnalysisChapterIDs.remove(chapterId)
                        if isCurrent {
                            currentChapter?.processed = true
                            currentChapter?.summary = summary
                        }
                        if let index = chapters.firstIndex(where: { $0.id == chapterId }) {
                            chapters[index].processed = true
                            chapters[index].summary = summary
                        }
                    case .thinking:
                        break
                    }
                }
            } catch {
                // The analyzer owns visible analysis errors.
            }
        }
        analysisTasks[chapterId] = AnalysisTask(id: id, task: task)
    }

    func cancelAnalysis() {
        if let chapterId = currentChapter?.id {
            if analysisTasks[chapterId] != nil { invalidatePaginationAssets(for: chapterId) }
            analysisTasks[chapterId]?.task.cancel()
            analysisTasks.removeValue(forKey: chapterId)
            if isAIPanelVisible { forcedAnalysisChapterIDs.remove(chapterId) }
            analyzer?.cancelInsights(for: chapterId)
        }
    }

    func handleWordClick(word: String, context: String, blockId: Int, action: BookContentView.WordAction) {
        guard !isCleaningUp, !Task.isCancelled,
              let appState, let book = appState.currentBook else { return }
        if case .explain = action {
            setAIPanelVisible(true)
            pendingChatPrompt = appState.llmService.explainWordChatPrompt(word: word, context: context)
        } else if case .generateImage = action, let chapter = currentChapter {
            setAIPanelVisible(true)
            generateImages(suggestions: [.init(excerpt: context, sourceBlockId: blockId)], book: book, chapter: chapter)
        }
    }

    private func generateImages(suggestions: [LLMService.ImageSuggestion], book: Book, chapter: Chapter) {
        guard canRunAI, let appState, appState.settings.imagesEnabled else { return }
        let saved = (try? appState.database.fetchImages(for: chapter)) ?? []
        let pending = PendingImages(suggestions: suggestions, book: book, chapter: chapter,
                                    existingImageIDs: Set(saved.compactMap(\.id)))
        let id = UUID()
        pendingImages[id] = pending
        generateImages(id: id, pending: pending)
    }

    private func generateImages(id: UUID, pending: PendingImages) {
        guard canRunAI, let appState, appState.settings.imagesEnabled,
              appState.currentBook?.id == pending.book.id, let analyzer else { return }
        let chapter = pending.chapter
        let saved = ((try? appState.database.fetchImages(for: chapter)) ?? []).filter {
            $0.id.map { !pending.existingImageIDs.contains($0) } ?? false
        }
        let suggestions = pending.suggestions.filter { suggestion in
            !saved.contains { $0.excerpt == suggestion.excerpt && $0.sourceBlockId == suggestion.sourceBlockId }
        }
        guard !suggestions.isEmpty else {
            pendingImages.removeValue(forKey: id)
            return
        }
        let generation = aiGeneration
        let task = Task {
            guard canRunAI(generation: generation) else { return }
            defer {
                if canRunAI(generation: generation) { pendingImages.removeValue(forKey: id) }
            }
            do {
                for try await image in analyzer.generateImages(suggestions: suggestions, book: pending.book, chapter: chapter) {
                    guard canRunAI(generation: generation) else { break }
                    if currentChapter?.id == chapter.id {
                        upsertImage(image)
                    } else {
                        invalidatePaginationAssets(for: chapter.id)
                    }
                    if image.status == .success { appState.readingStats.recordImage() }
                }
            } catch {
                if canRunAI(generation: generation) {
                    print("ReaderSession: Error generating images: \(error)")
                }
            }
        }
        trackAITask(task)
    }

    func retryImage(_ image: GeneratedImage) async {
        await regenerateImage(image, rewritePrompt: false)
    }

    func rewriteAndRetryImage(_ image: GeneratedImage) async {
        await regenerateImage(image, rewritePrompt: true)
    }

    private func regenerateImage(_ image: GeneratedImage, rewritePrompt: Bool) async {
        guard canRunAI, let appState, let analyzer,
              let chapter = currentChapter, let book = appState.currentBook,
              image.status != .success else { return }
        let generation = aiGeneration
        let task = Task {
            guard canRunAI(generation: generation) else { return }
            do {
                let updated = try await (rewritePrompt
                    ? analyzer.rewriteAndRetryImage(image, book: book, chapter: chapter)
                    : analyzer.retryImage(image, book: book, chapter: chapter))
                guard canRunAI(generation: generation) else { return }
                if currentChapter?.id == chapter.id {
                    upsertImage(updated)
                } else {
                    invalidatePaginationAssets(for: chapter.id)
                }
                if updated.status == .success { appState.readingStats.recordImage() }
            } catch {
                if canRunAI(generation: generation) {
                    print("ReaderSession: Image retry failed: \(error)")
                }
            }
        }
        trackAITask(task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func upsertImage(_ image: GeneratedImage) {
        if let imageId = image.id, let index = images.firstIndex(where: { $0.id == imageId }) {
            images[index] = image
            return
        }
        images.append(image)
    }

    func handleAnnotationClick(_ annotation: Annotation) {
        setAIPanelVisible(true)
        currentAnnotationId = annotation.id; externalTabSelection = .insights
    }

    func handleImageMarkerClick(_ imageId: Int64) {
        setAIPanelVisible(true)
        if images.contains(where: { $0.id == imageId }) { currentImageId = imageId; externalTabSelection = .images }
    }

    func handleImageMarkerDoubleClick(_ imageId: Int64) {
        guard let image = images.first(where: { $0.id == imageId }), image.status == .success else {
            return
        }
        setAIPanelVisible(true)
        withAnimation(.easeOut(duration: 0.2)) {
            expandedImage = image
        }
    }

    func handleFootnoteClick(_ refId: String) {
        setAIPanelVisible(true)
        if footnotes.contains(where: { $0.refId == refId }) { currentFootnoteRefId = refId; externalTabSelection = .footnotes }
    }

    func handleChapterNavigation(_ path: String, _ anchor: String?) {
        if let idx = chapters.firstIndex(where: { $0.resourcePath == path }) {
            if appState?.currentChapterIndex == idx { if let anchor = anchor { scrollToQuote = anchor } } 
            else { pendingAnchor = anchor; appState?.currentChapterIndex = idx }
        }
    }

    func generateMoreInsights() {
        guard canRunAI, let chapter = currentChapter, let analyzer else { return }
        let generation = aiGeneration
        let task = Task {
            guard canRunAI(generation: generation),
                  let new = try? await analyzer.generateMoreInsights(for: chapter),
                  canRunAI(generation: generation) else { return }
            if currentChapter?.id == chapter.id {
                annotations.append(contentsOf: new)
                refreshProgressCalculator(for: chapter)
            } else {
                invalidatePaginationAssets(for: chapter.id)
            }
        }
        trackAITask(task)
    }

    func generateMoreQuestions() {
        guard canRunAI, let chapter = currentChapter, let analyzer else { return }
        let generation = aiGeneration
        let task = Task {
            guard canRunAI(generation: generation),
                  let new = try? await analyzer.generateMoreQuestions(for: chapter),
                  canRunAI(generation: generation) else { return }
            if currentChapter?.id == chapter.id { quizzes.append(contentsOf: new) }
        }
        trackAITask(task)
    }

    func forceProcessGarbageChapter() {
        guard canRunAI, var chapter = currentChapter, let appState else { return }
        chapter.userOverride = true
        try? appState.database.saveChapter(&chapter)
        currentChapter = chapter
        if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) { chapters[idx] = chapter }
        processCurrentChapter()
    }

    func retryClassification() {
        startClassification(force: true)
    }

    private func startClassification(force: Bool = false) {
        guard canRunAI, let appState, let book = appState.currentBook,
              let analyzer, !chapters.isEmpty, classificationTask == nil,
              appState.settings.hasAuthentication(for: appState.settings.llmProvider) else { return }
        guard force || (appState.settings.autoAIProcessingEnabled && book.needsClassification) else { return }
        if force { resumeManualClassification = true }
        let generation = aiGeneration
        let id = UUID()
        let task = Task {
            defer {
                if classificationTask?.id == id { classificationTask = nil }
            }
            guard canRunAI(generation: generation) else { return }
            do {
                _ = try await analyzer.classifyChapters(chapters, for: book)
                guard canRunAI(generation: generation), appState.currentBook?.id == book.id else { return }
                resumeManualClassification = false
                if var updatedBook = appState.currentBook {
                    updatedBook.classificationStatus = .completed
                    try appState.database.saveBook(&updatedBook)
                    appState.currentBook = updatedBook
                }
                if let fresh = try? appState.database.fetchChapters(for: book) {
                    chapters = fresh
                    if let current = currentChapter, let chapter = fresh.first(where: { $0.id == current.id }) {
                        if !current.isGarbage && chapter.isGarbage,
                           let result = appState.readingSpeedTracker.endSession() {
                            appState.readingStats.addReadingTime(result.seconds)
                        }
                        currentChapter = chapter
                    }
                }
                processCurrentChapter()
            } catch {
                if canRunAI(generation: generation) { resumeManualClassification = false }
            }
        }
        classificationTask = AnalysisTask(id: id, task: task)
    }
}
