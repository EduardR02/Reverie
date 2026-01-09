import AppKit
import SwiftUI

struct ReaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var chapters: [Chapter] = []
    @State private var currentChapter: Chapter?
    @State private var annotations: [Annotation] = []
    @State private var quizzes: [Quiz] = []
    @State private var footnotes: [Footnote] = []
    @State private var images: [GeneratedImage] = []

    @State private var showChapterList = false
    
    struct ChapterProcessingState {
        var isProcessingInsights = false
        var isProcessingImages = false
        var liveInsightCount = 0
        var liveQuizCount = 0
        var liveThinking = ""
        var analysisError: String?
    }
    @State private var processingStates: [Int64: ChapterProcessingState] = [:]
    @State private var currentAnalysisTask: Task<Void, Never>?
    @State private var currentImageTask: Task<Void, Never>?
    
    // Scroll sync
    @State private var currentAnnotationId: Int64?
    @State private var currentImageId: Int64?
    @State private var currentFootnoteRefId: String?
    @State private var scrollToAnnotationId: Int64?
    @State private var scrollToPercent: Double?
    @State private var scrollToOffset: Double?
    @State private var scrollToBlockId: (Int, Int64?, String?)?
    @State private var scrollToQuote: String?
    @State private var pendingMarkerInjections: [MarkerInjection] = []
    @State private var pendingImageMarkerInjections: [ImageMarkerInjection] = []
    @State private var scrollByAmount: Double?
    @State private var pendingAnchor: String?
    @State private var lastScrollPercent: Double = 0
    @State private var lastScrollOffset: Double = 0
    @State private var didRestoreInitialPosition = false

    // Back navigation (after clicking insight)
    @State private var savedScrollOffset: Double?
    @State private var showBackButton = false
    @State private var backAnchorState: BackAnchorState = .inactive

    // Auto-switch logic
    @State private var externalTabSelection: AIPanel.Tab?
    @State private var hasAutoSwitchedToQuiz = false
    @State private var aiPanelSelectedTab: AIPanel.Tab = .insights
    @State private var pendingChatPrompt: String?
    @State private var isChatInputFocused = false
    @State private var lastAutoSwitchAt: TimeInterval = 0
    @State private var suppressContextAutoSwitchUntil: TimeInterval = 0

    // Reading speed tracking
    @State private var chapterWPM: Double?
    @State private var readingTickTask: Task<Void, Never>?

    // Image generation
    @State private var expandedImage: GeneratedImage?  // Full-screen image overlay

    // Progress tracking
    @State private var calculatorCache = ProgressCalculatorCache()
    @State private var currentLocation: BlockLocation?
    @State private var furthestLocation: BlockLocation?
    @State private var currentProgressPercent: Double = 0
    @State private var furthestProgressPercent: Double = 0

    // Error handling
    @State private var loadError: String?
    @State private var isLoadingChapters = true

    // Chapter classification
    @State private var isClassifying = false
    @State private var hasAttemptedClassification = false
    @State private var classificationError: String?
    @State private var isProgrammaticScroll = false

    // Auto-scroll
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var autoScrollCountdownTask: Task<Void, Never>?
    @State private var autoScrollTargetDate: Date?
    @State private var autoScrollDuration: TimeInterval = 0
    @State private var showAutoScrollIndicator: Bool = false
    @State private var isAutoScrollCountingDown: Bool = false
    @State private var markerPositions: [MarkerInfo] = []
    @State private var lastViewportHeight: Double = 0
    @State private var lastScrollHeight: Double = 0
    @State private var lastAutoScrollTargetY: Double?

    private enum BackAnchorState {
        case inactive
        case pending
        case away
    }

    var body: some View {
        mainContent
            .onDisappear {
                stopReadingTicker()
                stopAutoScrollLoop()
                persistCurrentProgress()
                if let result = appState.readingSpeedTracker.endSession() {
                    appState.readingStats.addReadingTime(result.seconds)
                }
                currentAnalysisTask = nil
                currentImageTask = nil
            }
            .onChange(of: aiPanelSelectedTab) { oldTab, newTab in
                if newTab == .chat {
                    appState.readingSpeedTracker.startPause(reason: .chatting)
                } else if oldTab == .chat {
                    appState.readingSpeedTracker.endPause(reason: .chatting)
                }
                // Reset quiz auto-switch flag when manually leaving quiz - enables repeated tug gestures
                if oldTab == .quiz && newTab != .quiz {
                    hasAutoSwitchedToQuiz = false
                }
            }
            .onChange(of: expandedImage) { oldImage, newImage in
                if newImage != nil {
                    appState.readingSpeedTracker.startPause(reason: .viewingImage)
                } else if oldImage != nil {
                    appState.readingSpeedTracker.endPause(reason: .viewingImage)
                }
            }
    }

    private var mainContent: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let readerIdealWidth = totalWidth * appState.splitRatio
            let aiIdealWidth = totalWidth - readerIdealWidth

            HSplitView {
                bookContentPanel
                    .frame(minWidth: 400, idealWidth: readerIdealWidth)

                aiPanel
                    .frame(minWidth: 280, idealWidth: aiIdealWidth)
            }
            .onKeyPress { press in
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

                switch press.key {
                case .upArrow:
                    scrollByAmount = -200
                    return .handled
                case .downArrow:
                    scrollByAmount = 200
                    return .handled
                case .leftArrow:
                    if appState.currentChapterIndex > 0 {
                        appState.currentChapterIndex -= 1
                    }
                    return .handled
                case .rightArrow:
                    if appState.currentChapterIndex < chapters.count - 1 {
                        appState.currentChapterIndex += 1
                    }
                    return .handled
                default:
                    return .ignored
                }
            }
        }
        .background(theme.base)
        .overlay {
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
        .onAppear {
            startReadingTicker()
            startAutoScrollLoop()
        }
        .onChange(of: appState.currentChapterIndex) { oldIndex, newIndex in
            persistCurrentProgress()
            cancelAutoScrollCountdown()
            currentAnalysisTask = nil
            currentImageTask = nil
            Task { await loadChapter(at: newIndex) }
        }
        .onChange(of: appState.currentBook?.classificationStatus) { _, newValue in
            if newValue == .completed {
                // Check if current chapter was classified as garbage - end reading session if so
                if let book = appState.currentBook,
                   let freshChapters = try? appState.database.fetchChapters(for: book),
                   appState.currentChapterIndex < freshChapters.count,
                   freshChapters[appState.currentChapterIndex].isGarbage {
                    _ = appState.readingSpeedTracker.endSession()
                }
                Task { await loadChapter(at: appState.currentChapterIndex) }
            }
        }
    }

    @MainActor
    private var aiPanel: some View {
        let chapterState = currentChapter?.id.flatMap { processingStates[$0] } ?? ChapterProcessingState()

        return AIPanel(
            chapter: currentChapter,
            annotations: $annotations,
            quizzes: $quizzes,
            footnotes: footnotes,
            images: images,
            currentAnnotationId: currentAnnotationId,
            currentImageId: currentImageId,
            currentFootnoteRefId: currentFootnoteRefId,
            isProcessingInsights: chapterState.isProcessingInsights,
            isProcessingImages: chapterState.isProcessingImages,
            liveInsightCount: chapterState.liveInsightCount,
            liveQuizCount: chapterState.liveQuizCount,
            liveThinking: chapterState.liveThinking,
            isClassifying: isClassifying,
            classificationError: classificationError,
            analysisError: chapterState.analysisError,
            onScrollTo: { annotationId in
                suppressContextAutoSwitch()
                currentAnnotationId = annotationId
                setBackAnchor()
                scrollToAnnotationId = annotationId
            },
            onScrollToQuote: { quote in
                scrollToQuote = quote
            },
            onScrollToFootnote: { refId in
                suppressContextAutoSwitch()
                currentFootnoteRefId = refId
                setBackAnchor()
                scrollToQuote = refId
            },
            onScrollToBlockId: { blockId, imageId in
                if let iid = imageId {
                    currentImageId = iid
                }
                suppressContextAutoSwitch()
                setBackAnchor()
                let type = imageId != nil ? "image" : nil
                scrollToBlockId = (blockId, imageId, type)
            },
            onGenerateMoreInsights: {
                startGenerateMoreInsights()
            },
            onGenerateMoreQuestions: {
                startGenerateMoreQuestions()
            },
            onForceProcess: {
                forceProcessGarbageChapter()
            },
            onProcessManually: {
                processChapterManually()
            },
            onRetryClassification: {
                retryClassification()
            },
            onCancelAnalysis: {
                cancelCurrentAnalysis()
            },
            onCancelImages: {
                cancelCurrentImages()
            },
            autoScrollHighlightEnabled: appState.settings.autoScrollHighlightEnabled,
            isProgrammaticScroll: isProgrammaticScroll,
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
    }

    // MARK: - Keyboard Navigation

    private func cycleAIPanelTab(direction: Int) {
        let tabs = AIPanel.Tab.allCases
        guard let currentIndex = tabs.firstIndex(of: aiPanelSelectedTab), !tabs.isEmpty else { return }
        let nextIndex = (currentIndex + direction + tabs.count) % tabs.count
        aiPanelSelectedTab = tabs[nextIndex]
    }

    // MARK: - Book Content Panel

    private var bookContentPanel: some View {
        VStack(spacing: 0) {
            chapterHeader

            if let error = loadError {
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
            } else if isLoadingChapters || appState.currentBook?.importStatus == .metadataOnly {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(appState.currentBook?.importStatus == .metadataOnly ? "Importing book content..." : "Loading chapters...")
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
                        selectedTab: aiPanelSelectedTab,
                        onWordClick: handleWordClick,
                        onAnnotationClick: handleAnnotationClick,
                        onImageMarkerClick: handleImageMarkerClick,
                        onFootnoteClick: handleFootnoteClick,
                        onChapterNavigationRequest: handleChapterNavigation,
                        onImageMarkerDblClick: { imageId in
                            if let image = images.first(where: { $0.id == imageId }) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    expandedImage = image
                                }
                            }
                        },
                        onScrollPositionChange: { context in
                            isProgrammaticScroll = context.isProgrammatic

                            if !context.isProgrammatic {
                                // Manual scroll cancels auto-scroll countdown
                                cancelAutoScrollCountdown()
                            }
                            
                            // Always update viewport height from scroll events as the source of truth
                            if context.viewportHeight > 0 {
                                lastViewportHeight = context.viewportHeight
                            }

                            // If we reached or passed our auto-scroll target (downward scroll), clear it
                            if let target = lastAutoScrollTargetY {
                                // Clear if within tolerance OR if we scrolled past the target
                                if context.scrollOffset >= target - 10 {
                                    lastAutoScrollTargetY = nil
                                    // Properly end the auto-scroll visual state once physical movement is confirmed
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        showAutoScrollIndicator = false
                                    }
                                    autoScrollTargetDate = nil
                                }
                            }

                            if context.isProgrammatic {
                                if let aid = context.annotationId { currentAnnotationId = aid }
                                if let iid = context.imageId { currentImageId = iid }
                                if let fid = context.footnoteRefId { currentFootnoteRefId = fid }
                            } else {
                                currentAnnotationId = context.annotationId
                                currentImageId = context.imageId
                                currentFootnoteRefId = context.footnoteRefId
                            }

                            let progress = updateProgress(from: context, chapter: chapter)
                            currentProgressPercent = progress.current
                            furthestProgressPercent = progress.furthest
                            lastScrollPercent = progress.current
                            lastScrollOffset = context.scrollOffset
                            lastViewportHeight = context.viewportHeight
                            lastScrollHeight = context.scrollHeight

                            appState.recordReadingProgress(
                                chapter: chapter,
                                currentPercent: progress.current,
                                furthestPercent: progress.furthest,
                                scrollOffset: context.scrollOffset
                            )

                            // LIGHTWEIGHT: Update speed tracker (memory only)
                            appState.readingSpeedTracker.updateSession(scrollPercent: progress.current)
                            if !context.isProgrammatic && appState.readingSpeedTracker.isPaused {
                                appState.readingSpeedTracker.endAllPauses()
                            }
                            updateBackAnchor(scrollOffset: context.scrollOffset, viewportHeight: context.viewportHeight)

                            if context.scrollPercent < 0.85 {
                                hasAutoSwitchedToQuiz = false
                            }

                            handleAutoSwitch(context: context)
                        },
                        onMarkersUpdated: { markers in
                            self.markerPositions = markers
                        },
                        onBottomTug: {
                            handleQuizAutoSwitchOnTug()
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
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    if lastViewportHeight == 0 { lastViewportHeight = geo.size.height }
                                }
                                .onChange(of: geo.size.height) { _, newH in
                                    // Fallback updates if the webview hasn't reported yet
                                    if lastViewportHeight == 0 { lastViewportHeight = newH }
                                }
                        }
                    )

                    if showBackButton {
                        HStack(spacing: 0) {
                            // Back Action Area
                            Button {
                                returnToBackAnchor()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 10, weight: .black))
                                    Text("RETURN")
                                        .font(.system(size: 10, weight: .bold))
                                        .kerning(1.2)
                                }
                                .padding(.leading, 18)
                                .padding(.trailing, 14)
                                .padding(.vertical, 12)
                                .background(Color.black.opacity(0.001)) // Area-wide hit testing
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(BackAnchorButtonStyle(accentColor: theme.rose))

                            // Thin minimal divider (doesn't reach edges)
                            Rectangle()
                                .fill(theme.overlay)
                                .frame(width: 1, height: 18)

                            // Dismiss Action Area
                            Button {
                                dismissBackAnchor()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.leading, 14)
                                    .padding(.trailing, 18)
                                    .padding(.vertical, 12)
                                    .background(Color.black.opacity(0.001)) // Area-wide hit testing
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(BackAnchorButtonStyle(accentColor: theme.muted))
                        }
                        .background(
                            Capsule()
                                .fill(theme.surface)
                                .shadow(color: Color.black.opacity(0.1), radius: 15, y: 8)
                        )
                        .overlay {
                            Capsule()
                                .stroke(theme.rose.opacity(0.2), lineWidth: 1)
                        }
                        .padding(24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showBackButton)
            } else {
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

            navigationFooter
        }
    }

    // MARK: - Chapter Header

    private var chapterHeader: some View {
        HStack {
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
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.headerHeight)
        .background(theme.surface)
    }

    // MARK: - Chapter List Popover

    private var chapterListPopover: some View {
        ScrollViewReader { proxy in
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
                                    .foregroundColor(chapter.id == currentChapter?.id ? theme.rose : theme.text)
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
                            .background(chapter.id == currentChapter?.id ? theme.overlay : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                    }
                }
            }
            .onAppear {
                if let currentId = currentChapter?.id {
                    proxy.scrollTo(currentId, anchor: .center)
                }
            }
        }
        .frame(width: 280, height: min(CGFloat(chapters.count) * 36 + 16, 400))
        .background(theme.surface)
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        HStack {
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

            Text("\(appState.currentChapterIndex + 1) / \(chapters.count)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.muted)

            Spacer()

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
            ZStack(alignment: .leading) {
                // Base divider
                Rectangle()
                    .fill(theme.overlay)
                    .frame(height: 1)
                    .opacity(showAutoScrollIndicator ? 0 : 1)
                
                // Active "Fuse" Indicator
                if showAutoScrollIndicator, let targetDate = autoScrollTargetDate {
                    AutoScrollFuse(
                        targetDate: targetDate,
                        duration: autoScrollDuration,
                        theme: theme,
                        onComplete: {
                            // Execute Scroll
                            if let targetY = lastAutoScrollTargetY {
                                scrollToOffset = targetY
                                isAutoScrollCountingDown = false
                            }
                        }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: showAutoScrollIndicator)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(appState.currentBook?.title ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.text)
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadChapters() async {
        isLoadingChapters = true
        loadError = nil
        didRestoreInitialPosition = false
        guard let currentBook = appState.currentBook else { 
            loadError = "No book loaded"
            isLoadingChapters = false
            return
        }

        // Wait for background import to finalize metadata if needed
        var book = currentBook
        while book.importStatus == .metadataOnly {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let bookId = book.id, let fresh = try? appState.database.fetchBook(id: bookId) {
                book = fresh
                appState.currentBook = fresh
            }
        }

        do {
            if let bookId = book.id, let fresh = try? appState.database.fetchBook(id: bookId) {
                appState.currentBook = fresh
            }
            chapters = try appState.database.fetchChapters(for: appState.currentBook!)
            appState.updateBookProgressCache(book: appState.currentBook!, chapters: chapters)
            if chapters.isEmpty {
                loadError = "No chapters were found in this book."
                isLoadingChapters = false
                return
            }
            if appState.currentChapterIndex >= chapters.count {
                appState.currentChapterIndex = max(0, chapters.count - 1)
            }
            startClassificationIfNeeded()
            isLoadingChapters = false
            await loadChapter(at: appState.currentChapterIndex)
        } catch {
            loadError = "Database error: \(error.localizedDescription)"
            isLoadingChapters = false
        }
    }

    private func startReadingTicker() {
        readingTickTask?.cancel()
        readingTickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                appState.readingSpeedTracker.tick()
            }
        }
    }

    private func stopReadingTicker() {
        readingTickTask?.cancel()
        readingTickTask = nil
    }

    @MainActor
    private func startClassificationIfNeeded() {
        guard appState.settings.autoAIProcessingEnabled else { return }
        guard var currentBook = appState.currentBook, currentBook.needsClassification, !isClassifying, !hasAttemptedClassification else { return }
        hasAttemptedClassification = true
        isClassifying = true
        classificationError = nil
        currentBook.classificationStatus = .inProgress
        try? appState.database.saveBook(&currentBook)
        appState.currentBook = currentBook
        Task {
            await classifyBookChapters()
            if let updatedChapters = try? appState.database.fetchChapters(for: appState.currentBook!) {
                await MainActor.run {
                    chapters = updatedChapters
                    refreshCurrentChapterFromChapters()
                }
            } else {
                await MainActor.run { refreshCurrentChapterFromChapters() }
            }
            await MainActor.run { processCurrentChapterIfReady() }
        }
    }

    @MainActor
    private func classifyBookChapters() async {
        guard var currentBook = appState.currentBook else { return }
        do {
            let chapterData: [(index: Int, title: String, preview: String)] = chapters.map { chapter in
                let plainText = chapter.contentHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (index: chapter.index, title: chapter.title, preview: plainText)
            }
            let classifications = try await appState.llmService.classifyChapters(chapters: chapterData, settings: appState.settings)
            for i in 0..<chapters.count {
                var chapter = chapters[i]
                chapter.isGarbage = classifications[chapter.index] ?? false
                try appState.database.saveChapter(&chapter)
                chapters[i] = chapter
            }
            currentBook.classificationStatus = .completed
            currentBook.classificationError = nil
            try appState.database.saveBook(&currentBook)
            appState.currentBook = currentBook
        } catch {
            currentBook.classificationStatus = .failed
            currentBook.classificationError = error.localizedDescription
            try? appState.database.saveBook(&currentBook)
            appState.currentBook = currentBook
            classificationError = error.localizedDescription
        }
        isClassifying = false
    }

    func retryClassification() {
        Task { @MainActor in
            startClassificationIfNeeded()
        }
    }

    private func persistCurrentProgress() {
        guard let chapter = currentChapter else { return }
        appState.recordReadingProgress(
            chapter: chapter,
            currentPercent: currentProgressPercent,
            furthestPercent: furthestProgressPercent,
            scrollOffset: lastScrollOffset
        )
    }

    private func refreshCurrentChapterFromChapters() {
        guard let current = currentChapter,
              let index = chapters.firstIndex(where: { $0.id == current.id }) else { return }
        currentChapter = chapters[index]
    }

    private func cancelAutoScrollCountdown() {
        isAutoScrollCountingDown = false
        showAutoScrollIndicator = false
        autoScrollCountdownTask?.cancel()
        autoScrollCountdownTask = nil
        autoScrollTargetDate = nil
        lastAutoScrollTargetY = nil
    }

    private func stopAutoScrollLoop() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        cancelAutoScrollCountdown()
    }

    private func startAutoScrollLoop() {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // Poll every 1s

                // Check auto-scroll conditions
                // We allow auto-scroll if confidence is high OR if we are at the very start of the book (offset < 50)
                // This enables auto-scroll to work on the first page before the user has generated scroll data.
                let hasConfidence = appState.readingSpeedTracker.confidence >= 0.5
                let isAtStart = lastScrollOffset < 50
                
                guard appState.settings.smartAutoScrollEnabled,
                      !appState.readingSpeedTracker.isPaused,
                      (hasConfidence || isAtStart),
                      !isAutoScrollCountingDown,
                      !isProgrammaticScroll,
                      !isLoadingChapters,
                      currentChapter != nil else {
                    continue
                }

                // Don't auto-scroll if we just finished one and haven't moved
                if let lastTarget = lastAutoScrollTargetY, abs(lastScrollOffset - lastTarget) < 10 {
                    continue
                }

                runAutoScroll()
            }
        }
    }

    private func runAutoScroll() {
        guard let chapter = currentChapter,
              let chapterId = chapter.id,
              let calculator = calculatorCache.get(for: chapterId) else { return }
        
        // 1. Calculate Target
        let currentY = lastScrollOffset
        let vh = lastViewportHeight
        guard vh > 0 else { return }
        
        var targetY = currentY + vh * 0.8
        var targetMarker: MarkerInfo?
        
        // Check for markers in range (currentY + 10, targetY)
        // We look for markers that would be "exposed" by this scroll
        if let firstMarker = markerPositions.first(where: { $0.y > currentY + vh * 0.4 + 10 && $0.y <= targetY + vh * 0.4 }) {
            // Scroll so this marker is at the eyeline (40% from top)
            targetY = firstMarker.y - (vh * 0.4)
            targetMarker = firstMarker
        }
        
        // Ensure we don't scroll past the end
        let maxScroll = max(0, lastScrollHeight - vh)
        targetY = min(targetY, maxScroll)
        
        if targetY <= currentY + 10 { return } // Already there or too small jump
        
        // 2. Calculate Words in Range
        let startWords = calculator.totalWords(upTo: currentLocation ?? BlockLocation(blockId: 1, offset: 0))
        
        let endWords: Double
        if let marker = targetMarker {
            endWords = calculator.totalWords(upTo: BlockLocation(blockId: marker.blockId, offset: 0))
        } else {
            // Estimate based on scroll percent
            let scrollRange = lastScrollHeight - vh
            if scrollRange > 0 {
                let newPercent = targetY / scrollRange
                endWords = Double(calculator.totalWords) * newPercent
            } else {
                endWords = Double(calculator.totalWords)
            }
        }
        
        let wordsInRange = max(1, Int(endWords - Double(startWords)))
        
        // 3. Calculate Delay
        var delay = appState.readingSpeedTracker.calculateScrollDelay(wordsInView: wordsInRange)
        
        // Image bonus
        if targetMarker?.type == "image" {
            delay += 8
        }
        
        // Sanity check on delay
        delay = min(max(delay, 3), 120) // 3s to 2min
        
        // 4. Start Countdown
        startCountdown(delay: delay, targetY: targetY)
    }

    private func startCountdown(delay: Double, targetY: Double) {
        isAutoScrollCountingDown = true
        lastAutoScrollTargetY = targetY
        
        // Animation is now 1.5x faster
        autoScrollDuration = min(2.2, delay * 0.25)
        
        // VISUAL: The target date is the exact moment the scroll command is fired.
        autoScrollTargetDate = Date().addingTimeInterval(delay)
        
        autoScrollCountdownTask?.cancel()
        autoScrollCountdownTask = Task(priority: .high) { @MainActor in
            let waitToShow = max(0, delay - autoScrollDuration)
            if waitToShow > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitToShow * 1_000_000_000))
            }
            
            if !Task.isCancelled {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showAutoScrollIndicator = true
                }
                
                // Duration sleep removed - logic is now in AutoScrollFuse onComplete
            }
        }
    }

    private func processCurrentChapterIfReady() {
        guard let chapter = currentChapter, let currentBook = appState.currentBook, shouldAutoProcess(chapter, in: currentBook) else { return }
        Task { await processChapter(chapter) }
    }

    // MARK: - Progress Tracking

    private func updateProgress(from context: ScrollContext, chapter: Chapter) -> (current: Double, furthest: Double) {
        var current = context.scrollPercent
        var furthest = max(furthestProgressPercent, current)

        if let blockId = context.blockId {
            let offset = context.blockOffset ?? 0
            let location = BlockLocation(blockId: blockId, offset: offset)
            currentLocation = location
            if let furthestLoc = furthestLocation {
                if furthestLoc < location { furthestLocation = location }
            } else {
                furthestLocation = location
            }

            if let chapterId = chapter.id, let calculator = calculatorCache.get(for: chapterId) {
                current = calculator.percent(for: location)
                if let furthestLoc = furthestLocation {
                    furthest = calculator.percent(for: furthestLoc)
                }
            }
        }

        current = min(max(current, 0), 1)
        furthest = min(max(max(furthest, current), 0), 1)
        return (current, furthest)
    }

    private func ensureProgressCalculator(for chapter: Chapter) {
        guard let chapterId = chapter.id, calculatorCache.get(for: chapterId) == nil else { return }
        let html = chapter.contentHTML
        let chapterWordCount = chapter.wordCount
        Task.detached(priority: .utility) {
            let parser = ContentBlockParser()
            let (blocks, _) = parser.parse(html: html)
            let wordCounts = blocks.map { block in
                block.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            }
            let computedTotal = wordCounts.reduce(0, +)
            let totalWords = max(chapterWordCount, computedTotal)
            let calculator = ChapterProgressCalculator(wordCounts: wordCounts, totalWords: totalWords)
            await MainActor.run {
                calculatorCache.insert(calculator, for: chapterId, protecting: currentChapter?.id)

                guard currentChapter?.id == chapterId else { return }
                if let loc = currentLocation {
                    currentProgressPercent = calculator.percent(for: loc)
                }
                if let furthestLoc = furthestLocation {
                    let computedFurthest = calculator.percent(for: furthestLoc)
                    furthestProgressPercent = max(furthestProgressPercent, computedFurthest)
                }
                lastScrollPercent = currentProgressPercent
            }
        }
    }

    private func shouldAutoProcess(_ chapter: Chapter, in book: Book) -> Bool {
        appState.settings.autoAIProcessingEnabled && hasLLMKey && book.classificationStatus == .completed && !chapter.processed && !chapter.shouldSkipAutoProcessing
    }

    private func loadChapter(at index: Int) async {
        guard let currentBook = appState.currentBook else { return }
        if let updated = try? appState.database.fetchChapters(for: currentBook) { self.chapters = updated }
        guard index >= 0, index < chapters.count else { return }
        if let result = appState.readingSpeedTracker.endSession() {
            chapterWPM = result.wpm
            appState.readingStats.addReadingTime(result.seconds)
        }
        let chapter = chapters[index]
        let previousChapterId = currentChapter?.id
        currentChapter = chapter
        markerPositions = []
        hasAutoSwitchedToQuiz = false
        externalTabSelection = .insights
        currentAnnotationId = nil
        currentImageId = nil
        currentFootnoteRefId = nil
        lastAutoSwitchAt = 0
        suppressContextAutoSwitchUntil = 0
        showBackButton = false
        savedScrollOffset = nil
        backAnchorState = .inactive
        chapterWPM = nil
        
        if let anchor = pendingAnchor {
            scrollToQuote = anchor
            pendingAnchor = nil
            lastScrollPercent = 0
            lastScrollOffset = 0
            didRestoreInitialPosition = true
        } else if chapter.id == previousChapterId {
            // Reloading the same chapter - preserve current scroll position
            didRestoreInitialPosition = true
        } else {
            let shouldRestore = !didRestoreInitialPosition && index == currentBook.currentChapter
            if shouldRestore {
                if currentBook.currentScrollOffset > 0 {
                    scrollToOffset = currentBook.currentScrollOffset
                    scrollToPercent = nil
                } else {
                    scrollToPercent = currentBook.currentScrollPercent
                    scrollToOffset = nil
                }
                lastScrollPercent = currentBook.currentScrollPercent
                lastScrollOffset = currentBook.currentScrollOffset
                didRestoreInitialPosition = true
            } else {
                scrollToPercent = 0
                scrollToOffset = nil
                lastScrollPercent = 0
                lastScrollOffset = 0
                if didRestoreInitialPosition {
                    appState.recordReadingProgress(
                        chapter: chapter,
                        currentPercent: 0,
                        furthestPercent: chapter.maxScrollReached,
                        scrollOffset: 0
                    )
                } else { didRestoreInitialPosition = true }
            }
        }
        currentProgressPercent = lastScrollPercent
        furthestProgressPercent = max(chapter.maxScrollReached, currentProgressPercent)
        let wordCount = chapter.wordCount > 0 ? chapter.wordCount : estimateWordCount(from: chapter.contentHTML)
        // Don't track reading speed until classification confirms it's content (not front/back matter)
        // Fallback: If AI auto-processing is disabled, track regardless of garbage status
        let isClassifiedContent = currentBook.classificationStatus == .completed && !chapter.isGarbage
        let isAIDisabled = !appState.settings.autoAIProcessingEnabled
        
        if wordCount > 0, let chapterId = chapter.id, (isClassifiedContent || isAIDisabled) {
            appState.readingSpeedTracker.startSession(
                chapterId: chapterId,
                wordCount: wordCount,
                startPercent: currentProgressPercent
            )
        }
        currentLocation = nil
        furthestLocation = nil
        ensureProgressCalculator(for: chapter)
        do {
            annotations = try appState.database.fetchAnnotations(for: chapter)
            quizzes = try appState.database.fetchQuizzes(for: chapter)
            footnotes = try appState.database.fetchFootnotes(for: chapter)
            images = try appState.database.fetchImages(for: chapter)
        } catch { print("Failed to load chapter data: \(error)") }
        if shouldAutoProcess(chapter, in: currentBook) { await processChapter(chapter) }
    }

    func forceProcessGarbageChapter() {
        guard var chapter = currentChapter else { return }
        chapter.userOverride = true
        do {
            try appState.database.saveChapter(&chapter)
            currentChapter = chapter
            if let index = chapters.firstIndex(where: { $0.id == chapter.id }) { chapters[index] = chapter }
        } catch { return }
        Task { await processChapter(chapter) }
    }

    func processChapterManually() {
        guard let chapter = currentChapter else { return }
        Task { await processChapter(chapter) }
    }

    private func cancelCurrentAnalysis() {
        currentAnalysisTask?.cancel()
        currentImageTask?.cancel()
        currentAnalysisTask = nil
        currentImageTask = nil
        if let id = currentChapter?.id {
            processingStates[id]?.isProcessingInsights = false
            processingStates[id]?.isProcessingImages = false
        }
    }

    private func cancelCurrentImages() {
        currentImageTask?.cancel()
        currentImageTask = nil
        if let id = currentChapter?.id {
            processingStates[id]?.isProcessingImages = false
        }
    }

    @MainActor
    private func beginInsightProcessing(for chapterId: Int64) {
        var state = processingStates[chapterId] ?? ChapterProcessingState()
        state.isProcessingInsights = true
        state.liveInsightCount = 0
        state.liveQuizCount = 0
        state.liveThinking = ""
        state.analysisError = nil
        processingStates[chapterId] = state
    }

    @MainActor
    private func endInsightProcessing(for chapterId: Int64) {
        guard var state = processingStates[chapterId] else { return }
        state.isProcessingInsights = false
        state.liveThinking = ""
        processingStates[chapterId] = state
    }

    private func collectAnalysis(
        from stream: AsyncThrowingStream<LLMService.ChapterAnalysisStreamEvent, Error>,
        chapterId: Int64
    ) async throws -> LLMService.ChapterAnalysis? {
        var finalAnalysis: LLMService.ChapterAnalysis?
        var lastThinkingUpdate = Date.distantPast

        for try await event in stream {
            if Task.isCancelled { throw CancellationError() }

            switch event {
            case .thinking(let text):
                if Date().timeIntervalSince(lastThinkingUpdate) > 0.1 {
                    await MainActor.run {
                        processingStates[chapterId]?.liveThinking = text
                    }
                    lastThinkingUpdate = Date()
                }
            case .insightFound:
                await MainActor.run {
                    processingStates[chapterId]?.liveInsightCount += 1
                }
            case .quizQuestionFound:
                await MainActor.run {
                    processingStates[chapterId]?.liveQuizCount += 1
                }
            case .usage:
                break  // Token tracking handled globally by LLMService
            case .completed(let analysis):
                finalAnalysis = analysis
            }
        }

        return finalAnalysis
    }

    private func processChapter(_ chapter: Chapter) async {
        guard let bookId = appState.currentBook?.id, let chapterId = chapter.id else { return }
        
        if processingStates[chapterId]?.isProcessingInsights == true { return }
        beginInsightProcessing(for: chapterId)
        
        currentAnalysisTask = Task {
            do {
                let blockParser = ContentBlockParser()
                let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
                
                let stream = appState.llmService.analyzeChapterStreaming(
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: chapter.rollingSummary,
                    bookTitle: appState.currentBook?.title,
                    author: appState.currentBook?.author,
                    settings: appState.settings
                )
                
                guard let analysis = try await collectAnalysis(from: stream, chapterId: chapterId) else {
                    await MainActor.run { endInsightProcessing(for: chapterId) }
                    return
                }
                
                var injections: [MarkerInjection] = []
                
                for data in analysis.annotations {
                    let type = AnnotationType(rawValue: data.type) ?? .science
                    let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count ? data.sourceBlockId : 1
                    var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: validBlockId)
                    try appState.database.saveAnnotation(&annotation)
                    
                    await MainActor.run {
                        if currentChapter?.id == chapterId {
                            annotations.append(annotation)
                            if let id = annotation.id {
                                injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId))
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    if currentChapter?.id == chapterId && !injections.isEmpty {
                        pendingMarkerInjections = injections
                    }
                }
                
                await MainActor.run { endInsightProcessing(for: chapterId) }
                
                for data in analysis.quizQuestions {
                    let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count ? data.sourceBlockId : 1
                    var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: validBlockId)
                    try appState.database.saveQuiz(&quiz)
                    await MainActor.run {
                        if currentChapter?.id == chapterId {
                            quizzes.append(quiz)
                        }
                    }
                }
                
                if appState.settings.imagesEnabled && !analysis.imageSuggestions.isEmpty {
                    let imageTask = Task { [analysis] in
                        await generateSuggestedImages(
                            analysis.imageSuggestions,
                            blockCount: blocks.count,
                            bookId: bookId,
                            chapterId: chapterId
                        )
                    }
                    await MainActor.run {
                        processingStates[chapterId]?.isProcessingImages = true
                        if currentChapter?.id == chapterId {
                            currentImageTask = imageTask
                        }
                    }
                    await imageTask.value
                    await MainActor.run {
                        processingStates[chapterId]?.isProcessingImages = false
                        if currentChapter?.id == chapterId {
                            currentImageTask = nil
                        }
                    }
                }
                
                if Task.isCancelled { return }
                
                await MainActor.run {
                    
                    var updatedChapter = chapter
                    updatedChapter.processed = true
                    updatedChapter.summary = analysis.summary
                    updatedChapter.contentText = contentWithBlocks
                    updatedChapter.blockCount = blocks.count
                    try? appState.database.saveChapter(&updatedChapter)
                    
                    if currentChapter?.id == chapterId { currentChapter = updatedChapter }
                    if let idx = chapters.firstIndex(where: { $0.id == chapterId }) { chapters[idx] = updatedChapter }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        processingStates[chapterId]?.isProcessingInsights = false
                        processingStates[chapterId]?.isProcessingImages = false
                        processingStates[chapterId]?.analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
    }

    private func generateSuggestedImages(_ suggestions: [LLMService.ImageSuggestion], blockCount: Int, bookId: Int64, chapterId: Int64) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }
        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        let inputs = imageInputs(from: suggestions, blockCount: blockCount, rewrite: appState.settings.rewriteImageExcerpts)
        let results = await appState.imageService.generateImages(from: inputs, model: appState.settings.imageModel, apiKey: trimmedKey, maxConcurrent: 5)
        if Task.isCancelled { return }
        await storeGeneratedImages(results, bookId: bookId, chapterId: chapterId)
    }

    private func imageInputs(from suggestions: [LLMService.ImageSuggestion], blockCount: Int, rewrite: Bool) -> [ImageService.ImageSuggestionInput] {
        suggestions.map {
            let validBlockId = $0.sourceBlockId > 0 && $0.sourceBlockId <= blockCount ? $0.sourceBlockId : 1
            let excerpt = $0.excerpt
            let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: rewrite)
            return ImageService.ImageSuggestionInput(excerpt: excerpt, prompt: prompt, sourceBlockId: validBlockId)
        }
    }

    @MainActor
    private func startGenerateMoreInsights() {
        guard let chapter = currentChapter, let chapterId = chapter.id, hasLLMKey else { return }
        guard processingStates[chapterId]?.isProcessingInsights != true else { return }

        beginInsightProcessing(for: chapterId)
        currentAnalysisTask = Task {
            await generateMoreInsights(for: chapter)
        }
    }

    @MainActor
    private func startGenerateMoreQuestions() {
        guard let chapter = currentChapter, let chapterId = chapter.id, hasLLMKey else { return }
        guard processingStates[chapterId]?.isProcessingInsights != true else { return }

        beginInsightProcessing(for: chapterId)
        currentAnalysisTask = Task {
            await generateMoreQuestions(for: chapter)
        }
    }

    private func storeGeneratedImages(_ results: [ImageService.GeneratedImageResult], bookId: Int64, chapterId: Int64) async {
        for result in results {
            do {
                let imagePath = try appState.imageService.saveImage(result.imageData, for: bookId, chapterId: chapterId)
                var image = GeneratedImage(chapterId: chapterId, prompt: result.excerpt, imagePath: imagePath, sourceBlockId: result.sourceBlockId)
                try appState.database.saveImage(&image)
                appState.readingStats.recordImage()
                
                await MainActor.run {
                    if currentChapter?.id == chapterId {
                        images.append(image)
                        if let id = image.id {
                            pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId))
                        }
                    }
                }
            } catch { continue }
        }
    }

    private func generateMoreInsights(for chapter: Chapter) async {
        guard let chapterId = chapter.id else { return }
        defer {
            Task { @MainActor in
                endInsightProcessing(for: chapterId)
            }
        }
        do {
            let (contentWithBlocks, blockCount) = chapter.getContentText()
            let existingTitles = annotations.map { $0.title }
            let stream = appState.llmService.generateMoreInsightsStreaming(
                contentWithBlocks: contentWithBlocks,
                rollingSummary: chapter.rollingSummary,
                existingTitles: existingTitles,
                settings: appState.settings
            )
            guard let analysis = try await collectAnalysis(from: stream, chapterId: chapterId) else { return }
            
            var injections: [MarkerInjection] = []
            for data in analysis.annotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount ? data.sourceBlockId : 1
                var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: validBlockId)
                try appState.database.saveAnnotation(&annotation)
                
                await MainActor.run {
                    if currentChapter?.id == chapterId {
                        annotations.append(annotation)
                        if let id = annotation.id {
                            injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId))
                        }
                    }
                }
            }
            
            await MainActor.run {
                if currentChapter?.id == chapterId && !injections.isEmpty {
                    pendingMarkerInjections = injections
                }
            }
        } catch {
            await MainActor.run {
                processingStates[chapterId]?.analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func generateMoreQuestions(for chapter: Chapter) async {
        guard let chapterId = chapter.id else { return }
        defer {
            Task { @MainActor in
                endInsightProcessing(for: chapterId)
            }
        }
        do {
            let (contentWithBlocks, blockCount) = chapter.getContentText()
            let existingQuestions = quizzes.map { $0.question }
            let stream = appState.llmService.generateMoreQuestionsStreaming(
                contentWithBlocks: contentWithBlocks,
                rollingSummary: chapter.rollingSummary,
                existingQuestions: existingQuestions,
                settings: appState.settings
            )
            guard let analysis = try await collectAnalysis(from: stream, chapterId: chapterId) else { return }
            
            for data in analysis.quizQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount ? data.sourceBlockId : 1
                var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: validBlockId)
                try appState.database.saveQuiz(&quiz)
                
                await MainActor.run {
                    if currentChapter?.id == chapterId {
                        quizzes.append(quiz)
                    }
                }
            }
        } catch {
            await MainActor.run {
                processingStates[chapterId]?.analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func fullScreenImageOverlay(_ image: GeneratedImage) -> some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { expandedImage = nil } }
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.2)) { expandedImage = nil } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 32)).foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 30)
                .padding(.top, 20)
                AsyncImage(url: image.imageURL) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage.resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.5), radius: 20)
                    case .failure:
                        VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.system(size: 48)); Text("Failed to load image").font(.system(size: 16)) }.foregroundColor(.white.opacity(0.6))
                    case .empty:
                        ProgressView().progressViewStyle(.circular).scaleEffect(1.5)
                    @unknown default: EmptyView()
                    }
                }
                .padding(.horizontal, 60)
                Text(image.prompt).font(.system(size: 14)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 80).padding(.bottom, 30)
            }
        }
    }

    private func handleWordClick(word: String, context: String, blockId: Int, action: BookContentView.WordAction) {
        switch action {
        case .explain:
            pendingChatPrompt = appState.llmService.explainWordChatPrompt(word: word, context: context)
        case .generateImage:
            guard let chapter = currentChapter, let chapterId = chapter.id, appState.settings.imagesEnabled else { return }
            Task {
                do {
                    let excerpt = word
                    let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: appState.settings.rewriteImageExcerpts)
                    let imageData = try await appState.imageService.generateImage(prompt: prompt, model: appState.settings.imageModel, apiKey: appState.settings.googleAPIKey)
                    guard let bookId = appState.currentBook?.id else { return }
                    let imagePath = try appState.imageService.saveImage(imageData, for: bookId, chapterId: chapterId)
                    var image = GeneratedImage(chapterId: chapterId, prompt: excerpt, imagePath: imagePath, sourceBlockId: blockId > 0 ? blockId : 1)
                    try appState.database.saveImage(&image)
                    
                    await MainActor.run {
                        if currentChapter?.id == chapterId {
                            images.append(image)
                            if let id = image.id {
                                pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId))
                            }
                        }
                    }
                } catch { }
            }
        }
    }

    private func handleAnnotationClick(_ annotation: Annotation) {
        currentAnnotationId = annotation.id
        externalTabSelection = .insights
    }

    private func handleChapterNavigation(_ path: String, _ anchor: String?) {
        if let targetIndex = chapters.firstIndex(where: { $0.resourcePath == path }) {
            if appState.currentChapterIndex == targetIndex {
                if let anchor = anchor {
                    scrollToQuote = anchor
                }
            } else {
                pendingAnchor = anchor
                appState.currentChapterIndex = targetIndex
            }
        }
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

    private func handleAutoSwitch(context: ScrollContext) {
        if appState.settings.autoSwitchFromChatOnScroll && aiPanelSelectedTab == .chat && !context.isProgrammatic {
            aiPanelSelectedTab = .insights
            return
        }

        guard appState.settings.autoSwitchContextTabs else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if now < suppressContextAutoSwitchUntil { return }
        if aiPanelSelectedTab == .quiz || aiPanelSelectedTab == .chat { return }
        guard let primaryType = context.primaryType else { return }

        let targetTab: AIPanel.Tab? = {
            switch primaryType {
            case "annotation": return .insights
            case "image": return .images
            case "footnote": return .footnotes
            default: return nil
            }
        }()

        guard let tab = targetTab, tab != aiPanelSelectedTab else { return }
        if now - lastAutoSwitchAt < 0.2 { return }
        lastAutoSwitchAt = now
        withAnimation(.easeOut(duration: 0.2)) { aiPanelSelectedTab = tab }
    }

    private func suppressContextAutoSwitch(for duration: TimeInterval = 2.0) {
        let now = Date().timeIntervalSinceReferenceDate
        suppressContextAutoSwitchUntil = max(suppressContextAutoSwitchUntil, now + duration)
    }

    private func handleQuizAutoSwitchOnTug() {
        guard appState.settings.autoSwitchToQuiz, !quizzes.isEmpty, !hasAutoSwitchedToQuiz else { return }
        if aiPanelSelectedTab == .quiz { return }
        hasAutoSwitchedToQuiz = true
        let now = Date().timeIntervalSinceReferenceDate
        suppressContextAutoSwitchUntil = now + 1.0
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { aiPanelSelectedTab = .quiz } }
    }

    private func setBackAnchor() {
        if savedScrollOffset == nil {
            savedScrollOffset = lastScrollOffset
            showBackButton = true
            backAnchorState = .pending
        }
    }

    private func dismissBackAnchor() {
        showBackButton = false
        savedScrollOffset = nil
        backAnchorState = .inactive
    }

    private func returnToBackAnchor() {
        if let offset = savedScrollOffset { scrollToOffset = offset }
        dismissBackAnchor()
    }

    private func updateBackAnchor(scrollOffset: Double, viewportHeight: Double) {
        guard showBackButton, let savedOffset = savedScrollOffset else { return }
        let leaveThreshold = viewportHeight > 0 ? max(80, viewportHeight * 0.12) : 120
        let returnThreshold = viewportHeight > 0 ? max(48, viewportHeight * 0.06) : 72
        let distance = abs(scrollOffset - savedOffset)
        switch backAnchorState {
        case .pending: if distance > leaveThreshold { backAnchorState = .away }
        case .away: if distance <= returnThreshold { dismissBackAnchor() }
        case .inactive: break
        }
    }

    private var hasLLMKey: Bool {
        switch appState.settings.llmProvider {
        case .google: return !appState.settings.googleAPIKey.isEmpty
        case .openai: return !appState.settings.openAIAPIKey.isEmpty
        case .anthropic: return !appState.settings.anthropicAPIKey.isEmpty
        }
    }

    private func estimateWordCount(from html: String) -> Int {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let words = stripped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.count
    }
}

