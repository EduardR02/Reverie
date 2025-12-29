import SwiftUI

struct ReaderView: View {
    @State private var book: Book

    init(book: Book) {
        self._book = State(initialValue: book)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var chapters: [Chapter] = []
    @State private var currentChapter: Chapter?
    @State private var annotations: [Annotation] = []
    @State private var quizzes: [Quiz] = []
    @State private var footnotes: [Footnote] = []
    @State private var images: [GeneratedImage] = []

    @State private var showChapterList = false
    @State private var isProcessing = false
    @State private var isGeneratingMore = false

    // Scroll sync
    @State private var currentAnnotationId: Int64?
    @State private var currentImageId: Int64?
    @State private var currentFootnoteRefId: String?
    @State private var scrollToAnnotationId: Int64?
    @State private var scrollToPercent: Double?
    @State private var scrollToOffset: Double?
    @State private var scrollToBlockId: Int?  // Block ID for scrolling
    @State private var scrollToQuote: String?
    @State private var pendingMarkerInjections: [MarkerInjection] = []
    @State private var pendingImageMarkerInjections: [ImageMarkerInjection] = []
    @State private var scrollByAmount: Double?
    @State private var lastScrollPercent: Double = 0
    @State private var lastScrollOffset: Double = 0
    @State private var pendingProgressSaveTask: Task<Void, Never>?
    @State private var didRestoreInitialPosition = false

    // Back navigation (after clicking insight)
    @State private var savedScrollOffset: Double?
    @State private var showBackButton = false

    // Auto-switch to quiz
    @State private var externalTabSelection: AIPanel.Tab?
    @State private var hasAutoSwitchedToQuiz = false
    @State private var aiPanelSelectedTab: AIPanel.Tab = .insights
    @State private var pendingChatPrompt: String?
    @State private var isChatInputFocused = false
    @State private var lastAutoSwitchAt: TimeInterval = 0
    @State private var suppressContextAutoSwitchUntil: TimeInterval = 0

    // Reading speed tracking
    @State private var chapterWPM: Double?

    // Image generation
    @State private var imageGenerating = false
    @State private var imageGenerationWord: String = ""
    @State private var expandedImage: GeneratedImage?  // Full-screen image overlay

    // Error handling
    @State private var loadError: String?
    @State private var isLoadingChapters = true

    // Chapter classification
    @State private var isClassifying = false
    @State private var classificationError: String?

    var body: some View {
        HSplitView {
            // Left: Book Content
            bookContentPanel
                .frame(minWidth: 400)

            // Right: AI Panel
            AIPanel(
                chapter: currentChapter,
                annotations: annotations,
                quizzes: quizzes,
                footnotes: footnotes,
                images: images,
                currentAnnotationId: currentAnnotationId,
                currentImageId: currentImageId,
                currentFootnoteRefId: currentFootnoteRefId,
                isProcessing: isProcessing,
                isGeneratingMore: isGeneratingMore,
                isClassifying: isClassifying,
                classificationError: classificationError,
                onScrollTo: { annotationId in
                    suppressContextAutoSwitch()
                    currentAnnotationId = annotationId
                    // Save current position for back navigation
                    savedScrollOffset = lastScrollOffset
                    showBackButton = true
                    scrollToAnnotationId = annotationId
                },
                onScrollToQuote: { quote in
                    scrollToQuote = quote
                },
                onScrollToFootnote: { refId in
                    suppressContextAutoSwitch()
                    currentFootnoteRefId = refId
                    // Scroll to footnote reference in text
                    scrollToQuote = refId  // Will be handled by JS to find the footnote link
                },
                onScrollToBlockId: { blockId, imageId in
                    suppressContextAutoSwitch()
                    if let imageId = imageId {
                        currentImageId = imageId
                    }
                    // Save current position for back navigation
                    savedScrollOffset = lastScrollOffset
                    showBackButton = true
                    scrollToBlockId = blockId
                },
                onGenerateMoreInsights: {
                    Task { await generateMoreInsights() }
                },
                onGenerateMoreQuestions: {
                    Task { await generateMoreQuestions() }
                },
                onForceProcess: {
                    forceProcessGarbageChapter()
                },
                onRetryClassification: {
                    retryClassification()
                },
                externalTabSelection: $externalTabSelection,
                selectedTab: $aiPanelSelectedTab,
                pendingChatPrompt: $pendingChatPrompt,
                isChatInputFocused: $isChatInputFocused,
                scrollPercent: lastScrollPercent,
                chapterWPM: chapterWPM,
                onApplyAdjustment: { adjustment in
                    appState.readingSpeedTracker.applyAdjustment(adjustment)
                },
                expandedImage: $expandedImage
            )
            .frame(minWidth: 280, idealWidth: 340)
        }
        .background(theme.base)
        .overlay {
            // Full-window image overlay
            if let image = expandedImage {
                fullScreenImageOverlay(image)
            }
        }
        .toolbar {
            toolbarContent
        }
        .task {
            await loadChapters()
        }
        .onChange(of: appState.currentChapterIndex) { _, newIndex in
            Task { await loadChapter(at: newIndex) }
        }
        .onDisappear {
            pendingProgressSaveTask?.cancel()
            saveReadingProgress(scrollPercent: lastScrollPercent, scrollOffset: lastScrollOffset)
            // End reading session when leaving the reader
            if appState.readingSpeedTracker.currentSession != nil {
                _ = appState.readingSpeedTracker.endSession()
            }
        }
        // Arrow key navigation
        .onKeyPress { press in
            guard !isChatInputFocused else { return .ignored }
            switch press.key {
            case .upArrow:
                scrollByAmount = -200
                return .handled
            case .downArrow:
                scrollByAmount = 200
                return .handled
            case .leftArrow:
                if press.modifiers.contains(.shift) {
                    cycleAIPanelTab(direction: -1)
                    return .handled
                }
                if appState.currentChapterIndex > 0 {
                    appState.currentChapterIndex -= 1
                }
                return .handled
            case .rightArrow:
                if press.modifiers.contains(.shift) {
                    cycleAIPanelTab(direction: 1)
                    return .handled
                }
                if appState.currentChapterIndex < chapters.count - 1 {
                    appState.currentChapterIndex += 1
                }
                return .handled
            default:
                return .ignored
            }
        }
    }

    // MARK: - Keyboard Navigation

    private func cycleAIPanelTab(direction: Int) {
        let tabs = AIPanel.Tab.allCases
        guard let currentIndex = tabs.firstIndex(of: aiPanelSelectedTab), !tabs.isEmpty else { return }
        let nextIndex = (currentIndex + direction + tabs.count) % tabs.count
        withAnimation(.easeOut(duration: 0.15)) {
            aiPanelSelectedTab = tabs[nextIndex]
        }
    }

    // MARK: - Book Content Panel

    private var bookContentPanel: some View {
        VStack(spacing: 0) {
            // Chapter header
            chapterHeader

            // Book content (WKWebView)
            if let error = loadError {
                // Error state
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(theme.love)

                    Text("Failed to load chapter")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.text)

                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(theme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        loadError = nil
                        Task { await loadChapters() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.base)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(theme.rose)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.base)
            } else if isLoadingChapters {
                // Loading state
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading chapters...")
                        .font(.system(size: 14))
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.base)
            } else if let chapter = currentChapter {
                ZStack(alignment: .bottomLeading) {
                    BookContentView(
                        chapter: chapter,
                        annotations: annotations,
                        images: images,
                        onWordClick: handleWordClick,
                        onAnnotationClick: handleAnnotationClick,
                        onImageMarkerClick: handleImageMarkerClick,
                        onFootnoteClick: handleFootnoteClick,
                        onScrollPositionChange: { annotationId, footnoteRefId, imageId, focusType, scrollPercent, scrollOffset, viewportHeight in
                            currentAnnotationId = annotationId
                            if let imageId = imageId,
                               images.contains(where: { $0.id == imageId }) {
                                currentImageId = imageId
                            } else {
                                currentImageId = nil
                            }
                            if let refId = footnoteRefId,
                               footnotes.contains(where: { $0.refId == refId }) {
                                currentFootnoteRefId = refId
                            } else {
                                currentFootnoteRefId = nil
                            }
                            lastScrollPercent = scrollPercent
                            lastScrollOffset = scrollOffset
                            scheduleProgressSave(scrollPercent: scrollPercent, scrollOffset: scrollOffset)

                            // Update reading speed session
                            appState.readingSpeedTracker.updateSession(scrollPercent: scrollPercent)

                            if showBackButton, let savedOffset = savedScrollOffset {
                                let threshold = viewportHeight > 0
                                    ? max(60, viewportHeight * 0.25)
                                    : 120
                                if abs(scrollOffset - savedOffset) <= threshold {
                                    showBackButton = false
                                    savedScrollOffset = nil
                                }
                            }

                            // Auto-switch to quiz when near bottom of chapter
                            if appState.settings.autoSwitchToQuiz &&
                               scrollPercent > 0.95 &&
                               !hasAutoSwitchedToQuiz &&
                               !quizzes.isEmpty {
                                hasAutoSwitchedToQuiz = true
                                suppressContextAutoSwitchUntil = Date().timeIntervalSinceReferenceDate + 0.75
                                // Small delay for graceful transition
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    externalTabSelection = .quiz
                                }
                            }

                            handleAutoSwitch(
                                focusType: focusType,
                                annotationId: annotationId,
                                imageId: imageId,
                                footnoteRefId: footnoteRefId
                            )
                        },
                        scrollToAnnotationId: $scrollToAnnotationId,
                        scrollToPercent: $scrollToPercent,
                        scrollToOffset: $scrollToOffset,
                        scrollToBlockId: $scrollToBlockId,
                        scrollToQuote: $scrollToQuote,
                        pendingMarkerInjections: $pendingMarkerInjections,
                        pendingImageMarkerInjections: $pendingImageMarkerInjections,
                        scrollByAmount: $scrollByAmount
                    )

                    // Back button (appears after jumping to annotation)
                    if showBackButton {
                        Button {
                            if let offset = savedScrollOffset {
                                scrollToOffset = offset
                            }
                            showBackButton = false
                            savedScrollOffset = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Back")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(theme.base)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(theme.rose)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showBackButton)
            } else {
                // No chapters found
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "book.closed")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(theme.muted)

                    Text("No chapters found")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.text)

                    Text("This book doesn't appear to have any readable content.")
                        .font(.system(size: 14))
                        .foregroundColor(theme.muted)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.base)
            }

