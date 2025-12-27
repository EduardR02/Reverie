import SwiftUI

struct ReaderView: View {
    let book: Book

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
    @State private var scrollToAnnotationId: Int64?
    @State private var scrollToPercent: Double?
    @State private var scrollToOffset: Double?
    @State private var scrollToQuote: String?
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

    // Reading speed tracking
    @State private var chapterWPM: Double?

    // Word action
    @State private var showExplanationSheet = false
    @State private var explanationLoading = false
    @State private var explanationText: String?
    @State private var explanationWord: String = ""

    // Image generation
    @State private var imageGenerating = false
    @State private var imageGenerationWord: String = ""

    // Error handling
    @State private var loadError: String?
    @State private var isLoadingChapters = true

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
                isProcessing: isProcessing,
                isGeneratingMore: isGeneratingMore,
                onScrollTo: { annotationId in
                    // Save current position for back navigation
                    savedScrollOffset = lastScrollOffset
                    showBackButton = true
                    scrollToAnnotationId = annotationId
                },
                onScrollToQuote: { quote in
                    scrollToQuote = quote
                },
                onScrollToFootnote: { refId in
                    // Scroll to footnote reference in text
                    scrollToQuote = refId  // Will be handled by JS to find the footnote link
                },
                onGenerateMoreInsights: {
                    Task { await generateMoreInsights() }
                },
                onGenerateMoreQuestions: {
                    Task { await generateMoreQuestions() }
                },
                externalTabSelection: $externalTabSelection,
                scrollPercent: lastScrollPercent,
                chapterWPM: chapterWPM,
                onApplyAdjustment: { adjustment in
                    appState.readingSpeedTracker.applyAdjustment(adjustment)
                }
            )
            .frame(minWidth: 280, idealWidth: 340)
        }
        .background(theme.base)
        .toolbar {
            toolbarContent
        }
        .task {
            await loadChapters()
        }
        .onChange(of: appState.currentChapterIndex) { _, newIndex in
            Task { await loadChapter(at: newIndex) }
        }
        .sheet(isPresented: $showExplanationSheet) {
            explanationSheet
        }
        .onDisappear {
            pendingProgressSaveTask?.cancel()
            saveReadingProgress(scrollPercent: lastScrollPercent, scrollOffset: lastScrollOffset)
            // End reading session when leaving the reader
            if appState.readingSpeedTracker.currentSession != nil {
                _ = appState.readingSpeedTracker.endSession()
            }
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
                        onScrollPositionChange: { annotationId, scrollPercent, scrollOffset in
                            currentAnnotationId = annotationId
                            lastScrollPercent = scrollPercent
                            lastScrollOffset = scrollOffset
                            scheduleProgressSave(scrollPercent: scrollPercent, scrollOffset: scrollOffset)

                            // Update reading speed session
                            appState.readingSpeedTracker.updateSession(scrollPercent: scrollPercent)

                            // Auto-switch to quiz when near bottom of chapter
                            if appState.settings.autoSwitchToQuiz &&
                               scrollPercent > 0.95 &&
                               !hasAutoSwitchedToQuiz &&
                               !quizzes.isEmpty {
                                hasAutoSwitchedToQuiz = true
                                // Small delay for graceful transition
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    externalTabSelection = .quiz
                                }
                            }
                        },
                        scrollToAnnotationId: $scrollToAnnotationId,
                        scrollToPercent: $scrollToPercent,
                        scrollToOffset: $scrollToOffset,
                        scrollToQuote: $scrollToQuote
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

    // MARK: - Explanation Sheet

    private var explanationSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Explaining: \(explanationWord)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.text)

                Spacer()

                Button {
                    showExplanationSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(theme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            if explanationLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Thinking...")
                        .font(.system(size: 13))
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if let text = explanationText {
                ScrollView {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundColor(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
        .background(theme.surface)
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
        .padding(.horizontal, 20)
        .frame(height: 48)
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
            // Reading speed info bar (when enabled)
            if appState.settings.showReadingSpeedFooter {
                HStack(spacing: 12) {
                    if appState.readingSpeedTracker.averageWPM > 0 {
                        // Average WPM
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 10))
                            Text("\(appState.readingSpeedTracker.formattedAverageWPM) WPM")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.iris)

                        // Confidence indicator
                        let confidence = appState.readingSpeedTracker.confidence
                        HStack(spacing: 4) {
                            Circle()
                                .fill(confidence >= 0.8 ? theme.foam : theme.gold)
                                .frame(width: 6, height: 6)
                            Text(confidence >= 0.8 ? "Calibrated" : "Calibrating...")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(theme.muted)
                    } else {
                        // Placeholder when no data yet
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 10))
                            Text("Learning your pace...")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.muted)

                        Text("Finish a chapter to calibrate")
                            .font(.system(size: 10))
                            .foregroundColor(theme.subtle)
                    }

                    Spacer()

                    // Lock/pause toggle (only show when we have data)
                    if appState.readingSpeedTracker.averageWPM > 0 {
                        Button {
                            appState.readingSpeedTracker.toggleLock()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: appState.readingSpeedTracker.isLocked ? "lock.fill" : "lock.open")
                                    .font(.system(size: 10))
                                Text(appState.readingSpeedTracker.isLocked ? "Locked" : "Tracking")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(appState.readingSpeedTracker.isLocked ? theme.rose : theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(appState.readingSpeedTracker.isLocked ? theme.rose.opacity(0.15) : theme.overlay)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(appState.readingSpeedTracker.isLocked ? "Reading speed is locked" : "Click to lock reading speed")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(theme.surface)

                Divider()
                    .background(theme.overlay)
            }

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(theme.surface)
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
            } else {
                if appState.currentChapterIndex >= chapters.count {
                    appState.currentChapterIndex = max(0, chapters.count - 1)
                }
                await loadChapter(at: appState.currentChapterIndex)
            }
        } catch {
            loadError = "Database error: \(error.localizedDescription)"
        }

        isLoadingChapters = false
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

        // Process chapter if not already processed and API key is set
        if !chapter.processed && hasLLMKey {
            await processChapter(chapter)
        }
    }

    private func processChapter(_ chapter: Chapter) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            let analysis = try await appState.llmService.analyzeChapter(
                content: chapter.contentHTML,
                rollingSummary: chapter.rollingSummary,
                settings: appState.settings
            )

            // Save annotations
            for data in analysis.annotations {
                let type = AnnotationType(rawValue: data.type) ?? .insight
                var annotation = Annotation(
                    chapterId: chapter.id!,
                    type: type,
                    title: data.title,
                    content: data.content,
                    sourceQuote: data.sourceQuote,
                    sourceOffset: findOffset(for: data.sourceQuote, in: chapter.contentHTML)
                )
                try appState.database.saveAnnotation(&annotation)
                annotations.append(annotation)
            }

            // Save quizzes
            for data in analysis.quizQuestions {
                var quiz = Quiz(
                    chapterId: chapter.id!,
                    question: data.question,
                    answer: data.answer,
                    sourceQuote: data.sourceQuote,
                    sourceOffset: findOffset(for: data.sourceQuote, in: chapter.contentHTML)
                )
                try appState.database.saveQuiz(&quiz)
                quizzes.append(quiz)
            }

            // Update chapter as processed
            var updatedChapter = chapter
            updatedChapter.processed = true
            updatedChapter.summary = analysis.summary
            try appState.database.saveChapter(&updatedChapter)
            currentChapter = updatedChapter

            // Update in chapters array
            if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
                chapters[idx] = updatedChapter
            }

        } catch {
            print("Failed to process chapter: \(error)")
        }
    }

    private func generateMoreInsights() async {
        guard let chapter = currentChapter, hasLLMKey else { return }

        isGeneratingMore = true
        defer { isGeneratingMore = false }

        do {
            let existingTitles = annotations.map { $0.title }
            let newAnnotations = try await appState.llmService.generateMoreInsights(
                content: chapter.contentHTML,
                rollingSummary: chapter.rollingSummary,
                existingTitles: existingTitles,
                settings: appState.settings
            )

            for data in newAnnotations {
                let type = AnnotationType(rawValue: data.type) ?? .insight
                var annotation = Annotation(
                    chapterId: chapter.id!,
                    type: type,
                    title: data.title,
                    content: data.content,
                    sourceQuote: data.sourceQuote,
                    sourceOffset: findOffset(for: data.sourceQuote, in: chapter.contentHTML)
                )
                try appState.database.saveAnnotation(&annotation)
                annotations.append(annotation)
            }
        } catch {
            print("Failed to generate more insights: \(error)")
        }
    }

    private func generateMoreQuestions() async {
        guard let chapter = currentChapter, hasLLMKey else { return }

        isGeneratingMore = true
        defer { isGeneratingMore = false }

        do {
            let existingQuestions = quizzes.map { $0.question }
            let newQuestions = try await appState.llmService.generateMoreQuestions(
                content: chapter.contentHTML,
                rollingSummary: chapter.rollingSummary,
                existingQuestions: existingQuestions,
                settings: appState.settings
            )

            for data in newQuestions {
                var quiz = Quiz(
                    chapterId: chapter.id!,
                    question: data.question,
                    answer: data.answer,
                    sourceQuote: data.sourceQuote,
                    sourceOffset: findOffset(for: data.sourceQuote, in: chapter.contentHTML)
                )
                try appState.database.saveQuiz(&quiz)
                quizzes.append(quiz)
            }
        } catch {
            print("Failed to generate more questions: \(error)")
        }
    }

    // MARK: - Word Actions

    private func handleWordClick(word: String, context: String, offset: Int, action: BookContentView.WordAction) {
        switch action {
        case .explain:
            explanationWord = word
            explanationText = nil
            explanationLoading = true
            showExplanationSheet = true

            Task {
                do {
                    let explanation = try await appState.llmService.explainWord(
                        word: word,
                        context: context,
                        rollingSummary: currentChapter?.rollingSummary,
                        settings: appState.settings
                    )
                    explanationText = explanation
                } catch {
                    explanationText = "Failed to get explanation: \(error.localizedDescription)"
                }
                explanationLoading = false
            }

        case .generateImage:
            guard let chapter = currentChapter, appState.settings.imagesEnabled else { return }

            imageGenerating = true
            imageGenerationWord = word

            Task {
                do {
                    // First get the image prompt from LLM
                    let prompt = try await appState.llmService.generateImagePrompt(
                        word: word,
                        context: context,
                        settings: appState.settings
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
                        prompt: prompt,
                        imagePath: imagePath,
                        sourceOffset: offset
                    )
                    try appState.database.saveImage(&image)
                    images.append(image)

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

    private func findOffset(for quote: String, in content: String) -> Int {
        if let range = content.range(of: quote) {
            return content.distance(from: content.startIndex, to: range.lowerBound)
        }
        return 0
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