// MARK: - UI Components

struct BackAnchorButtonStyle: ButtonStyle {
    let accentColor: Color
    @State private var isHovered = false
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let highlightColor = accentColor == theme.muted ? theme.text : accentColor
        
        configuration.label
            .foregroundColor(configuration.isPressed ? highlightColor : (isHovered ? highlightColor : theme.muted))
            .background(isHovered ? highlightColor.opacity(0.06) : Color.clear)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.2), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.set() }
                else { NSCursor.arrow.set() }
            }
    }
}

// MARK: - Auto Scroll Animation Component

fileprivate struct AutoScrollFuse: View {
    let targetDate: Date
    let duration: TimeInterval
    let theme: Theme
    let onComplete: () -> Void

    @State private var hasTriggered = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let timeRemaining = targetDate.timeIntervalSince(now)
            let progress = 1.0 - (timeRemaining / duration)
            
            // Trigger completion on the exact frame the target is reached
            let _ = {
                if now >= targetDate && !hasTriggered {
                    DispatchQueue.main.async {
                        if !hasTriggered {
                            hasTriggered = true
                            onComplete()
                        }
                    }
                }
            }()

            GeometryReader { proxy in
                let width = proxy.size.width
                let isOvertime = progress >= 1.0
                
                // Cap the visual fill at 100%, but let the spark handle the wait
                let fillWidth = width * min(1.0, max(0, progress))
                
                ZStack(alignment: .leading) {
                    // 1. The Fuse Line (Energy Beam)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: theme.rose.opacity(0.0), location: 0),
                                    .init(color: theme.rose.opacity(0.5), location: 0.7),
                                    .init(color: theme.rose, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                        .shadow(color: theme.rose.opacity(0.5), radius: 3, x: 0, y: 0)
                    
                    // 2. The Spark (Burning Head)
                    // If overtime (waiting for JS/MainActor latency), it stays at the end and glows
                    let sparkSize: CGFloat = isOvertime ? 4 : 3
                    let pulse = isOvertime ? (sin(now.timeIntervalSince(targetDate) * 15) * 0.5 + 0.5) : 0
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: sparkSize, height: sparkSize)
                        .shadow(color: .white, radius: 2 + pulse) // Hot core
                        .shadow(color: theme.rose, radius: 6 + (pulse * 4)) // Glow
                        .offset(x: fillWidth - (sparkSize / 2)) // Center on tip
                        .opacity(progress > 0.01 ? 1 : progress * 100) // Fade in start
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

