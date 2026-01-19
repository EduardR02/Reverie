import Foundation
import SwiftUI
import AppKit

@Observable @MainActor
final class ReaderSession {
    private(set) var autoScroll = AutoScrollEngine()
    private(set) var rsvpEngine = RSVPEngine()
    private(set) var analyzer: ChapterAnalyzer?
    private weak var appState: AppState?
    
    var chapters: [Chapter] = []
    var currentChapter: Chapter?
    var annotations: [Annotation] = []
    var quizzes: [Quiz] = []
    var footnotes: [Footnote] = []
    var images: [GeneratedImage] = []
    
    var currentAnnotationId: Int64?
    var currentImageId: Int64?
    var currentFootnoteRefId: String?
    var scrollToAnnotationId: Int64?
    var scrollToPercent: Double?
    var scrollToOffset: Double?
    var scrollToBlockId: (Int, Int64?, String?)?
    var scrollToQuote: String?
    var scrollByAmount: Double?
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
    var showBackButton = false
    var backAnchorState: BackAnchorState = .inactive
    enum BackAnchorState { case inactive, pending, away }
    
    var externalTabSelection: AIPanel.Tab?
    var hasAutoSwitchedToQuiz = false
    var aiPanelSelectedTab: AIPanel.Tab = .insights
    var pendingChatPrompt: String?
    var isChatInputFocused = false
    var lastAutoSwitchAt: TimeInterval = 0
    var suppressContextAutoSwitchUntil: TimeInterval = 0
    
    var calculatorCache = ProgressCalculatorCache()
    private var baseWordCountsByChapter: [Int64: [Int]] = [:]
    private var baseBlockTextsByChapter: [Int64: [String]] = [:]
    private var didLoadChapterAssets = false
    var currentLocation: BlockLocation?
    var furthestLocation: BlockLocation?
    var currentProgressPercent: Double = 0
    var furthestProgressPercent: Double = 0
    
