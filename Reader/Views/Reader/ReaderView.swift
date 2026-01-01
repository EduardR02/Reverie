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
    @State private var isProcessingInsights = false
    @State private var isProcessingImages = false
    @State private var processingChapterId: Int64?
    @State private var isGeneratingMore = false
    @State private var analysisError: String?

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

    // Image generation
    @State private var imageGenerating = false
    @State private var expandedImage: GeneratedImage?  // Full-screen image overlay

    // Error handling
    @State private var loadError: String?
    @State private var isLoadingChapters = true

    // Chapter classification
    @State private var isClassifying = false
    @State private var hasAttemptedClassification = false
    @State private var classificationError: String?
    @State private var isProgrammaticScroll = false

    // Navigation Intent (to break feedback loop)
    @State private var navigationIntent: NavigationIntent?

    private struct NavigationIntent: Equatable {
        let targetId: String 
        let timestamp: TimeInterval
        
        static func annotation(_ id: Int64) -> NavigationIntent {
            .init(targetId: "annotation-\(id)", timestamp: Date().timeIntervalSinceReferenceDate)
        }
        
        static func image(_ id: Int64) -> NavigationIntent {
            .init(targetId: "image-\(id)", timestamp: Date().timeIntervalSinceReferenceDate)
        }
        
        static func footnote(_ id: String) -> NavigationIntent {
            .init(targetId: "footnote-\(id)", timestamp: Date().timeIntervalSinceReferenceDate)
        }
        
        static func block(_ id: Int) -> NavigationIntent {
            .init(targetId: "block-\(id)", timestamp: Date().timeIntervalSinceReferenceDate)
        }
        
        var isExpired: Bool {
            Date().timeIntervalSinceReferenceDate - timestamp > 2.5 
        }
    }

    private enum BackAnchorState {
        case inactive
        case pending
        case away
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let readerIdealWidth = totalWidth * appState.splitRatio
            let aiIdealWidth = totalWidth - readerIdealWidth

            HSplitView {
                // Left: Book Content
                bookContentPanel
                    .frame(minWidth: 400, idealWidth: readerIdealWidth)

                // Right: AI Panel
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
        .onChange(of: appState.currentChapterIndex) { _, newIndex in
            Task { await loadChapter(at: newIndex) }
        }
        .onChange(of: appState.currentBook?.classificationStatus) { _, newValue in
            if newValue == .completed {
                Task { await loadChapter(at: appState.currentChapterIndex) }
            }
        }
        .onDisappear {
            if let chapter = currentChapter {
                appState.updateChapterProgress(
                    chapter: chapter,
                    scrollPercent: lastScrollPercent,
                    scrollOffset: lastScrollOffset
                )
            }
            if let result = appState.readingSpeedTracker.endSession() {
                appState.readingStats.addReadingTime(result.seconds)
                appState.readingStats.addWords(result.words)
            }
        }
    }

    @MainActor
    private var aiPanel: some View {
        AIPanel(
            chapter: currentChapter,
            annotations: $annotations,
            quizzes: $quizzes,
            footnotes: footnotes,
            images: images,
            currentAnnotationId: currentAnnotationId,
            currentImageId: currentImageId,
            currentFootnoteRefId: currentFootnoteRefId,
            isProcessingInsights: isProcessingInsights,
            isProcessingImages: isProcessingImages,
            isGeneratingMore: isGeneratingMore,
            isClassifying: isClassifying,
            classificationError: classificationError,
            analysisError: analysisError,
            onScrollTo: { annotationId in
                navigationIntent = .annotation(annotationId)
                suppressContextAutoSwitch()
                currentAnnotationId = annotationId
                setBackAnchor()
                scrollToAnnotationId = annotationId
            },
            onScrollToQuote: { quote in
                navigationIntent = nil 
                scrollToQuote = quote
            },
            onScrollToFootnote: { refId in
                navigationIntent = .footnote(refId)
                suppressContextAutoSwitch()
                currentFootnoteRefId = refId
                setBackAnchor()
                scrollToQuote = refId
            },
            onScrollToBlockId: { blockId, imageId in
                if let iid = imageId {
                    navigationIntent = .image(iid)
                    currentImageId = iid
                } else {
                    navigationIntent = .block(blockId)
                }
                suppressContextAutoSwitch()
                setBackAnchor()
                let type = imageId != nil ? "image" : nil
                scrollToBlockId = (blockId, imageId, type)
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
        withAnimation(.easeOut(duration: 0.15)) {
            aiPanelSelectedTab = tabs[nextIndex]
        }
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
            } else if isLoadingChapters {
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
                        selectedTab: aiPanelSelectedTab,
                        onWordClick: handleWordClick,
                        onAnnotationClick: handleAnnotationClick,
                        onImageMarkerClick: handleImageMarkerClick,
                        onFootnoteClick: handleFootnoteClick,
                        onImageMarkerDblClick: { imageId in
                            if let image = images.first(where: { $0.id == imageId }) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    expandedImage = image
                                }
                            }
                        },
                        onScrollPositionChange: { context in
                            isProgrammaticScroll = context.isProgrammatic

                            // Selection Lock logic
                            if !context.isProgrammatic {
                                navigationIntent = nil
                            }

                            let isLocked: Bool = {
                                if let intent = navigationIntent, !intent.isExpired {
                                    let targets = [
                                        context.annotationId.map { "annotation-\($0)" },
                                        context.footnoteRefId.map { "footnote-\($0)" },
                                        context.imageId.map { "image-\($0)" },
                                        context.blockId.map { "block-\($0)" }
                                    ].compactMap { $0 }

                                    if targets.contains(intent.targetId) {
                                        navigationIntent = nil
                                        return false
                                    }
                                    return true
                                }
                                return false
                            }()

                            if !isLocked {
                                currentAnnotationId = context.annotationId
                                currentImageId = context.imageId
                                currentFootnoteRefId = context.footnoteRefId
                            }

                            lastScrollPercent = context.scrollPercent
                            lastScrollOffset = context.scrollOffset

                            appState.updateChapterProgress(chapter: chapter, scrollPercent: context.scrollPercent, scrollOffset: context.scrollOffset)
                            appState.readingSpeedTracker.updateSession(scrollPercent: context.scrollPercent)
                            updateBackAnchor(scrollOffset: context.scrollOffset, viewportHeight: context.viewportHeight)

                            if context.scrollPercent < 0.85 {
                                hasAutoSwitchedToQuiz = false
                            }

                            handleAutoSwitch(context: context)
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

                    if showBackButton {
                        HStack(spacing: 0) {
                            Button {
                                returnToBackAnchor()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Back")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                if isHovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }

                            Rectangle()
                                .fill(theme.base.opacity(0.25))
                                .frame(width: 1, height: 14)

                            Button {
                                dismissBackAnchor()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                if isHovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(theme.base)
                        .background(theme.rose)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showBackButton)
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
                }
            }
        }
        .frame(width: 280, height: min(CGFloat(chapters.count) * 36 + 16, 400))
        .background(theme.surface)
    }

    // MARK: - Navigation Footer

    private var navigationFooter: some View {
        VStack(spacing: 0) {
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
        do {
            if let bookId = currentBook.id, let fresh = try? appState.database.fetchAllBooks().first(where: { $0.id == bookId }) {
                appState.currentBook = fresh
            }
            chapters = try appState.database.fetchChapters(for: appState.currentBook!)
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

    @MainActor
    private func startClassificationIfNeeded() {
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

    private func refreshCurrentChapterFromChapters() {
        guard let current = currentChapter,
              let index = chapters.firstIndex(where: { $0.id == current.id }) else { return }
        currentChapter = chapters[index]
    }

    private func processCurrentChapterIfReady() {
        guard let chapter = currentChapter, let currentBook = appState.currentBook, shouldAutoProcess(chapter, in: currentBook) else { return }
        Task { await processChapter(chapter) }
    }

    private func shouldAutoProcess(_ chapter: Chapter, in book: Book) -> Bool {
        hasLLMKey && book.classificationStatus == .completed && !chapter.processed && !chapter.shouldSkipAutoProcessing
    }

    private func loadChapter(at index: Int) async {
        guard let currentBook = appState.currentBook else { return }
        if let updated = try? appState.database.fetchChapters(for: currentBook) { self.chapters = updated }
        guard index >= 0, index < chapters.count else { return }
        if let result = appState.readingSpeedTracker.endSession() {
            chapterWPM = result.wpm
            appState.readingStats.addReadingTime(result.seconds)
            appState.readingStats.addWords(result.words)
        }
        let chapter = chapters[index]
        currentChapter = chapter
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
        let wordCount = estimateWordCount(from: chapter.contentHTML)
        if wordCount > 0 { appState.readingSpeedTracker.startSession(chapterId: chapter.id!, wordCount: wordCount) }
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
                appState.updateChapterProgress(chapter: chapter, scrollPercent: 0, scrollOffset: 0)
            } else { didRestoreInitialPosition = true }
        }
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

    private func processChapter(_ chapter: Chapter) async {
        guard let bookId = appState.currentBook?.id else { return }
        let chapterId = chapter.id!
        if processingChapterId == chapterId { return }
        analysisError = nil
        processingChapterId = chapterId
        isProcessingInsights = true
        defer { 
            if processingChapterId == chapterId {
                isProcessingInsights = false
                isProcessingImages = false
                processingChapterId = nil
            }
        }
        do {
            let blockParser = ContentBlockParser()
            let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
            let analysis = try await appState.llmService.analyzeChapter(contentWithBlocks: contentWithBlocks, rollingSummary: chapter.rollingSummary, settings: appState.settings)
            if Task.isCancelled { return }
            let stillOnSameChapter = currentChapter?.id == chapterId
            var injections: [MarkerInjection] = []
            for data in analysis.annotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count ? data.sourceBlockId : 1
                var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: validBlockId)
                try appState.database.saveAnnotation(&annotation)
                if stillOnSameChapter {
                    annotations.append(annotation)
                    if let id = annotation.id { injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId)) }
                }
            }
            if stillOnSameChapter && !injections.isEmpty { await MainActor.run { pendingMarkerInjections = injections } }
            if stillOnSameChapter { isProcessingInsights = false }
            for data in analysis.quizQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count ? data.sourceBlockId : 1
                var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: validBlockId)
                try appState.database.saveQuiz(&quiz)
                if stillOnSameChapter { quizzes.append(quiz) }
            }
            if stillOnSameChapter && appState.settings.imagesEnabled && !analysis.imageSuggestions.isEmpty { isProcessingImages = true }
            if Task.isCancelled { return }
            await generateSuggestedImages(analysis.imageSuggestions, blockCount: blocks.count, bookId: bookId, chapterId: chapterId, stillOnSameChapter: stillOnSameChapter)
            isProcessingImages = false
            processingChapterId = nil
            var updatedChapter = chapter
            updatedChapter.processed = true
            updatedChapter.summary = analysis.summary
            updatedChapter.contentText = contentWithBlocks
            updatedChapter.blockCount = blocks.count
            try appState.database.saveChapter(&updatedChapter)
            if stillOnSameChapter { currentChapter = updatedChapter }
            if let idx = chapters.firstIndex(where: { $0.id == chapterId }) { chapters[idx] = updatedChapter }
        } catch {
            if currentChapter?.id == chapterId { analysisError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func generateSuggestedImages(_ suggestions: [LLMService.ImageSuggestion], blockCount: Int, bookId: Int64, chapterId: Int64, stillOnSameChapter: Bool) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }
        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        imageGenerating = true
        defer { imageGenerating = false }
        let inputs = imageInputs(from: suggestions, blockCount: blockCount, rewrite: appState.settings.rewriteImageExcerpts)
        let results = await appState.imageService.generateImages(from: inputs, model: appState.settings.imageModel, apiKey: trimmedKey, maxConcurrent: 5)
        if Task.isCancelled { return }
        await storeGeneratedImages(results, bookId: bookId, chapterId: chapterId, stillOnSameChapter: stillOnSameChapter)
    }

    private func imageInputs(from suggestions: [LLMService.ImageSuggestion], blockCount: Int, rewrite: Bool) -> [ImageService.ImageSuggestionInput] {
        suggestions.map {
            let validBlockId = $0.sourceBlockId > 0 && $0.sourceBlockId <= blockCount ? $0.sourceBlockId : 1
            let excerpt = $0.excerpt
            let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: rewrite)
            return ImageService.ImageSuggestionInput(excerpt: excerpt, prompt: prompt, sourceBlockId: validBlockId)
        }
    }

    private func storeGeneratedImages(_ results: [ImageService.GeneratedImageResult], bookId: Int64, chapterId: Int64, stillOnSameChapter: Bool) async {
        for result in results {
            do {
                let imagePath = try appState.imageService.saveImage(result.imageData, for: bookId, chapterId: chapterId)
                var image = GeneratedImage(chapterId: chapterId, prompt: result.excerpt, imagePath: imagePath, sourceBlockId: result.sourceBlockId)
                try appState.database.saveImage(&image)
                appState.readingStats.recordImage()
                if stillOnSameChapter {
                    images.append(image)
                    if let id = image.id { pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId)) }
                }
            } catch { continue }
        }
    }

    private func generateMoreInsights() async {
        guard let chapter = currentChapter, hasLLMKey else { return }
        let chapterId = chapter.id!
        isGeneratingMore = true
        defer { isGeneratingMore = false }
        do {
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
            let newAnnotations = try await appState.llmService.generateMoreInsights(contentWithBlocks: contentWithBlocks, rollingSummary: chapter.rollingSummary, existingTitles: existingTitles, settings: appState.settings)
            let stillOnSameChapter = currentChapter?.id == chapterId
            var injections: [MarkerInjection] = []
            for data in newAnnotations {
                let type = AnnotationType(rawValue: data.type) ?? .science
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount ? data.sourceBlockId : 1
                var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: validBlockId)
                try appState.database.saveAnnotation(&annotation)
                if stillOnSameChapter {
                    annotations.append(annotation)
                    if let id = annotation.id { injections.append(MarkerInjection(annotationId: id, sourceBlockId: validBlockId)) }
                }
            }
            if stillOnSameChapter { await MainActor.run { pendingMarkerInjections = injections } }
        } catch { return }
    }

    private func generateMoreQuestions() async {
        guard let chapter = currentChapter, hasLLMKey else { return }
        let chapterId = chapter.id!
        isGeneratingMore = true
        defer { isGeneratingMore = false }
        do {
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
            let newQuestions = try await appState.llmService.generateMoreQuestions(contentWithBlocks: contentWithBlocks, rollingSummary: chapter.rollingSummary, existingQuestions: existingQuestions, settings: appState.settings)
            let stillOnSameChapter = currentChapter?.id == chapterId
            for data in newQuestions {
                let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blockCount ? data.sourceBlockId : 1
                var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: validBlockId)
                try appState.database.saveQuiz(&quiz)
                if stillOnSameChapter { quizzes.append(quiz) }
            }
        } catch { return }
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
            guard let chapter = currentChapter, appState.settings.imagesEnabled else { return }
            imageGenerating = true
            Task {
                do {
                    let excerpt = word
                    let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: appState.settings.rewriteImageExcerpts)
                    let imageData = try await appState.imageService.generateImage(prompt: prompt, model: appState.settings.imageModel, apiKey: appState.settings.googleAPIKey)
                    guard let bookId = appState.currentBook?.id else { return }
                    let imagePath = try appState.imageService.saveImage(imageData, for: bookId, chapterId: chapter.id!)
                    var image = GeneratedImage(chapterId: chapter.id!, prompt: excerpt, imagePath: imagePath, sourceBlockId: blockId > 0 ? blockId : 1)
                    try appState.database.saveImage(&image)
                    images.append(image)
                    if let id = image.id { pendingImageMarkerInjections.append(ImageMarkerInjection(imageId: id, sourceBlockId: image.sourceBlockId)) }
                } catch { }
                imageGenerating = false
            }
        }
    }

    private func handleAnnotationClick(_ annotation: Annotation) {
        currentAnnotationId = annotation.id
        externalTabSelection = .insights
    }

    private func handleImageMarkerClick(_ imageId: Int64) {
        guard images.contains(where: { $0.id == imageId }) else { return }
        navigationIntent = nil 
        currentImageId = imageId
        externalTabSelection = .images
    }

    private func handleFootnoteClick(_ refId: String) {
        guard footnotes.contains(where: { $0.refId == refId }) else { return }
        navigationIntent = nil
        currentFootnoteRefId = refId
        externalTabSelection = .footnotes
    }

    private func handleAutoSwitch(context: ScrollContext) {
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
