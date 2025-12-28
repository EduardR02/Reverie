import SwiftUI

struct AIPanel: View {
    let chapter: Chapter?
    let annotations: [Annotation]
    let quizzes: [Quiz]
    let footnotes: [Footnote]
    let images: [GeneratedImage]
    let currentAnnotationId: Int64?
    let currentFootnoteRefId: String?
    let isProcessing: Bool
    let isGeneratingMore: Bool
    let isClassifying: Bool
    let classificationError: String?
    let onScrollTo: (Int64) -> Void  // Scroll to annotation by ID
    let onScrollToQuote: (String) -> Void  // Scroll to quote text (for quizzes)
    let onScrollToFootnote: (String) -> Void  // Scroll to footnote reference by refId
    let onScrollToBlockId: (Int) -> Void  // Scroll to block by ID (for images/quizzes)
    let onGenerateMoreInsights: () -> Void
    let onGenerateMoreQuestions: () -> Void
    let onForceProcess: () -> Void  // Force process garbage chapter
    let onRetryClassification: () -> Void  // Retry failed classification
    @Binding var externalTabSelection: Tab?  // External control for tab switching
    @Binding var selectedTab: Tab
    @Binding var pendingChatPrompt: String?

    // Reading speed tracking
    let scrollPercent: Double
    let chapterWPM: Double?  // WPM for current chapter session
    let onApplyAdjustment: (ReadingSpeedTracker.AdjustmentType) -> Void

    @State private var highlightedFootnoteId: String?
    @State private var showedSpeedPromptForChapter: Int64?  // Track which chapter we showed prompt for
    @State private var isPromptAnimating = false  // Prevent layout chaos during popup animation
    @Binding var expandedImage: GeneratedImage?  // Image shown in fullscreen overlay (shown at ReaderView level)

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var chatInput = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var expandedAnnotationId: Int64?
    @State private var chatScrollViewHeight: CGFloat = 0
    @State private var chatContentMetrics = ChatContentMetrics(height: 0, minY: 0)
    @State private var chatAutoScrollEnabled = true
    @State private var chatScrollTick = 0

    private let chatScrollSpace = "chat-scroll"
    private let chatBottomId = "chat-bottom"

    enum Tab: String, CaseIterable {
        case insights = "Insights"
        case images = "Images"
        case quiz = "Quiz"
        case footnotes = "Notes"
        case chat = "Chat"