            // Navigation footer
            navigationFooter
        }
    }

    // MARK: - Chapter Header

    private var chapterHeader: some View {
        HStack {
            // Back button with larger hit area
            Button {
                appState.closeBook()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.subtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -12)
            .padding(.vertical, -8)

            Spacer()

            // Chapter selector
            Button {
                showChapterList.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(currentChapter?.title ?? (isLoadingChapters ? "Loading..." : "No Chapter"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.text)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.muted)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showChapterList) {
                chapterListPopover
            }

            Spacer()

            // Image generating indicator (processing spinner moved to AI Panel)
            if imageGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Generating image...")
                        .font(.system(size: 12))
                        .foregroundColor(theme.rose)
                }
            }
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.headerHeight)
        .background(theme.surface)
    }

    // MARK: - Chapter List Popover

    private var chapterListPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        appState.currentChapterIndex = chapter.index
                        showChapterList = false
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.system(size: 13))
                                .foregroundColor(
                                    chapter.id == currentChapter?.id ? theme.rose : theme.text
                                )

                            Spacer()

                            if chapter.processed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.foam)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            chapter.id == currentChapter?.id ?
                            theme.overlay : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 280, height: min(CGFloat(chapters.count) * 36 + 16, 400))
        .background(theme.surface)
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        VStack(spacing: 0) {
            // Main navigation bar
            HStack {
                // Previous
                Button {
                    appState.previousChapter()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Previous")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appState.currentChapterIndex > 0 ? theme.text : theme.muted)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.currentChapterIndex <= 0)

                Spacer()

                // Progress
                Text("\(appState.currentChapterIndex + 1) / \(chapters.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.muted)

                Spacer()

                // Next
                Button {
                    appState.nextChapter()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        appState.currentChapterIndex < chapters.count - 1 ? theme.text : theme.muted
                    )
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.currentChapterIndex >= chapters.count - 1)
            }
            .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
            .frame(height: ReaderMetrics.footerHeight)
            .background(theme.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.overlay)
                    .frame(height: 1)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(book.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.text)
        }
    }

    // MARK: - Data Loading

    private func loadChapters() async {
        isLoadingChapters = true
        loadError = nil
        didRestoreInitialPosition = false

        do {
            chapters = try appState.database.fetchChapters(for: book)

            if chapters.isEmpty {
                loadError = "No chapters were found in this book. The EPUB may be corrupted or in an unsupported format."
                isLoadingChapters = false
                return
            }

            if appState.currentChapterIndex >= chapters.count {
                appState.currentChapterIndex = max(0, chapters.count - 1)
            }

            startClassificationIfNeeded()

            // Clear loading state before loading chapter content
            isLoadingChapters = false

            await loadChapter(at: appState.currentChapterIndex)
        } catch {
            loadError = "Database error: \(error.localizedDescription)"
            isLoadingChapters = false
        }
    }

    private func startClassificationIfNeeded() {
        guard book.needsClassification, !isClassifying else { return }

        isClassifying = true
        classificationError = nil
        book.classificationStatus = .inProgress
        try? appState.database.saveBook(&book)

        Task {
            await classifyBookChapters()

            if let updatedChapters = try? appState.database.fetchChapters(for: book) {
                await MainActor.run {
                    chapters = updatedChapters
                    refreshCurrentChapterFromChapters()
                }
            } else {
                await MainActor.run {
                    refreshCurrentChapterFromChapters()
                }
            }

            await MainActor.run {
                processCurrentChapterIfReady()
            }
        }
    }

    /// Classify all chapters in the book using LLM
    private func classifyBookChapters() async {
        do {
            // Prepare chapter data for classification
            let chapterData: [(index: Int, title: String, preview: String)] = chapters.map { chapter in
                // Strip HTML and get first ~200 words as preview
                let plainText = chapter.contentHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (index: chapter.index, title: chapter.title, preview: plainText)
            }

            // Call LLM to classify
            let classifications = try await appState.llmService.classifyChapters(
                chapters: chapterData,
                settings: appState.settings
            )

            // Update each chapter with classification result
            for i in 0..<chapters.count {
                var chapter = chapters[i]
                chapter.isGarbage = classifications[chapter.index] ?? false
                try appState.database.saveChapter(&chapter)
                chapters[i] = chapter
            }

            // Mark book as classified - update local state AND save to DB
            book.classificationStatus = .completed
            book.classificationError = nil
            try appState.database.saveBook(&book)

        } catch {
            // Store error for retry - update local state AND save to DB
            book.classificationStatus = .failed
            book.classificationError = error.localizedDescription
            try? appState.database.saveBook(&book)
            classificationError = error.localizedDescription
        }

        isClassifying = false
    }

    /// Retry classification after failure
    func retryClassification() {
        startClassificationIfNeeded()
    }

    private func refreshCurrentChapterFromChapters() {
        guard let current = currentChapter,
              let index = chapters.firstIndex(where: { $0.id == current.id }) else { return }
        currentChapter = chapters[index]
    }

    private func processCurrentChapterIfReady() {
        guard let chapter = currentChapter, shouldAutoProcess(chapter) else { return }
        Task { await processChapter(chapter) }
    }

    private func shouldAutoProcess(_ chapter: Chapter) -> Bool {
        hasLLMKey
            && book.classificationStatus == .completed
            && !chapter.processed
            && !chapter.shouldSkipAutoProcessing
    }

    private func loadChapter(at index: Int) async {
        guard index >= 0, index < chapters.count else { return }

        // End previous reading session
        if appState.readingSpeedTracker.currentSession != nil {
            chapterWPM = appState.readingSpeedTracker.endSession()
        }

        currentChapter = chapters[index]

        // Reset auto-switch state and switch back to insights for new chapter
        hasAutoSwitchedToQuiz = false
        externalTabSelection = .insights
        currentAnnotationId = nil
        currentImageId = nil
        currentFootnoteRefId = nil
        lastAutoSwitchAt = 0
        suppressContextAutoSwitchUntil = 0
        chapterWPM = nil

        guard let chapter = currentChapter else { return }

        // Start new reading session with estimated word count
        let wordCount = estimateWordCount(from: chapter.contentHTML)
        if wordCount > 0 {
            appState.readingSpeedTracker.startSession(chapterId: chapter.id!, wordCount: wordCount)
        }

        let shouldRestore = !didRestoreInitialPosition && index == book.currentChapter
        if shouldRestore {
            let percent = min(max(book.currentScrollPercent, 0), 1)
            if book.currentScrollOffset > 0 {
                scrollToOffset = book.currentScrollOffset
                scrollToPercent = nil
            } else {
                scrollToPercent = percent
                scrollToOffset = nil
            }
            lastScrollPercent = percent
            lastScrollOffset = book.currentScrollOffset
            didRestoreInitialPosition = true
        } else {
            scrollToPercent = 0
            scrollToOffset = nil
            lastScrollPercent = 0
            lastScrollOffset = 0
            if didRestoreInitialPosition {
                saveReadingProgress(scrollPercent: 0, scrollOffset: 0)
            } else {
                didRestoreInitialPosition = true
            }
        }

        // Load existing annotations, quizzes, footnotes
        do {
            annotations = try appState.database.fetchAnnotations(for: chapter)
            quizzes = try appState.database.fetchQuizzes(for: chapter)
            footnotes = try appState.database.fetchFootnotes(for: chapter)
            images = try appState.database.fetchImages(for: chapter)
        } catch {
            print("Failed to load chapter data: \(error)")
        }

        // Process chapter if not already processed, not garbage, and classification is complete
        if shouldAutoProcess(chapter) {
            await processChapter(chapter)
        }
    }

    /// Force process a garbage chapter (user clicked "Process Anyway")
    func forceProcessGarbageChapter() {
        guard var chapter = currentChapter else { return }

        // Set user override and save
        chapter.userOverride = true
        do {
            try appState.database.saveChapter(&chapter)
            currentChapter = chapter

            // Update in chapters array
            if let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
                chapters[index] = chapter
            }
        } catch {
            print("Failed to save user override: \(error)")
            return
        }

        // Now process the chapter
        Task {
            await processChapter(chapter)
        }
    }

    private func processChapter(_ chapter: Chapter) async {
        let chapterId = chapter.id!  // Capture ID to check after async call
        isProcessing = true
        defer { isProcessing = false }

        do {
            // Parse HTML into numbered blocks
            let blockParser = ContentBlockParser()
            let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)

            let analysis = try await appState.llmService.analyzeChapter(
                contentWithBlocks: contentWithBlocks,
                rollingSummary: chapter.rollingSummary,
                settings: appState.settings
            )

            // Check if user is still on the same chapter
            let stillOnSameChapter = currentChapter?.id == chapterId

            // Save annotations to DB (always), append to array only if still on same chapter
            var injections: [MarkerInjection] = []
            for data in analysis.annotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                // Validate block ID is in range
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count
                    ? data.sourceBlockId : 1

                var annotation = Annotation(
                    chapterId: chapterId,
                    type: type,
                    title: data.title,
                    content: data.content,
                    sourceBlockId: validBlockId
                )
                try appState.database.saveAnnotation(&annotation)
                if stillOnSameChapter {
                    annotations.append(annotation)
                    // Queue marker injection for WebView
                    if let id = annotation.id {
                        injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId))
                    }
                }
            }

            // Trigger marker injection in WebView
            if stillOnSameChapter && !injections.isEmpty {
                await MainActor.run {
                    pendingMarkerInjections = injections
                }
            }

            // Save quizzes
            for data in analysis.quizQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count
                    ? data.sourceBlockId : 1

                var quiz = Quiz(
                    chapterId: chapterId,
                    question: data.question,
                    answer: data.answer,
                    sourceBlockId: validBlockId
                )
                try appState.database.saveQuiz(&quiz)
                if stillOnSameChapter {
                    quizzes.append(quiz)
                }
            }
            if !analysis.quizQuestions.isEmpty {
                appState.readingStats.recordQuizGenerated(count: analysis.quizQuestions.count)
            }

            await generateSuggestedImages(
                analysis.imageSuggestions,
                blockCount: blocks.count,
                chapterId: chapterId,
                stillOnSameChapter: stillOnSameChapter
            )

            // Update chapter as processed with block info
            var updatedChapter = chapter
            updatedChapter.processed = true
            updatedChapter.summary = analysis.summary
            updatedChapter.contentText = contentWithBlocks
            updatedChapter.blockCount = blocks.count
            try appState.database.saveChapter(&updatedChapter)

            // Only update current view state if still on same chapter
            if stillOnSameChapter {
                currentChapter = updatedChapter
            }

            // Update in chapters array
            if let idx = chapters.firstIndex(where: { $0.id == chapterId }) {
                chapters[idx] = updatedChapter
            }

        } catch {
            print("Failed to process chapter: \(error)")
        }
    }

    private func generateSuggestedImages(
        _ suggestions: [LLMService.ImageSuggestion],
        blockCount: Int,
        chapterId: Int64,
        stillOnSameChapter: Bool
    ) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }

        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            print("Skipping image generation: missing Google API key.")
            return
        }

        imageGenerating = true
        defer { imageGenerating = false }

        let inputs = imageInputs(
            from: suggestions,
            blockCount: blockCount,
            rewrite: appState.settings.rewriteImageExcerpts
        )
        let results = await appState.imageService.generateImages(
            from: inputs,
            model: appState.settings.imageModel,
            apiKey: trimmedKey,
            maxConcurrent: 5
        )

        await storeGeneratedImages(
            results,
            chapterId: chapterId,
            stillOnSameChapter: stillOnSameChapter
        )
    }

    private func imageInputs(
        from suggestions: [LLMService.ImageSuggestion],
        blockCount: Int,
        rewrite: Bool
    ) -> [ImageService.ImageSuggestionInput] {
        suggestions.map { suggestion in
            let validBlockId = suggestion.sourceBlockId > 0 && suggestion.sourceBlockId <= blockCount
                ? suggestion.sourceBlockId : 1
            let excerpt = suggestion.excerpt
            let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: rewrite)
            return ImageService.ImageSuggestionInput(
                excerpt: excerpt,
                prompt: prompt,
                sourceBlockId: validBlockId
            )
        }
    }

    private func storeGeneratedImages(
        _ results: [ImageService.GeneratedImageResult],
        chapterId: Int64,
        stillOnSameChapter: Bool
    ) async {
        for result in results {
            do {
                let imagePath = try appState.imageService.saveImage(
                    result.imageData,
                    for: book.id!,
                    chapterId: chapterId
                )
                var image = GeneratedImage(
                    chapterId: chapterId,
                    prompt: result.excerpt,
                    imagePath: imagePath,
                    sourceBlockId: result.sourceBlockId
                )
                try appState.database.saveImage(&image)
                appState.readingStats.recordImage()

                if stillOnSameChapter {
                    images.append(image)
                    if let id = image.id {
                        pendingImageMarkerInjections.append(
                            ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId)
                        )
                    }
                }
            } catch {
                print("Failed to save image: \(error)")
            }
        }
    }

    private func generateMoreInsights() async {
        guard let chapter = currentChapter, hasLLMKey else { return }
        let chapterId = chapter.id!

        isGeneratingMore = true
        defer { isGeneratingMore = false }

        do {
            // Get or generate block content
            let blockParser = ContentBlockParser()
            let contentWithBlocks: String
            let blockCount: Int

            if let cached = chapter.contentText {
                contentWithBlocks = cached
                blockCount = chapter.blockCount
            } else {
                let (blocks, text) = blockParser.parse(html: chapter.contentHTML)
                contentWithBlocks = text
                blockCount = blocks.count
            }

            let existingTitles = annotations.map { $0.title }
            let newAnnotations = try await appState.llmService.generateMoreInsights(
                contentWithBlocks: contentWithBlocks,
                rollingSummary: chapter.rollingSummary,
                existingTitles: existingTitles,
                settings: appState.settings
            )

            // Check if still on same chapter
            let stillOnSameChapter = currentChapter?.id == chapterId

            var injections: [MarkerInjection] = []
            for data in newAnnotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount
                    ? data.sourceBlockId : 1

                var annotation = Annotation(
                    chapterId: chapterId,
                    type: type,
                    title: data.title,
                    content: data.content,
                    sourceBlockId: validBlockId
                )
                try appState.database.saveAnnotation(&annotation)

                if stillOnSameChapter {
                    annotations.append(annotation)
                    // Queue marker injection for WebView
                    if let id = annotation.id {
                        injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId))
                    }
                }
            }

            // Trigger marker injection in WebView only if on same chapter
            if stillOnSameChapter {
                await MainActor.run {
                    pendingMarkerInjections = injections
                }
            }
        } catch {
            print("Failed to generate more insights: \(error)")
        }
    }

    private func generateMoreQuestions() async {
        guard let chapter = currentChapter, hasLLMKey else { return }
        let chapterId = chapter.id!

        isGeneratingMore = true
        defer { isGeneratingMore = false }

        do {
            // Get or generate block content
            let blockParser = ContentBlockParser()
            let contentWithBlocks: String
            let blockCount: Int

            if let cached = chapter.contentText {
                contentWithBlocks = cached
                blockCount = chapter.blockCount
            } else {
                let (blocks, text) = blockParser.parse(html: chapter.contentHTML)
                contentWithBlocks = text
                blockCount = blocks.count
            }

            let existingQuestions = quizzes.map { $0.question }
            let newQuestions = try await appState.llmService.generateMoreQuestions(
                contentWithBlocks: contentWithBlocks,
                rollingSummary: chapter.rollingSummary,
                existingQuestions: existingQuestions,
                settings: appState.settings
            )

            // Check if still on same chapter
            let stillOnSameChapter = currentChapter?.id == chapterId

            for data in newQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount
                    ? data.sourceBlockId : 1

                var quiz = Quiz(
                    chapterId: chapterId,
                    question: data.question,
                    answer: data.answer,
                    sourceBlockId: validBlockId
                )
                try appState.database.saveQuiz(&quiz)
                if stillOnSameChapter {
                    quizzes.append(quiz)
                }
            }
            if !newQuestions.isEmpty {
                appState.readingStats.recordQuizGenerated(count: newQuestions.count)
            }
        } catch {
            print("Failed to generate more questions: \(error)")
        }
    }

    // MARK: - Image Overlay

    @ViewBuilder
    private func fullScreenImageOverlay(_ image: GeneratedImage) -> some View {
        ZStack {
            // Background dim
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        expandedImage = nil
                    }
                }

            VStack(spacing: 20) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            expandedImage = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 30)
                .padding(.top, 20)

                // Image - takes most of the space
                AsyncImage(url: image.imageURL) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 20)
                    case .failure:
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                            Text("Failed to load image")
                                .font(.system(size: 16))
                        }
                        .foregroundColor(.white.opacity(0.6))
                    case .empty:
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.5)
                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 60)

                // Prompt/caption
                Text(image.prompt)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 30)
            }
        }
    }

    // MARK: - Word Actions

    private func handleWordClick(word: String, context: String, blockId: Int, action: BookContentView.WordAction) {
        switch action {
        case .explain:
            pendingChatPrompt = appState.llmService.explainWordChatPrompt(
                word: word,
                context: context
            )

        case .generateImage:
            guard let chapter = currentChapter, appState.settings.imagesEnabled else { return }

            imageGenerating = true
            imageGenerationWord = word

            Task {
                do {
                    let excerpt = word
                    let prompt = appState.llmService.imagePromptFromExcerpt(
                        excerpt,
                        rewrite: appState.settings.rewriteImageExcerpts
                    )

                    // Then generate the image
                    let imageData = try await appState.imageService.generateImage(
                        prompt: prompt,
                        model: appState.settings.imageModel,
                        apiKey: appState.settings.googleAPIKey
                    )

                    // Save image
                    let imagePath = try appState.imageService.saveImage(
                        imageData,
                        for: book.id!,
                        chapterId: chapter.id!
                    )

                    // Create database record
                    var image = GeneratedImage(
                        chapterId: chapter.id!,
                        prompt: excerpt,
                        imagePath: imagePath,
                        sourceBlockId: blockId > 0 ? blockId : 1
                    )
                    try appState.database.saveImage(&image)
                    images.append(image)
                    if let id = image.id {
                        pendingImageMarkerInjections.append(
                            ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId)
                        )
                    }

                } catch {
                    print("Failed to generate image: \(error)")
                }

                imageGenerating = false
            }
        }
    }

    private func handleAnnotationClick(_ annotation: Annotation) {
        // Expand the annotation in the AI panel
        currentAnnotationId = annotation.id
    }

    private func handleImageMarkerClick(_ imageId: Int64) {
        guard images.contains(where: { $0.id == imageId }) else { return }
        currentImageId = imageId
        externalTabSelection = .images
    }

    private func handleFootnoteClick(_ refId: String) {
        guard footnotes.contains(where: { $0.refId == refId }) else { return }
        currentFootnoteRefId = refId
        externalTabSelection = .footnotes
    }

    private func handleAutoSwitch(
        focusType: String?,
        annotationId: Int64?,
        imageId: Int64?,
        footnoteRefId: String?
    ) {
        guard appState.settings.autoSwitchContextTabs,
              let focusType = focusType else {
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        if now < suppressContextAutoSwitchUntil { return }

        let targetTab: AIPanel.Tab?
        switch focusType {
        case "annotation":
            targetTab = annotationId != nil ? .insights : nil
        case "image":
            targetTab = (imageId != nil && currentImageId != nil) ? .images : nil
        case "footnote":
            targetTab = (footnoteRefId != nil && currentFootnoteRefId != nil) ? .footnotes : nil
        default:
            targetTab = nil
        }

        guard let tab = targetTab else { return }

        if aiPanelSelectedTab == tab { return }
        if aiPanelSelectedTab == .quiz { return }
        if aiPanelSelectedTab == .chat && !appState.settings.autoSwitchFromChatOnScroll { return }

        if now - lastAutoSwitchAt < 0.35 { return }

        lastAutoSwitchAt = now
        externalTabSelection = tab
    }

    private func suppressContextAutoSwitch(for duration: TimeInterval = 2.0) {
        let now = Date().timeIntervalSinceReferenceDate
        suppressContextAutoSwitchUntil = max(suppressContextAutoSwitchUntil, now + duration)
    }

    // MARK: - Helpers

    private func scheduleProgressSave(scrollPercent: Double, scrollOffset: Double) {
        pendingProgressSaveTask?.cancel()
        pendingProgressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            saveReadingProgress(scrollPercent: scrollPercent, scrollOffset: scrollOffset)
        }
    }

    private func saveReadingProgress(scrollPercent: Double, scrollOffset: Double) {
        guard book.id != nil else { return }

        let clampedPercent = max(0, min(scrollPercent, 1))
        let chapterCount = max(1, max(chapters.count, book.chapterCount))
        let chapterProgress = Double(appState.currentChapterIndex) + clampedPercent
        let overallProgress = min(max(chapterProgress / Double(chapterCount), 0), 1)

        var updatedBook = book
        updatedBook.currentChapter = appState.currentChapterIndex
        updatedBook.currentScrollPercent = clampedPercent
        updatedBook.currentScrollOffset = scrollOffset
        updatedBook.progressPercent = overallProgress
        updatedBook.lastReadAt = Date()

        do {
            try appState.database.saveBook(&updatedBook)
        } catch {
            print("Failed to save reading progress: \(error)")
        }
    }

    private var hasLLMKey: Bool {
        switch appState.settings.llmProvider {
        case .google:
            return !appState.settings.googleAPIKey.isEmpty
        case .openai:
            return !appState.settings.openAIAPIKey.isEmpty
        case .anthropic:
            return !appState.settings.anthropicAPIKey.isEmpty
        }
    }

    private func estimateWordCount(from html: String) -> Int {
        // Strip HTML tags and count words
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let words = stripped.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.count
    }
}