    private var readingTickTask: Task<Void, Never>?
    private var autoScrollTickTask: Task<Void, Never>?
    private var chapterLoadTask: Task<Void, Never>?
    private var analysisTasks: [Int64: Task<Void, Never>] = [:]
    private var backgroundTasks: [Task<Void, Never>] = []
    private var isCleaningUp = false
    var showChapterList = false
    var expandedImage: GeneratedImage?
    var loadError: String?
    var isLoadingChapters = true

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
        autoScrollTickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !isCleaningUp else { break }
                guard autoScroll.isActive else { continue }
                guard let chapterId = currentChapter?.id, let calculator = calculatorCache.get(for: chapterId) else { continue }
                if let amount = autoScroll.calculateScrollAmount(currentOffset: lastScrollOffset, currentLocation: currentLocation, calculator: calculator) {
                    self.scrollByAmount = amount
                }
            }
        }
    }
    
    func cleanup() {
        isCleaningUp = true
        scrollByAmount = nil
        readingTickTask?.cancel()
        autoScrollTickTask?.cancel()
        for task in analysisTasks.values { task.cancel() }
        analysisTasks.removeAll()
        for task in backgroundTasks { task.cancel() }
        backgroundTasks.removeAll()
        autoScroll.stop()
        persistCurrentProgress()
        if let result = appState?.readingSpeedTracker.endSession() {
            appState?.readingStats.addReadingTime(result.seconds)
        }
        analyzer?.cancelAll()
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
            
            let classificationTask = Task {
                guard appState.settings.autoAIProcessingEnabled else { return }
                guard book.needsClassification else { return }
                let bookId = book.id
                do {
                    _ = try await analyzer?.classifyChapters(chapters, for: book)
                    guard appState.currentBook?.id == bookId else { return }
                    
                    // Update status FIRST so processCurrentChapter sees isClassified = true
                    if var updatedBook = appState.currentBook {
                        updatedBook.classificationStatus = .completed
                        try? appState.database.saveBook(&updatedBook)
                        appState.currentBook = updatedBook
                    }
                    
                    if let fresh = try? appState.database.fetchChapters(for: book) {
                        self.chapters = fresh
                        if let current = self.currentChapter, let idx = fresh.firstIndex(where: { $0.id == current.id }) {
                            let newlyGarbage = !current.isGarbage && fresh[idx].isGarbage
                            if newlyGarbage {
                                if let result = appState.readingSpeedTracker.endSession() {
                                    appState.readingStats.addReadingTime(result.seconds)
                                }
                            }
                        self.currentChapter = fresh[idx]
                        // Now loadChapter will trigger processCurrentChapter with classification complete
                        await self.loadChapter(at: appState.currentChapterIndex, force: true)
                    }
                }
            } catch {
                // Classification failed - don't update status, leave as pending/failed
            }
        }
        backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
        backgroundTasks.append(classificationTask)
    } catch {
        loadError = error.localizedDescription
        isLoadingChapters = false
    }
}

    func loadChapter(at index: Int, force: Bool = false) async {
        chapterLoadTask?.cancel()
        chapterLoadTask = Task { @MainActor in
            guard let appState = appState, let book = appState.currentBook, index >= 0, index < chapters.count else { return }
            guard !Task.isCancelled else { return }
            if let result = appState.readingSpeedTracker.endSession() {
                appState.readingStats.addReadingTime(result.seconds)
            }
            
            let chapter = chapters[index]
            guard !Task.isCancelled else { return }
            let sameChapter = currentChapter?.id == chapter.id
            
            if sameChapter && pendingAnchor == nil && !force {
                return
            }

            if !sameChapter {
                cancelAnalysis()
                pendingMarkerInjections.removeAll()
                pendingImageMarkerInjections.removeAll()
            }
            currentChapter = chapter
            autoScroll.updateMarkers([])
            hasAutoSwitchedToQuiz = false
            externalTabSelection = .insights
            currentAnnotationId = nil
            currentImageId = nil
            currentFootnoteRefId = nil
            showBackButton = false
            savedScrollOffset = nil
            backAnchorState = .inactive
            lastAutoSwitchAt = 0
            suppressContextAutoSwitchUntil = 0
            didLoadChapterAssets = false
            
            if let anchor = pendingAnchor {
                scrollToQuote = anchor
                pendingAnchor = nil
                lastScrollPercent = 0; lastScrollOffset = 0
                didRestoreInitialPosition = true
            } else if sameChapter {
                if force {
                    if lastScrollOffset > 0 { scrollToOffset = lastScrollOffset }
                    else { scrollToPercent = lastScrollPercent }
                    didRestoreInitialPosition = true
                }
            } else {
                let restoring = !didRestoreInitialPosition && index == book.currentChapter
                if restoring {
                    if book.currentScrollOffset > 0 { scrollToOffset = book.currentScrollOffset }
                    else { scrollToPercent = book.currentScrollPercent }
                    lastScrollPercent = book.currentScrollPercent
                    lastScrollOffset = book.currentScrollOffset
                    didRestoreInitialPosition = true
                } else {
                    scrollToPercent = 0; scrollToOffset = nil; lastScrollPercent = 0; lastScrollOffset = 0
                    if didRestoreInitialPosition {
                        appState.recordReadingProgress(chapter: chapter, currentPercent: 0, furthestPercent: chapter.maxScrollReached, scrollOffset: 0)
                    } else { didRestoreInitialPosition = true }
                }
            }
            currentProgressPercent = lastScrollPercent
            furthestProgressPercent = max(chapter.maxScrollReached, currentProgressPercent)
            
            currentLocation = nil; furthestLocation = nil
            ensureProgressCalculator(for: chapter)
            
            do {
                annotations = try appState.database.fetchAnnotations(for: chapter)
                quizzes = try appState.database.fetchQuizzes(for: chapter)
                footnotes = try appState.database.fetchFootnotes(for: chapter)
                images = try appState.database.fetchImages(for: chapter)
                
                // Load content into RSVP engine
                let parser = ContentBlockParser()
                let (blocks, _) = parser.parse(html: chapter.contentHTML)
                rsvpEngine.loadChapter(
                    blocks: blocks,
                    annotations: annotations,
                    images: images,
                    footnotes: footnotes
                )
                
                didLoadChapterAssets = true
            } catch {
                print("ReaderSession: Failed to load chapter assets: \(error)")
                didLoadChapterAssets = true
            }
            
            refreshProgressCalculator(for: chapter)
            autoScroll.stop()
            processCurrentChapter()
        }
        await chapterLoadTask?.value
    }

    func persistCurrentProgress() {
        guard let appState = appState, let chapter = currentChapter else { return }
        appState.recordReadingProgress(chapter: chapter, currentPercent: currentProgressPercent, furthestPercent: furthestProgressPercent, scrollOffset: lastScrollOffset)
    }

    func ensureProgressCalculator(for chapter: Chapter) {
        guard let id = chapter.id else { return }
        if baseWordCountsByChapter[id] != nil {
            refreshProgressCalculator(for: chapter)
            return
        }
        let html = chapter.contentHTML
        let task = Task.detached(priority: .utility) {
            let parser = ContentBlockParser()
            let (blocks, _) = parser.parse(html: html)
            let wordCounts = blocks.map { ReaderSession.wordCount(in: $0.text) }
            let blockTexts = blocks.map { $0.text }
            await MainActor.run {
                self.baseWordCountsByChapter[id] = wordCounts
                self.baseBlockTextsByChapter[id] = blockTexts
                self.refreshProgressCalculator(for: chapter)
            }
        }
        backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
        backgroundTasks.append(task)
    }

    private func refreshProgressCalculator(for chapter: Chapter) {
        guard let id = chapter.id,
              let baseCounts = baseWordCountsByChapter[id],
              let baseTexts = baseBlockTextsByChapter[id],
              !baseCounts.isEmpty else { return }

        let combinedCounts = Self.combinedWordCounts(
            baseCounts: baseCounts,
            baseTexts: baseTexts,
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

    nonisolated static func combinedWordCounts(
        baseCounts: [Int],
        baseTexts: [String],
        annotations: [Annotation],
        footnotes: [Footnote],
        chapterWordCount: Int
    ) -> [Int] {
        guard !baseCounts.isEmpty else { return baseCounts }

        var counts = baseCounts
        let normalizedBlocks = baseTexts.map { normalizedText($0) }
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
            let isEmbedded = normalizedBlocks.contains { $0.contains(normalizedFootnote) }
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

    func startReadingTicker() {
        readingTickTask?.cancel()
        readingTickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                appState?.readingSpeedTracker.tick()
            }
        }
    }

    func setBackAnchor() {
        if savedScrollOffset == nil {
            savedScrollOffset = lastScrollOffset
            showBackButton = true
            backAnchorState = .pending
        }
    }

    func dismissBackAnchor() {
        showBackButton = false; savedScrollOffset = nil; backAnchorState = .inactive
    }

    func returnToBackAnchor() {
        if let offset = savedScrollOffset { scrollToOffset = offset }
        dismissBackAnchor()
    }

    func handleScrollUpdate(context: ScrollContext, chapter: Chapter) {
        isProgrammaticScroll = context.isProgrammatic
        autoScroll.updateScrollPosition(offset: context.scrollOffset, viewportHeight: context.viewportHeight, scrollHeight: context.scrollHeight, isProgrammatic: context.isProgrammatic)
        
        if context.isProgrammatic {
            if let aid = context.annotationId { currentAnnotationId = aid }
            if let iid = context.imageId { currentImageId = iid }
            if let fid = context.footnoteRefId { currentFootnoteRefId = fid }
        } else {
            currentAnnotationId = context.annotationId; currentImageId = context.imageId; currentFootnoteRefId = context.footnoteRefId
        }

        var current = context.scrollPercent
        let atBottom = context.scrollPercent >= 1.0
        if isAtChapterBottom != atBottom { isAtChapterBottom = atBottom }
        
        var furthest = max(furthestProgressPercent, current)
        if let blockId = context.blockId {
            let location = BlockLocation(blockId: blockId, offset: context.blockOffset ?? 0)
            currentLocation = location
            if let floc = furthestLocation { if floc < location { furthestLocation = location } } else { furthestLocation = location }
            if let id = chapter.id, let calculator = calculatorCache.get(for: id) {
                current = calculator.percent(for: location)
                if let floc = furthestLocation { furthest = calculator.percent(for: floc) }
            }
        }
        currentProgressPercent = min(max(current, 0), 1)
        furthestProgressPercent = min(max(max(furthest, current), 0), 1)
        lastScrollPercent = currentProgressPercent; lastScrollOffset = context.scrollOffset
        
        appState?.recordReadingProgress(chapter: chapter, currentPercent: currentProgressPercent, furthestPercent: furthestProgressPercent, scrollOffset: context.scrollOffset)
        appState?.readingSpeedTracker.updateSession(scrollPercent: currentProgressPercent)
        if !context.isProgrammatic { appState?.readingSpeedTracker.endAllPauses() }
        
        if showBackButton, let saved = savedScrollOffset {
            let dist = abs(context.scrollOffset - saved)
            let leave = context.viewportHeight > 0 ? max(80, context.viewportHeight * 0.12) : 120
            let ret = context.viewportHeight > 0 ? max(48, context.viewportHeight * 0.06) : 72
            if backAnchorState == .pending && dist > leave { backAnchorState = .away }
            else if backAnchorState == .away && dist <= ret { dismissBackAnchor() }
        }

        if context.scrollPercent < 0.85 { hasAutoSwitchedToQuiz = false }
        handleAutoSwitch(context: context)
    }

    func handleAutoSwitch(context: ScrollContext) {
        guard let appState = appState else { return }
        if appState.settings.autoSwitchFromChatOnScroll && aiPanelSelectedTab == .chat && !context.isProgrammatic {
            aiPanelSelectedTab = .insights
            return
        }
        guard appState.settings.autoSwitchContextTabs, Date().timeIntervalSinceReferenceDate >= suppressContextAutoSwitchUntil, aiPanelSelectedTab != .quiz, aiPanelSelectedTab != .chat, let primary = context.primaryType else { return }

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
        guard let appState = appState, appState.settings.autoSwitchToQuiz, !quizzes.isEmpty, !hasAutoSwitchedToQuiz, aiPanelSelectedTab != .quiz else { return }
        hasAutoSwitchedToQuiz = true
        suppressContextAutoSwitchUntil = Date().timeIntervalSinceReferenceDate + 1.0
        withAnimation(.easeOut(duration: 0.3)) { self.aiPanelSelectedTab = .quiz }
    }

    func cycleAIPanelTab(direction: Int) {
        let tabs = AIPanel.Tab.allCases
        guard let idx = tabs.firstIndex(of: aiPanelSelectedTab) else { return }
        aiPanelSelectedTab = tabs[(idx + direction + tabs.count) % tabs.count]
    }

    func suppressContextAutoSwitch(for duration: TimeInterval = 2.0) {
        suppressContextAutoSwitchUntil = max(suppressContextAutoSwitchUntil, Date().timeIntervalSinceReferenceDate + duration)
    }
    
    func setRSVPMode(_ enabled: Bool) {
        isRSVPMode = enabled
        if enabled {
            // Disable auto-scroll when entering RSVP
            appState?.settings.smartAutoScrollEnabled = false
            appState?.settings.save()
            autoScroll.stop()
            
            // Sync RSVP to current reading position
            syncRSVPToCurrentPosition()
        } else {
            // Pause RSVP when exiting
            rsvpEngine.pause()
        }
    }
    
    /// Synchronizes the RSVP engine's current word index to the user's current scroll position.
    func syncRSVPToCurrentPosition() {
        guard let location = currentLocation, !rsvpEngine.words.isEmpty else { return }
        
        // Find the first word that belongs to the current block
        if let index = rsvpEngine.words.firstIndex(where: { $0.sourceBlockId == location.blockId }) {
            rsvpEngine.currentWordIndex = index
            rsvpEngine.pendingPauseContent = nil
        }
    }
    
    func handleRSVPPauseContentChange(_ content: PauseContent?) {
        guard let content = content else { return }
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
        
        // Otherwise toggle auto-scroll (existing behavior)
        appState?.settings.smartAutoScrollEnabled.toggle()
        if let enabled = appState?.settings.smartAutoScrollEnabled, !enabled {
            autoScroll.cancelCountdown()
        }
        return .handled
    }

    func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) {
            if press.key == .leftArrow {
                cycleAIPanelTab(direction: -1)
                return .handled
            }
            if press.key == .rightArrow {
                cycleAIPanelTab(direction: 1)
                return .handled
            }
        }

        guard !isChatInputFocused else { return .ignored }

        // RSVP mode: arrows skip words (override chapter navigation)
        if isRSVPMode {
            switch press.key {
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

        switch press.key {
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
        if newTab == .chat {
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
        guard let chapter = currentChapter, let chapterId = chapter.id, let analyzer = analyzer, let book = appState?.currentBook else { return }
        
        if !force {
            guard analyzer.shouldAutoProcess(chapter, in: chapters, book: book) else { return }
        } else {
            // Manual trigger: only require LLM key and not already processed
            let hasLLMKey = !(appState?.settings.googleAPIKey.isEmpty ?? true) || !(appState?.settings.openAIAPIKey.isEmpty ?? true) || !(appState?.settings.anthropicAPIKey.isEmpty ?? true)
            guard hasLLMKey, !chapter.processed else { return }
        }
        
        if analysisTasks[chapterId] != nil { return }
        
        let task = Task {
            defer { analysisTasks.removeValue(forKey: chapterId) }
            do {
                for try await event in analyzer.analyzeChapter(chapter, book: book) {
                    if Task.isCancelled { break }
                    let isCurrent = self.currentChapter?.id == chapterId
                    
                    switch event {
                    case .annotation(let ann):
                        if isCurrent {
                            annotations.append(ann)
                            pendingMarkerInjections.append(MarkerInjection(annotationId: ann.id!, sourceBlockId: ann.sourceBlockId))
                            refreshProgressCalculator(for: chapter)
                        }
                    case .quiz(let q):
                        if isCurrent { quizzes.append(q) }
                    case .imageSuggestions(let suggestions):
                        guard let appState = self.appState, appState.settings.imagesEnabled else { continue }
                        let imgTask = Task {
                            guard let analyzer = self.analyzer else { return }
                            do {
                                for try await img in analyzer.generateImages(suggestions: suggestions, book: book, chapter: chapter) {
                                    if Task.isCancelled { break }
                                    if self.currentChapter?.id == chapterId {
                                        images.append(img)
                                        pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: img.id!, sourceBlockId: img.sourceBlockId))
                                        appState.readingStats.recordImage()
                                    }
                                }
                            } catch {
                                print("ReaderSession: Error generating images: \(error)")
                            }
                        }
                        self.backgroundTasks = self.backgroundTasks.filter { !$0.isCancelled }
                        self.backgroundTasks.append(imgTask)
                    case .complete(let summary):
                        if isCurrent { self.currentChapter?.processed = true }
                        if let idx = self.chapters.firstIndex(where: { $0.id == chapterId }) { self.chapters[idx].processed = true }
                        if let summary = summary {
                            if isCurrent { self.currentChapter?.summary = summary }
                            if let idx = self.chapters.firstIndex(where: { $0.id == chapterId }) { self.chapters[idx].summary = summary }
                        }
                    case .thinking: break
                    }
                }
            } catch {
                // UI uses analyzer.processingStates[id]?.error instead of a local property
            }
        }
        analysisTasks[chapterId] = task
    }

    // Image generation uses non-streamed requests that can't actually be cancelled
    // (the API call still completes and bills, we just ignore the result).
    func cancelAnalysis() {
        if let chapterId = currentChapter?.id {
            analysisTasks[chapterId]?.cancel()
            analysisTasks.removeValue(forKey: chapterId)
            analyzer?.cancel(for: chapterId)
        }
    }

    func handleWordClick(word: String, context: String, blockId: Int, action: BookContentView.WordAction) {
        guard let appState = appState, let book = appState.currentBook else { return }
        if case .explain = action { pendingChatPrompt = appState.llmService.explainWordChatPrompt(word: word, context: context) } 
        else if case .generateImage = action, let chapter = currentChapter, appState.settings.imagesEnabled {
            let task = Task {
                guard let analyzer = self.analyzer else { return }
                do {
                    for try await img in analyzer.generateImages(suggestions: [.init(excerpt: context, sourceBlockId: blockId)], book: book, chapter: chapter) {
                        if currentChapter?.id == chapter.id {
                            images.append(img)
                            pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: img.id!, sourceBlockId: img.sourceBlockId))
                            appState.readingStats.recordImage()
                        }
                    }
                } catch {
                    print("ReaderSession: Error generating single image: \(error)")
                }
            }
            backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
            backgroundTasks.append(task)
        }
    }

    func handleAnnotationClick(_ annotation: Annotation) {
        currentAnnotationId = annotation.id; externalTabSelection = .insights
    }

    func handleImageMarkerClick(_ imageId: Int64) {
        if images.contains(where: { $0.id == imageId }) { currentImageId = imageId; externalTabSelection = .images }
    }

    func handleFootnoteClick(_ refId: String) {
        if footnotes.contains(where: { $0.refId == refId }) { currentFootnoteRefId = refId; externalTabSelection = .footnotes }
    }

    func handleChapterNavigation(_ path: String, _ anchor: String?) {
        if let idx = chapters.firstIndex(where: { $0.resourcePath == path }) {
            if appState?.currentChapterIndex == idx { if let anchor = anchor { scrollToQuote = anchor } } 
            else { pendingAnchor = anchor; appState?.currentChapterIndex = idx }
        }
    }

    func generateMoreInsights() {
        guard let chapter = currentChapter else { return }
        let task = Task {
            guard let analyzer = self.analyzer, let new = try? await analyzer.generateMoreInsights(for: chapter) else { return }
            annotations.append(contentsOf: new)
            pendingMarkerInjections.append(contentsOf: new.compactMap { ann in ann.id.map { MarkerInjection(annotationId: $0, sourceBlockId: ann.sourceBlockId) } })
        }
        backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
        backgroundTasks.append(task)
    }

    func generateMoreQuestions() {
        guard let chapter = currentChapter else { return }
        let task = Task {
            guard let analyzer = self.analyzer, let new = try? await analyzer.generateMoreQuestions(for: chapter) else { return }
            quizzes.append(contentsOf: new)
        }
        backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
        backgroundTasks.append(task)
    }

    func forceProcessGarbageChapter() {
        guard var chapter = currentChapter, let appState = appState else { return }
        chapter.userOverride = true
        try? appState.database.saveChapter(&chapter)
        currentChapter = chapter
        if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) { chapters[idx] = chapter }
        processCurrentChapter()
    }

    func retryClassification() {
        guard let appState = appState, let book = appState.currentBook else { return }
        let bookId = book.id
        let task = Task {
            do {
                _ = try await analyzer?.classifyChapters(chapters, for: book)
                guard appState.currentBook?.id == bookId else { return }
                
                // Update status FIRST so processCurrentChapter sees isClassified = true
                if var updatedBook = appState.currentBook {
                    updatedBook.classificationStatus = .completed
                    try? appState.database.saveBook(&updatedBook)
                    appState.currentBook = updatedBook
                }
                
                if let fresh = try? appState.database.fetchChapters(for: book) {
                    self.chapters = fresh
                    if let current = self.currentChapter, let idx = fresh.firstIndex(where: { $0.id == current.id }) {
                        let newlyGarbage = !current.isGarbage && fresh[idx].isGarbage
                        if newlyGarbage {
                            if let result = appState.readingSpeedTracker.endSession() {
                                appState.readingStats.addReadingTime(result.seconds)
                            }
                        }
                        self.currentChapter = fresh[idx]
                        await self.loadChapter(at: appState.currentChapterIndex, force: true)
                    }
                }
            } catch {
                print("ReaderSession: Classification retry failed: \(error)")
            }
        }
        backgroundTasks = backgroundTasks.filter { !$0.isCancelled }
        backgroundTasks.append(task)
    }
}