        var icon: String {
            switch self {
            case .insights: return "lightbulb"
            case .images: return "photo"
            case .quiz: return "checkmark.circle"
            case .footnotes: return "note.text"
            case .chat: return "bubble.left.and.bubble.right"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            // Content with safe area inset for reading speed footer only
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsSharedPanels && appState.settings.showReadingSpeedFooter {
                        readingSpeedFooter
                    }
                }
        }
        .background(theme.surface)
        .onChange(of: currentAnnotationId) { _, newId in
            // Auto-expand the current annotation when scrolling through text
            // Skip during popup animation to prevent chaotic layout
            if let newId = newId, selectedTab == .insights, !isPromptAnimating {
                withAnimation(.easeOut(duration: 0.2)) {
                    expandedAnnotationId = newId
                }
            }
        }
        .onChange(of: currentFootnoteRefId) { _, newId in
            highlightedFootnoteId = newId
        }
        .onChange(of: externalTabSelection) { _, newTab in
            // External tab control (e.g., auto-switch to quiz at chapter end)
            if let tab = newTab {
                if selectedTab != tab {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                }
                // Reset external selection after applying
                DispatchQueue.main.async {
                    externalTabSelection = nil
                }
            }
        }
        .onChange(of: pendingChatPrompt) { _, newPrompt in
            let trimmed = newPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                selectedTab = .chat
            }
            sendMessage(trimmed)
            DispatchQueue.main.async {
                pendingChatPrompt = nil
            }
        }
    }

    private var showsSharedPanels: Bool {
        selectedTab != .chat
    }

    private var shouldShowSpeedPrompt: Bool {
        scrollPercent > 0.9 && showedSpeedPromptForChapter != chapter?.id
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .insights:
            insightsTab
        case .images:
            imagesTab
        case .quiz:
            quizTab
        case .footnotes:
            footnotesTab
        case .chat:
            chatTab
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))

                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))

                        // Badge for counts
                        if tab == .insights && !annotations.isEmpty {
                            Text("\(annotations.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(selectedTab == tab ? theme.base : theme.rose)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(selectedTab == tab ? theme.rose : theme.rose.opacity(0.2))
                                .clipShape(Capsule())
                        } else if tab == .images && !images.isEmpty {
                            Text("\(images.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(selectedTab == tab ? theme.base : theme.iris)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(selectedTab == tab ? theme.iris : theme.iris.opacity(0.2))
                                .clipShape(Capsule())
                        } else if tab == .quiz && !quizzes.isEmpty {
                            Text("\(quizzes.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(selectedTab == tab ? theme.base : theme.rose)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(selectedTab == tab ? theme.rose : theme.rose.opacity(0.2))
                                .clipShape(Capsule())
                        } else if tab == .footnotes && !footnotes.isEmpty {
                            Text("\(footnotes.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(selectedTab == tab ? theme.base : theme.foam)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(selectedTab == tab ? theme.foam : theme.foam.opacity(0.2))
                            .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .foregroundColor(selectedTab == tab ? theme.rose : theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selectedTab == tab ? theme.overlay : Color.clear)
            }
        }
        .frame(height: ReaderMetrics.headerHeight)
        .background(theme.surface)
    }

    // MARK: - Insights Tab

    private var insightsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Classification in progress
                    if isClassifying {
                        classifyingBanner
                    }

                    // Classification error banner
                    if classificationError != nil {
                        classificationErrorBanner
                    }

                    // Garbage chapter banner (show when chapter is garbage and not yet processed)
                    if let chapter = chapter, chapter.shouldSkipAutoProcessing && !chapter.processed {
                        garbageChapterBanner
                    }

                    // Processing indicator
                    if isProcessing {
                        processingBanner(text: "Generating insights...")
                    }

                    if annotations.isEmpty && !isProcessing && !isClassifying && (chapter?.shouldSkipAutoProcessing != true) {
                        emptyState(
                            icon: "lightbulb",
                            title: "No insights yet",
                            subtitle: "Insights will appear as you read"
                        )
                    } else if !annotations.isEmpty {
                        ForEach(annotations) { annotation in
                            if let annotationId = annotation.id {
                                AnnotationCard(
                                    annotation: annotation,
                                    isExpanded: expandedAnnotationId == annotationId,
                                    isCurrent: currentAnnotationId == annotationId,
                                    onToggle: {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            if expandedAnnotationId == annotationId {
                                                expandedAnnotationId = nil
                                            } else {
                                                expandedAnnotationId = annotationId
                                                // Auto-scroll to passage when expanding
                                                onScrollTo(annotationId)
                                            }
                                        }
                                    },
                                    onScrollTo: {
                                        onScrollTo(annotationId)
                                    }
                                )
                                .id(annotationId)
                            }
                        }
                    }

                    // More insights button
                    if !annotations.isEmpty && !isProcessing {
                        Button {
                            onGenerateMoreInsights()
                        } label: {
                            HStack(spacing: 6) {
                                if isGeneratingMore {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Generating...")
                                } else {
                                    Image(systemName: "plus.circle")
                                    Text("More insights")
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isGeneratingMore)
                    }

                    // Chapter complete prompt (shows at 90% scroll)
                    if shouldShowSpeedPrompt {
                        chapterCompletePrompt
                    }
                }
                .padding(16)
            }
            .onChange(of: currentAnnotationId) { oldValue, newValue in
                // Auto-scroll to current insight and expand it
                // Skip during popup animation to prevent chaotic layout
                // Use .top anchor so insights near top of list can still be scrolled to
                if let id = newValue, !isPromptAnimating {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .top)
                        expandedAnnotationId = id
                    }
                }
            }
        }
    }

    // MARK: - Images Tab

    private var imagesTab: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if images.isEmpty {
                    emptyState(
                        icon: "photo",
                        title: "No images yet",
                        subtitle: "Images will appear as they're generated"
                    )
                } else {
                    ForEach(images) { image in
                        ImageCard(
                            image: image,
                            onScrollTo: {
                                onScrollToBlockId(image.sourceBlockId)
                            },
                            onExpand: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    expandedImage = image
                                }
                            }
                        )
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Quiz Tab

    private var quizTab: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Compact reading speed prompt (at top of quiz)
                if shouldShowSpeedPrompt {
                    compactSpeedPrompt
                }

                // Processing indicator
                if isProcessing {
                    processingBanner(text: "Generating questions...")
                }

                if quizzes.isEmpty && !isProcessing {
                    emptyState(
                        icon: "checkmark.circle",
                        title: "No quiz yet",
                        subtitle: "Quiz questions will appear at chapter end"
                    )
                } else if !quizzes.isEmpty {
                    ForEach(quizzes) { quiz in
                        QuizCard(
                            quiz: quiz,
                            onScrollTo: {
                                onScrollToBlockId(quiz.sourceBlockId)
                            }
                        )
                    }

                    // More questions button
                    if !isProcessing {
                        Button {
                            onGenerateMoreQuestions()
                        } label: {
                            HStack(spacing: 6) {
                                if isGeneratingMore {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Generating...")
                                } else {
                                    Image(systemName: "plus.circle")
                                    Text("More questions")
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isGeneratingMore)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Footnotes Tab

    private var footnotesTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if footnotes.isEmpty {
                        emptyState(
                            icon: "note.text",
                            title: "No footnotes",
                            subtitle: "This chapter has no footnotes"
                        )
                    } else {
                        ForEach(footnotes) { footnote in
                            FootnoteCard(
                                footnote: footnote,
                                isHighlighted: highlightedFootnoteId == footnote.refId,
                                onScrollTo: {
                                    onScrollToFootnote(footnote.refId)
                                }
                            )
                            .id(footnote.refId)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: highlightedFootnoteId) { _, newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    // Remove highlight after animation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if highlightedFootnoteId == id {
                            highlightedFootnoteId = nil
                        }
                    }
                }
            }
            .onAppear {
                if let id = highlightedFootnoteId {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Chat Tab

    private var chatTab: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Messages
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatMessages.isEmpty {
                            emptyState(
                                icon: "bubble.left.and.bubble.right",
                                title: "Ask anything",
                                subtitle: "I have the current chapter in context"
                            )
                        } else {
                            ForEach(chatMessages) { message in
                                ChatBubble(message: message)
                            }
                        }
                        Color.clear.frame(height: 1).id(chatBottomId)
                    }
                    .padding(16)
                    .background(
                        GeometryReader { geo in
                            let metrics = ChatContentMetrics(
                                height: geo.size.height,
                                minY: geo.frame(in: .named(chatScrollSpace)).minY
                            )
                            Color.clear.preference(key: ChatContentMetricsKey.self, value: metrics)
                        }
                    )
                }
                .coordinateSpace(name: chatScrollSpace)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChatScrollViewHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ChatContentMetricsKey.self) { metrics in
                    chatContentMetrics = metrics
                    updateChatAutoScroll()
                }
                .onPreferenceChange(ChatScrollViewHeightKey.self) { height in
                    chatScrollViewHeight = height
                    updateChatAutoScroll()
                }

                // Input
                chatInputBar
            }
            .onChange(of: chatScrollTick) { _, _ in
                guard chatAutoScrollEnabled else { return }
                proxy.scrollTo(chatBottomId, anchor: .bottom)
            }
            .onChange(of: chatAutoScrollEnabled) { _, enabled in
                if enabled {
                    proxy.scrollTo(chatBottomId, anchor: .bottom)
                }
            }
        }
    }

    private var chatInputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about this chapter...", text: $chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme.base)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: isLoading ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(chatInput.isEmpty ? theme.muted : theme.rose)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(chatInput.isEmpty || isLoading)
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

    // MARK: - Shared Panels

    private var chapterCompletePrompt: some View {
        ReadingSpeedPrompt(
            chapterWPM: chapterWPM,
            averageWPM: appState.readingSpeedTracker.averageWPM,
            confidence: appState.readingSpeedTracker.confidence,
            onApplyAdjustment: { adjustment in
                onApplyAdjustment(adjustment)
                showedSpeedPromptForChapter = chapter?.id
            },
            onDismiss: {
                showedSpeedPromptForChapter = chapter?.id
            }
        )
    }

    /// Compact reading speed prompt for quiz tab
    private var compactSpeedPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.iris)

            VStack(alignment: .leading, spacing: 2) {
                Text("Chapter Complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.text)

                if let wpm = chapterWPM, wpm > 0 {
                    Text("\(Int(wpm)) WPM this chapter")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
            }

            Spacer()

            Button {
                showedSpeedPromptForChapter = chapter?.id
            } label: {
                Text("OK")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.foam)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.foam.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(theme.iris.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.iris.opacity(0.2), lineWidth: 1)
        }
    }

    private var readingSpeedFooter: some View {
        HStack(spacing: 10) {
            if appState.readingSpeedTracker.averageWPM > 0 {
                let confidence = appState.readingSpeedTracker.confidence
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 10))

                    Text("\(appState.readingSpeedTracker.formattedAverageWPM) WPM")
                        .font(.system(size: 11, weight: .medium))

                    Text("•")
                        .foregroundColor(theme.muted)

                    Circle()
                        .fill(confidence >= 0.8 ? theme.foam : theme.gold)
                        .frame(width: 5, height: 5)

                    Text(confidence >= 0.8 ? "Calibrated" : "Calibrating...")
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.iris)
            } else {
                // Placeholder when no data yet
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 10))
                    Text("Learning your pace...")
                        .font(.system(size: 11, weight: .medium))
                    Text("•")
                        .foregroundColor(theme.muted)
                    Text("Finish a chapter to calibrate")
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
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
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.footerHeight)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.overlay)
                .frame(height: 1)
        }
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.muted)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(theme.text)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(theme.muted)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Processing Banner

    private func processingBanner(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.rose)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(theme.rose.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Banner shown for garbage chapters (front/back matter)
    private var garbageChapterBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.system(size: 16))
                    .foregroundColor(theme.muted)

                Text("Front/Back Matter")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            Text("This chapter looks like front or back matter (copyright, acknowledgements, etc). AI generation was skipped.")
                .font(.system(size: 12))
                .foregroundColor(theme.muted)
                .lineSpacing(3)

            Button {
                onForceProcess()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Process Anyway")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foam)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(theme.foam.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.overlay.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Banner shown when classification failed
    private var classificationErrorBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundColor(theme.gold)

                Text("Classification Failed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            if let error = classificationError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
                    .lineSpacing(3)
            }

            Text("Will retry automatically when you reopen this book.")
                .font(.system(size: 11))
                .foregroundColor(theme.subtle)

            Button {
                onRetryClassification()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry Now")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.gold)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(theme.gold.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Banner shown while classifying chapters
    private var classifyingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Classifying chapters...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.foam)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(theme.foam.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    @MainActor
    private func sendMessage(_ text: String? = nil) {
        let rawInput = text ?? chatInput
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let chapter = chapter else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        chatMessages.append(userMessage)
        chatScrollTick += 1
        let query = trimmed
        if text == nil {
            chatInput = ""
        }

        // Add empty assistant message for streaming
        let assistantMessage = ChatMessage(role: .assistant, content: "", thinking: nil)
        chatMessages.append(assistantMessage)
        chatScrollTick += 1
        let messageIndex = chatMessages.count - 1

        isLoading = true

        Task {
            do {
                var contentBuffer = ""
                var thinkingBuffer = ""

                // Get or generate clean text with block markers
                let contentWithBlocks: String
                if let cached = chapter.contentText {
                    contentWithBlocks = cached
                } else {
                    let (_, text) = ContentBlockParser().parse(html: chapter.contentHTML)
                    contentWithBlocks = text
                }

                let stream = appState.llmService.chatStreaming(
                    message: query,
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: chapter.rollingSummary,
                    settings: appState.settings
                )

                for try await chunk in stream {
                    if chunk.isThinking {
                        thinkingBuffer += chunk.text
                        await MainActor.run {
                            chatMessages[messageIndex].thinking = thinkingBuffer
                            chatScrollTick += 1
                        }
                    } else {
                        contentBuffer += chunk.text
                        await MainActor.run {
                            chatMessages[messageIndex].content = contentBuffer
                            chatScrollTick += 1
                        }
                    }
                }

                // Finalize message
                if contentBuffer.isEmpty && !thinkingBuffer.isEmpty {
                    await MainActor.run {
                        chatMessages[messageIndex].content = "(Reasoning only - no response)"
                        chatScrollTick += 1
                    }
                } else if contentBuffer.isEmpty && thinkingBuffer.isEmpty {
                    await MainActor.run {
                        chatMessages[messageIndex].content = "No response returned. Try again."
                        chatScrollTick += 1
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    chatMessages[messageIndex].content = message
                    chatScrollTick += 1
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func normalizedChapterText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let condensed = stripped.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return condensed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateChatAutoScroll() {
        guard chatScrollViewHeight > 0 else { return }
        let distanceToBottom = chatContentMetrics.height + chatContentMetrics.minY - chatScrollViewHeight
        let shouldAutoScroll = distanceToBottom <= 20
        if chatAutoScrollEnabled != shouldAutoScroll {
            chatAutoScrollEnabled = shouldAutoScroll
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    var thinking: String?

    enum Role {
        case user
        case assistant
    }

    init(role: Role, content: String, thinking: String? = nil) {
        self.role = role
        self.content = content
        self.thinking = thinking
    }
}

private struct ChatContentMetrics: Equatable {
    let height: CGFloat
    let minY: CGFloat
}

private struct ChatContentMetricsKey: PreferenceKey {
    static var defaultValue = ChatContentMetrics(height: 0, minY: 0)

    static func reduce(value: inout ChatContentMetrics, nextValue: () -> ChatContentMetrics) {
        value = nextValue()
    }
}

private struct ChatScrollViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    @Environment(\.theme) private var theme
    @State private var showThinking = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 8) {
                // Thinking section (collapsible)
                if let thinking = message.thinking, !thinking.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showThinking.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Reasoning")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Image(systemName: showThinking ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.base.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        if showThinking {
                            Text(thinking)
                                .font(.system(size: 12))
                                .foregroundColor(theme.subtle)
                                .italic()
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.base.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                // Main content
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundColor(message.role == .user ? theme.base : theme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? theme.rose : theme.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Annotation Card

struct AnnotationCard: View {
    let annotation: Annotation
    let isExpanded: Bool
    let isCurrent: Bool
    let onToggle: () -> Void
    let onScrollTo: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // Type icon
                    Image(systemName: annotation.type.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.rose)
                        .frame(width: 24, height: 24)
                        .background(theme.rose.opacity(0.15))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(annotation.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.text)
                            .lineLimit(isExpanded ? nil : 1)

                        Text(annotation.type.label)
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.muted)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .background(theme.overlay)

                    Text(annotation.content)
                        .font(.system(size: 13))
                        .foregroundColor(theme.text)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    // Jump to source
                    Button(action: onScrollTo) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                            Text("Go to passage")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.rose)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(isCurrent ? theme.overlay : theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? theme.rose : theme.overlay, lineWidth: isCurrent ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}

// MARK: - Quiz Card

struct QuizCard: View {
    let quiz: Quiz
    let onScrollTo: () -> Void

    @Environment(\.theme) private var theme
    @State private var showAnswer = false
    @State private var userResponse: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question
            Text(quiz.question)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.text)
                .textSelection(.enabled)

            if showAnswer {
                // Answer
                VStack(alignment: .leading, spacing: 8) {
                    Text(quiz.answer)
                        .font(.system(size: 13))
                        .foregroundColor(theme.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.overlay)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: onScrollTo) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                            Text("See in text")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.rose)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Show answer button
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAnswer = true
                    }
                } label: {
                    Text("Show Answer")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.rose)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.rose.opacity(0.15))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Feedback buttons (after answer shown)
            if showAnswer && userResponse == nil {
                HStack(spacing: 12) {
                    Text("Did you know this?")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)

                    Spacer()

                    Button {
                        userResponse = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundColor(theme.foam)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        userResponse = false
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 20))
                            .foregroundColor(theme.love)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    userResponse == true ? theme.foam :
                    userResponse == false ? theme.love :
                    theme.overlay,
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Footnote Card

struct FootnoteCard: View {
    let footnote: Footnote
    let isHighlighted: Bool
    let onScrollTo: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with marker
            HStack(spacing: 8) {
                Text(footnote.marker)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.base)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.foam)
                    .clipShape(Capsule())

                Text("Footnote")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)

                Spacer()

                Button(action: onScrollTo) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                        Text("Go to reference")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.foam)
                }
                .buttonStyle(.plain)
            }

            // Footnote content
            Text(footnote.content)
                .font(.system(size: 13))
                .foregroundColor(theme.text)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? theme.foam.opacity(0.15) : theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHighlighted ? theme.foam : theme.overlay, lineWidth: isHighlighted ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.3), value: isHighlighted)
    }
}

// MARK: - Reading Speed Prompt

struct ReadingSpeedPrompt: View {
    let chapterWPM: Double?
    let averageWPM: Double
    let confidence: Double
    let onApplyAdjustment: (ReadingSpeedTracker.AdjustmentType) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var showAdjustments = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.iris)

                Text("Chapter Complete")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.muted)
                }
                .buttonStyle(.plain)
            }

            // WPM display
            if let wpm = chapterWPM, wpm > 0 {
                VStack(spacing: 4) {
                    Text("\(Int(wpm))")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(theme.iris)

                    Text("words per minute")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                }
                .padding(.vertical, 8)
            }

            // Confidence indicator
            if averageWPM > 0 {
                HStack(spacing: 8) {
                    Text("Average: \(Int(averageWPM)) WPM")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.subtle)

                    Text("•")
                        .foregroundColor(theme.muted)

                    Text("\(Int(confidence * 100))% confident")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(confidence >= 0.8 ? theme.foam : theme.gold)
                }
            }

            // Primary actions
            if !showAdjustments {
                VStack(spacing: 10) {
                    // Main action buttons
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showAdjustments = true
                            }
                        } label: {
                            Text("Adjust speed")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.rose)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(theme.rose.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: onDismiss) {
                            Text("Looks right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.foam)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(theme.foam.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Subtle dismissal for browsing
                    Button(action: onDismiss) {
                        Text("I was just browsing")
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Adjustment buttons
                VStack(spacing: 8) {
                    Text("Help calibrate your reading speed:")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)

                    ForEach(ReadingSpeedTracker.AdjustmentType.allCases, id: \.self) { adjustment in
                        Button {
                            onApplyAdjustment(adjustment)
                        } label: {
                            HStack {
                                Text(adjustment.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.text)

                                Spacer()

                                Text(adjustmentDescription(adjustment))
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.muted)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(theme.iris.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.iris.opacity(0.3), lineWidth: 1)
        }
    }

    private func adjustmentDescription(_ type: ReadingSpeedTracker.AdjustmentType) -> String {
        switch type {
        case .readingSlowly: return "-15%"
        case .skippedInsights: return "+15%"
        case .readInsights: return "-10%"
        case .wasDistracted: return "-30%"
        }
    }
}

// MARK: - Image Card

struct ImageCard: View {
    let image: GeneratedImage
    let onScrollTo: () -> Void
    let onExpand: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image preview - use .fit to show full image, never clip content
            AsyncImage(url: image.imageURL) { phase in
                switch phase {
                case .success(let loadedImage):
                    loadedImage
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 200)
                        .frame(maxWidth: .infinity)
                        .background(theme.overlay.opacity(0.3))
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 24))
                        Text("Failed to load")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.muted)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(theme.overlay)
                case .empty:
                    ProgressView()
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .background(theme.overlay)
                @unknown default:
                    EmptyView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onExpand()
            }
            .onTapGesture(count: 1) {
                onScrollTo()
            }
            .contextMenu {
                Button {
                    onExpand()
                } label: {
                    Label("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button {
                    onScrollTo()
                } label: {
                    Label("Go to Source", systemImage: "arrow.right.circle")
                }
            }

            // Caption/prompt
            VStack(alignment: .leading, spacing: 6) {
                Text(image.prompt)
                    .font(.system(size: 12))
                    .foregroundColor(theme.text)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Button(action: onScrollTo) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                            Text("Go to source")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.iris)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }
}
