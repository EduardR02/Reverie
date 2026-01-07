import AppKit
import SwiftUI

struct AIPanel: View {
    let chapter: Chapter?
    @Binding var annotations: [Annotation]
    @Binding var quizzes: [Quiz]
    let footnotes: [Footnote]
    let images: [GeneratedImage]
    let currentAnnotationId: Int64?
    let currentImageId: Int64?
    let currentFootnoteRefId: String?
    let isProcessingInsights: Bool
    let isProcessingImages: Bool
    let liveInsightCount: Int
    let liveQuizCount: Int
    let liveThinking: String
    let isClassifying: Bool
    let classificationError: String?
    let analysisError: String?
    let onScrollTo: (Int64) -> Void  // Scroll to annotation by ID
    let onScrollToQuote: (String) -> Void  // Scroll to quote text (for quizzes)
    let onScrollToFootnote: (String) -> Void  // Scroll to footnote reference by refId
    let onScrollToBlockId: (_ blockId: Int, _ imageId: Int64?) -> Void  // Scroll to block by ID (for images/quizzes)
    let onGenerateMoreInsights: () -> Void
    let onGenerateMoreQuestions: () -> Void
    let onForceProcess: () -> Void  // Force process garbage chapter
    let onRetryClassification: () -> Void  // Retry failed classification
    let onCancelAnalysis: () -> Void
    let onCancelImages: () -> Void
    let autoScrollHighlightEnabled: Bool
    let isProgrammaticScroll: Bool
    @Binding var externalTabSelection: Tab?  // External control for tab switching
    @Binding var selectedTab: Tab
    @Binding var pendingChatPrompt: String?
    @Binding var isChatInputFocused: Bool

    // Reading speed tracking
    let scrollPercent: Double
    let chapterWPM: Double?  // WPM for current chapter session
    let onApplyAdjustment: (ReadingSpeedTracker.AdjustmentType) -> Void

    @State private var highlightedFootnoteId: String?
    @State private var showedSpeedPromptForChapter: Int64?  // Track which chapter we showed prompt for
    @Binding var expandedImage: GeneratedImage?  // Image shown in fullscreen overlay (shown at ReaderView level)

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var chatInput = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var chatSessionToken = UUID()
    @State private var expandedAnnotationId: Int64?
    @State private var chatScrollViewHeight: CGFloat = 0
    @State private var chatContentMetrics = ChatContentMetrics(height: 0, minY: 0)
    @State private var chatAutoScrollEnabled = true
    @State private var chatScrollTick = 0
    @State private var scrollRequestCount = 0
    @State private var externalScrollRequest: (id: AnyHashable, tab: Tab)?
    @State private var isThinkingExpanded = false
    @FocusState private var isChatFocused: Bool

    private let chatScrollSpace = "chat-scroll"
    private let chatBottomId = "chat-bottom"

    private var sortedImages: [GeneratedImage] {
        images.sorted { $0.sourceBlockId < $1.sourceBlockId }
    }

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
            handleAnnotationChange(newId)
        }
        .onChange(of: currentFootnoteRefId) { _, newId in
            highlightedFootnoteId = newId
        }
        .onChange(of: externalTabSelection) { _, newTab in
            handleExternalTabChange(newTab)
        }
        .onChange(of: pendingChatPrompt) { _, newPrompt in
            handlePendingChatPrompt(newPrompt)
        }
        .onChange(of: selectedTab) { _, newTab in
            handleTabChange(newTab)
        }
        .onChange(of: isChatFocused) { _, newValue in
            if isChatInputFocused != newValue {
                isChatInputFocused = newValue
            }
        }
        .onChange(of: appState.chatContextReference) { _, newValue in
            handleChatContextChange(newValue)
        }
    }

    private func handleAnnotationChange(_ newId: Int64?) {
        // Auto-expand the current annotation when scrolling through text
        if let newId = newId, selectedTab == .insights {
            withAnimation(.easeOut(duration: 0.2)) {
                expandedAnnotationId = newId
            }
            
            // Record as seen in Journey
            if let annotation = annotations.first(where: { $0.id == newId }) {
                appState.recordAnnotationSeen(annotation)
            }
        }
    }

    private func handleExternalTabChange(_ newTab: Tab?) {
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

    private func handlePendingChatPrompt(_ newPrompt: String?) {
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

    private func handleTabChange(_ newTab: Tab) {
        if newTab != .chat {
            if isChatFocused {
                isChatFocused = false
            }
        }
        if newTab == .insights, let id = currentAnnotationId {
            expandedAnnotationId = id
        }
    }

    private func handleChatContextChange(_ reference: AppState.ChatReference?) {
        guard reference != nil else { return }
        chatScrollTick += 1
        isChatFocused = true
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
                    selectedTab = tab
                } label: {
                    ViewThatFits(in: .horizontal) {
                        tabLabelRow(for: tab)
                            .fixedSize(horizontal: true, vertical: false)
                        tabLabelStacked(for: tab)
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

    private func tabLabelRow(for tab: Tab) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .medium))

            tabLabelText(tab)

            tabBadge(for: tab)
        }
    }

    private func tabLabelStacked(for tab: Tab) -> some View {
        VStack(spacing: 4) {
            tabLabelText(tab)

            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))

                tabBadge(for: tab)
            }
        }
    }

    private func tabLabelText(_ tab: Tab) -> some View {
        Text(tab.rawValue)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private func tabBadge(for tab: Tab) -> some View {
        if tab == .insights && !annotations.isEmpty {
            badge(text: "\(annotations.count)", color: theme.rose, isSelected: selectedTab == tab)
        } else if tab == .images {
            if isProcessingImages {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(selectedTab == tab ? theme.base : theme.iris)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(selectedTab == tab ? theme.iris : theme.iris.opacity(0.2))
                    .clipShape(Capsule())
            } else if !images.isEmpty {
                badge(text: "\(images.count)", color: theme.iris, isSelected: selectedTab == tab)
            }
        } else if tab == .quiz && !quizzes.isEmpty {
            badge(text: "\(quizzes.count)", color: theme.rose, isSelected: selectedTab == tab)
        } else if tab == .footnotes && !footnotes.isEmpty {
            badge(text: "\(footnotes.count)", color: theme.foam, isSelected: selectedTab == tab)
        } else {
            EmptyView()
        }
    }

    private func badge(text: String, color: Color, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(isSelected ? theme.base : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isSelected ? color : color.opacity(0.2))
            .clipShape(Capsule())
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

                    // Analysis error banner
                    if let analysisError {
                        analysisErrorBanner(error: analysisError)
                    }

                    // Garbage chapter banner (show when chapter is garbage and not yet processed)
                    if let chapter = chapter, chapter.shouldSkipAutoProcessing && !chapter.processed {
                        garbageChapterBanner
                    }

                    // Processing indicator
                    if isProcessingInsights {
                        processingSkeleton(text: "Analyzing chapter...")
                    }

                    if annotations.isEmpty && !isProcessingInsights && !isClassifying && (chapter?.shouldSkipAutoProcessing != true) {
                        emptyState(
                            icon: "lightbulb",
                            title: "No insights yet",
                            subtitle: "Insights will appear as you read"
                        )
                    } else if !annotations.isEmpty {
                        annotationList
                    }

                    // More insights button
                    if !annotations.isEmpty && !isProcessingInsights {
                        Button {
                            onGenerateMoreInsights()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                Text("More insights")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Chapter complete prompt (shows at 90% scroll)
                    if shouldShowSpeedPrompt {
                        chapterCompletePrompt
                    }
                }
                .padding(16)
            }
            .onChange(of: scrollRequestCount) { _, _ in
                guard let req = externalScrollRequest, req.tab == .insights else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(req.id, anchor: UnitPoint(x: 0.5, y: 0.2))
                }
            }
            .onChange(of: currentAnnotationId) { oldValue, newValue in
                // Auto-scroll to current insight and expand it
                // Use .top anchor so insights near top of list can still be scrolled to
                if let id = newValue {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.2))
                        expandedAnnotationId = id
                    }
                }
            }
            .onAppear {
                guard let id = currentAnnotationId else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.2))
                        expandedAnnotationId = id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var annotationList: some View {
        let indexById: [Int64: Int] = Dictionary(uniqueKeysWithValues: annotations.indices.compactMap { index in
            guard let id = annotations[index].id else { return nil }
            return (id, index)
        })
        let orderedIds = annotations
            .sorted { $0.sourceBlockId < $1.sourceBlockId }
            .compactMap { $0.id }

        ForEach(orderedIds, id: \.self) { annotationId in
            if let index = indexById[annotationId] {
                AnnotationCard(
                    annotation: $annotations[index],
                    isExpanded: expandedAnnotationId == annotationId,
                    isCurrent: currentAnnotationId == annotationId,
                    isAutoScroll: !isProgrammaticScroll,
                    onToggle: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if expandedAnnotationId == annotationId {
                                expandedAnnotationId = nil
                            } else {
                                expandedAnnotationId = annotationId
                                // Auto-scroll to passage when expanding
                                onScrollTo(annotationId)
                                externalScrollRequest = (annotationId, .insights)
                                scrollRequestCount += 1
                            }
                        }
                    },
                    onScrollTo: {
                        onScrollTo(annotationId)
                        externalScrollRequest = (annotationId, .insights)
                        scrollRequestCount += 1
                    },
                    selectedTab: $selectedTab,
                    onAsk: { reference in
                        resetChatSession(context: reference)
                        selectedTab = .chat
                    },
                    onUpdateAnnotation: { updated in
                        appState.updateAnnotation(updated)
                    }
                )
                .id(annotationId)
            }
        }
    }

    // MARK: - Images Tab

    private var imagesTab: some View {
        let autoScrollAnchor = UnitPoint(x: 0.5, y: 0.2)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if isProcessingImages {
                        processingSkeleton(text: "Generating illustrations...", isImages: true)
                    }

                    if images.isEmpty && !isProcessingImages {
                        emptyState(
                            icon: "photo",
                            title: "No images yet",
                            subtitle: "Images will appear as they're generated"
                        )
                    } else {
                        ForEach(sortedImages) { image in
                            ImageCard(
                                image: image,
                                isHighlighted: image.id == currentImageId,
                                isAutoScroll: !isProgrammaticScroll,
                                onScrollTo: {
                                    if let id = image.id {
                                        onScrollToBlockId(image.sourceBlockId, id)
                                        externalScrollRequest = (id, .images)
                                        scrollRequestCount += 1
                                    }
                                },
                                onExpand: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        expandedImage = image
                                    }
                                }
                            )
                            .id(image.id ?? Int64(image.sourceBlockId))
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: scrollRequestCount) { _, _ in
                guard let req = externalScrollRequest, req.tab == .images else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(req.id, anchor: autoScrollAnchor)
                }
            }
            .onChange(of: currentImageId) { _, newId in
                guard let id = newId else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: autoScrollAnchor)
                }
            }
            .onAppear {
                if let id = currentImageId {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: autoScrollAnchor)
                        }
                    }
                }
            }
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
                if isProcessingInsights {
                    processingSkeleton(text: "Generating questions...")
                }

                if let analysisError {
                    analysisErrorBanner(error: analysisError)
                }

                if quizzes.isEmpty && !isProcessingInsights {
                    emptyState(
                        icon: "checkmark.circle",
                        title: "No quiz yet",
                        subtitle: "Quiz questions will appear at chapter end"
                    )
                } else if !quizzes.isEmpty {
                    quizList

                    // More questions button
                    if !isProcessingInsights {
                        Button {
                            onGenerateMoreQuestions()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                Text("More questions")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var quizList: some View {
        let indexById: [Int64: Int] = Dictionary(uniqueKeysWithValues: quizzes.indices.compactMap { index in
            guard let id = quizzes[index].id else { return nil }
            return (id, index)
        })
        let orderedIds = quizzes
            .sorted { $0.sourceBlockId < $1.sourceBlockId }
            .compactMap { $0.id }

        ForEach(orderedIds, id: \.self) { quizId in
            if let index = indexById[quizId] {
                QuizCard(
                    quiz: $quizzes[index],
                    onScrollTo: {
                        onScrollToBlockId(quizzes[index].sourceBlockId, nil)
                    }
                )
                .id(quizId)
            }
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
                                isAutoScroll: !isProgrammaticScroll,
                                onScrollTo: {
                                    onScrollToFootnote(footnote.refId)
                                    externalScrollRequest = (footnote.refId, .footnotes)
                                    scrollRequestCount += 1
                                }
                            )
                            .id(footnote.refId)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: scrollRequestCount) { _, _ in
                guard let req = externalScrollRequest, req.tab == .footnotes else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(req.id, anchor: .center)
                }
            }
            .onChange(of: highlightedFootnoteId) { _, newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
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
                        let contextReference = appState.chatContextReference
                        if chatMessages.isEmpty && contextReference == nil {
                            emptyState(
                                icon: "bubble.left.and.bubble.right",
                                title: "Ask anything",
                                subtitle: "I have the current chapter in context"
                            )
                        } else {
                            if let reference = contextReference {
                                ChatBubble(message: ChatMessage(role: .reference, content: "", reference: reference))
                            }
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
                .focused($isChatFocused)
                .onSubmit {
                    sendMessage()
                }

            Button {
                resetChatSession(context: nil)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.muted)
                    .frame(width: 28, height: 28)
                    .background(theme.overlay.opacity(0.6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hasChatContent ? 1 : 0)
            .allowsHitTesting(hasChatContent)
            .help("Reset chat")

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
            liveWPM: appState.readingSpeedTracker.currentSession?.wpm,
            liveSeconds: appState.readingSpeedTracker.currentSession?.timeSpentSeconds,
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
        CompactReadingSpeedPrompt(
            chapterWPM: chapterWPM,
            liveWPM: appState.readingSpeedTracker.currentSession?.wpm,
            liveSeconds: appState.readingSpeedTracker.currentSession?.timeSpentSeconds,
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

    // MARK: - Processing State

    private func processingSkeleton(text: String, isImages: Bool = false) -> some View {
        AnalysisWorkbench(
            title: text,
            isImages: isImages,
            liveInsightCount: liveInsightCount,
            liveQuizCount: liveQuizCount,
            liveThinking: liveThinking,
            isThinkingExpanded: $isThinkingExpanded,
            onCancel: {
                if isImages { onCancelImages() }
                else { onCancelAnalysis() }
            }
        )
    }

    private struct AnalysisWorkbench: View {
        let title: String
        let isImages: Bool
        let liveInsightCount: Int
        let liveQuizCount: Int
        let liveThinking: String
        @Binding var isThinkingExpanded: Bool
        let onCancel: () -> Void

        @Environment(\.theme) private var theme
        @State private var pulsePhase: CGFloat = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // Top Progress Line (The "Zen" Indicator)
                FlowingProgressLine()
                    .frame(height: 2)

                // Main Header
                HStack(spacing: 12) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.2)
                        .foregroundColor(theme.muted)
                    
                    Spacer()
                    
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.muted.opacity(0.5))
                            .padding(6)
                            .background(theme.overlay.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel analysis")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Live Metrics (Bloom Animation)
                if !isImages && (liveInsightCount > 0 || liveQuizCount > 0) {
                    HStack(spacing: 20) {
                        if liveInsightCount > 0 {
                            refinedMetric(icon: "lightbulb.fill", count: liveInsightCount, color: theme.rose)
                        }
                        if liveQuizCount > 0 {
                            refinedMetric(icon: "checkmark.circle.fill", count: liveQuizCount, color: theme.foam)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }

                // Thinking Stream (Masked & Expandable)
                if !liveThinking.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider().background(theme.overlay.opacity(0.5))
                        
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                isThinkingExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 12))
                                    .symbolEffect(.pulse, options: .repeating)
                                
                                if isThinkingExpanded {
                                    Text("Reasoning")
                                        .font(.system(size: 11, weight: .bold))
                                } else {
                                    Text(lastThinkingSentence)
                                        .font(.system(size: 11, weight: .medium))
                                        .italic()
                                        .lineLimit(1)
                                        .mask(
                                            LinearGradient(
                                                gradient: Gradient(stops: [
                                                    .init(color: .black, location: 0.8),
                                                    .init(color: .clear, location: 1.0)
                                                ]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .rotationEffect(.degrees(isThinkingExpanded ? 90 : 0))
                            }
                            .foregroundColor(theme.rose.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.001)) // Reliable hit-testing
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isThinkingExpanded {
                            Text(liveThinking)
                                .font(.system(size: 11))
                                .foregroundColor(theme.text.opacity(0.8))
                                .lineSpacing(4)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(theme.overlay.opacity(0.2))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface)
                    .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.overlay, lineWidth: 1)
            }
            .padding(.bottom, 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: liveInsightCount)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: liveQuizCount)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: liveThinking)
        }

        private var lastThinkingSentence: String {
            let sentences = liveThinking.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return sentences.last ?? "Processing..."
        }

        private func refinedMetric(icon: String, count: Int, color: Color) -> some View {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.2), lineWidth: 1)
            }
        }
    }

    private struct FlowingProgressLine: View {
        @Environment(\.theme) private var theme
        @State private var phase: CGFloat = 0
        
        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.overlay.opacity(0.5))
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [theme.rose.opacity(0), theme.rose, theme.foam, theme.foam.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: -geo.size.width * 0.4 + (geo.size.width * 1.4 * phase))
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }

    private func analysisErrorBanner(error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.love)

                Text("Analysis Failed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            Text(error)
                .font(.system(size: 12))
                .foregroundColor(theme.muted)
                .lineSpacing(3)

            Button {
                if chapter != nil {
                    // Triggers processChapter in ReaderView via onForceProcess
                    onForceProcess()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry Analysis")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.love)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(theme.love.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.love.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

            Text("Generating chapter dividers...")
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

    private var hasChatContent: Bool {
        !chatMessages.isEmpty || appState.chatContextReference != nil
    }

    @MainActor
    private func resetChatSession(context: AppState.ChatReference?) {
        chatSessionToken = UUID()
        isLoading = false
        chatInput = ""
        chatMessages.removeAll()
        chatAutoScrollEnabled = true
        appState.chatContextReference = context
        chatScrollTick += 1
    }

    @MainActor
    private func sendMessage(_ text: String? = nil) {
        let rawInput = text ?? chatInput
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let chapter = chapter else { return }
        let sessionToken = chatSessionToken

        let referenceContext = appState.chatContextReference

        let userMessage = ChatMessage(role: .user, content: trimmed)
        chatMessages.append(userMessage)
        chatScrollTick += 1
        appState.readingStats.recordFollowup()
        let query = trimmed
        if text == nil {
            chatInput = ""
        }

        let assistantMessage = ChatMessage(role: .assistant, content: "", thinking: nil)
        chatMessages.append(assistantMessage)
        chatScrollTick += 1
        let messageIndex = chatMessages.count - 1

        isLoading = true

        Task {
            do {
                var contentBuffer = ""
                var thinkingBuffer = ""

                let (contentWithBlocks, _) = chapter.getContentText()

                // If we have context, prepend it to the message or use a specialized prompt
                let finalQuery: String
                if let ref = referenceContext {
                    finalQuery = "Regarding the insight \"\(ref.title)\" (\(ref.content)): \(query)"
                } else {
                    finalQuery = query
                }

                let stream = appState.llmService.chatStreaming(
                    message: finalQuery,
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: chapter.rollingSummary,
                    settings: appState.settings
                )

                for try await chunk in stream {
                    if sessionToken != chatSessionToken { return }
                    if chunk.isThinking {
                        thinkingBuffer += chunk.text
                        await MainActor.run {
                            guard sessionToken == chatSessionToken,
                                  chatMessages.indices.contains(messageIndex) else { return }
                            chatMessages[messageIndex].thinking = thinkingBuffer
                            chatScrollTick += 1
                        }
                    } else {
                        contentBuffer += chunk.text
                        await MainActor.run {
                            guard sessionToken == chatSessionToken,
                                  chatMessages.indices.contains(messageIndex) else { return }
                            chatMessages[messageIndex].content = contentBuffer
                            chatScrollTick += 1
                        }
                    }
                }

                // Finalize message
                if sessionToken != chatSessionToken { return }
                if contentBuffer.isEmpty && !thinkingBuffer.isEmpty {
                    await MainActor.run {
                        guard sessionToken == chatSessionToken,
                              chatMessages.indices.contains(messageIndex) else { return }
                        chatMessages[messageIndex].content = "(Reasoning only - no response)"
                        chatScrollTick += 1
                    }
                } else if contentBuffer.isEmpty && thinkingBuffer.isEmpty {
                    await MainActor.run {
                        guard sessionToken == chatSessionToken,
                              chatMessages.indices.contains(messageIndex) else { return }
                        chatMessages[messageIndex].content = "No response returned. Try again."
                        chatScrollTick += 1
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    guard sessionToken == chatSessionToken,
                          chatMessages.indices.contains(messageIndex) else { return }
                    chatMessages[messageIndex].content = message
                    chatScrollTick += 1
                }
            }

            await MainActor.run {
                if sessionToken == chatSessionToken {
                    isLoading = false
                }
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
    var reference: AppState.ChatReference?

    enum Role {
        case user
        case assistant
        case reference
    }

    init(role: Role, content: String, thinking: String? = nil, reference: AppState.ChatReference? = nil) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.reference = reference
    }
}

private struct ChatContentMetrics: Equatable {
    let height: CGFloat
    let minY: CGFloat
}

private struct ChatContentMetricsKey: PreferenceKey {
    static let defaultValue = ChatContentMetrics(height: 0, minY: 0)

    static func reduce(value: inout ChatContentMetrics, nextValue: () -> ChatContentMetrics) {
        value = nextValue()
    }
}

private struct ChatScrollViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

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
                if message.role == .reference, let ref = message.reference {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if let type = ref.type {
                                Image(systemName: type.icon)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.rose)
                            }
                            Text(ref.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.rose)
                        }
                        
                        SelectableText(
                            ref.content,
                            fontSize: 12,
                            color: theme.text
                        )
                    }
                    .padding(10)
                    .background(theme.rose.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.rose.opacity(0.2), lineWidth: 1)
                    }
                } else {
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
                                SelectableText(
                                    thinking,
                                    fontSize: 12,
                                    color: theme.subtle,
                                    isItalic: true
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.base.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    // Main content
                    SelectableText(
                        message.content,
                        fontSize: 14,
                        color: message.role == .user ? theme.base : theme.text
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? theme.rose : theme.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if message.role == .assistant || message.role == .reference { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Annotation Card

struct AnnotationCard: View {
    @Binding var annotation: Annotation
    let isExpanded: Bool
    let isCurrent: Bool
    let isAutoScroll: Bool
    let onToggle: () -> Void
    let onScrollTo: () -> Void
    @Binding var selectedTab: AIPanel.Tab
    let onAsk: (AppState.ChatReference) -> Void
    let onUpdateAnnotation: (Annotation) -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @State private var isSearching = false

    private var showHighlight: Bool {
        if !isCurrent { return false }
        if !isAutoScroll { return true }
        return appState.settings.autoScrollHighlightEnabled
    }

    private var showBorder: Bool {
        showHighlight && appState.settings.activeContentBorderEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button {
                onToggle()
                if !isExpanded {
                    appState.recordAnnotationSeen(annotation)
                }
            } label: {
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

                    SelectableText(
                        annotation.content,
                        fontSize: 13,
                        color: theme.text,
                        lineSpacing: 4
                    )

                    HStack(spacing: 8) {
                        // Jump to source
                        Button(action: onScrollTo) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle")
                                Text("Passage")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(theme.rose.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        // Web Search
                        searchControl

                        // Ask about this
                        Button {
                            let reference = AppState.ChatReference(
                                title: annotation.title,
                                content: annotation.content,
                                type: annotation.type
                            )
                            onAsk(reference)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrowshape.turn.up.right")
                                Text("Ask")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.foam)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(theme.foam.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(showHighlight ? theme.overlay : theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(showBorder ? theme.rose : theme.overlay, lineWidth: showBorder ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: showHighlight)
    }

    private var cachedSearchQuery: String? {
        guard let query = annotation.refinedSearchQuery else { return nil }
        let cleaned = SearchQueryBuilder.validateQuery(query)
        return cleaned.isEmpty ? nil : cleaned
    }

    private var searchControl: some View {
        let hasCachedQuery = cachedSearchQuery != nil
        let labelText = isSearching ? "Forming" : "Search"
        let iconName = hasCachedQuery ? "magnifyingglass.circle.fill" : "magnifyingglass.circle"

        return HStack(spacing: 0) {
            Button {
                performSearch(regenerate: false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 12))
                        .frame(width: 12, height: 12)
                    Text(labelText)
                    if isSearching {
                        AnimatedEllipsis()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.iris)
                .padding(.vertical, 6)
                .padding(.leading, 8)
                .padding(.trailing, hasCachedQuery ? 4 : 8)
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .help(hasCachedQuery ? "Cached search query" : "Generate search query")

            if hasCachedQuery {
                Button {
                    performSearch(regenerate: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(theme.iris)
                        .frame(width: 16, height: 16)
                        .background(theme.iris.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSearching)
                .padding(.trailing, 8)
                .help("Regenerate search query")
            }
        }
        .frame(height: 26)
        .background(theme.iris.opacity(hasCachedQuery ? 0.18 : 0.1))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.2), value: isSearching)
    }

    private struct AnimatedEllipsis: View {
        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.4)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
                HStack(spacing: 0) {
                    Text(".").opacity(phase >= 1 ? 1 : 0.2)
                    Text(".").opacity(phase >= 2 ? 1 : 0.2)
                    Text(".").opacity(phase >= 3 ? 1 : 0.2)
                }
            }
        }
    }

    private func performSearch(regenerate: Bool) {
        // 1. If we have a cached refined query, use it immediately
        if !regenerate, let refined = cachedSearchQuery {
            if let url = SearchQueryBuilder.searchURL(for: refined) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        let bookTitle = appState.currentBook?.title ?? "Unknown"
        let author = appState.currentBook?.author ?? "Unknown"
        
        // 2. Otherwise, we need to distill it. Show loading.
        Task { @MainActor in
            isSearching = true
            defer { isSearching = false }
            
            do {
                let refinedRaw = try await appState.llmService.distillSearchQuery(
                    insightTitle: annotation.title,
                    insightContent: annotation.content,
                    bookTitle: bookTitle,
                    author: author,
                    settings: appState.settings
                )
                
                let refined = SearchQueryBuilder.validateQuery(refinedRaw)
                guard !refined.isEmpty else { throw SearchError.emptyResult }
                
                // Cache it in parent/binding (single source of truth)
                var updated = annotation
                updated.refinedSearchQuery = refined
                annotation = updated
                
                // Persist to DB
                onUpdateAnnotation(updated)
                
                if let url = SearchQueryBuilder.searchURL(for: refined) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                // Fallback to deterministic query if LLM fails or returns junk
                let detQuery = SearchQueryBuilder.deterministicQuery(
                    insightTitle: annotation.title,
                    insightContent: annotation.content,
                    bookTitle: bookTitle,
                    author: author
                )
                if let url = SearchQueryBuilder.searchURL(for: detQuery) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    enum SearchError: Error {
        case emptyResult
    }

}

// MARK: - Quiz Card

struct QuizCard: View {
    @Binding var quiz: Quiz
    let onScrollTo: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @State private var showAnswer = false
    
    private var userResponse: Bool? {
        guard quiz.userAnswered else { return nil }
        return quiz.userCorrect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question Header with Quality Feedback
            HStack(alignment: .top) {
                SelectableText(
                    quiz.question,
                    fontSize: 14,
                    fontWeight: .medium,
                    color: theme.text
                )
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        let nextFeedback: Quiz.QualityFeedback? = quiz.qualityFeedback == .good ? nil : .good
                        withAnimation(.spring(duration: 0.2)) {
                            quiz.qualityFeedback = nextFeedback
                        }
                        appState.recordQuizQuality(quiz: quiz, feedback: nextFeedback)
                    } label: {
                        Image(systemName: quiz.qualityFeedback == .good ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 11))
                            .foregroundColor(quiz.qualityFeedback == .good ? theme.foam : theme.muted)
                            .frame(width: 24, height: 24)
                            .background(quiz.qualityFeedback == .good ? theme.foam.opacity(0.15) : Color.clear)
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        let nextFeedback: Quiz.QualityFeedback? = quiz.qualityFeedback == .garbage ? nil : .garbage
                        withAnimation(.spring(duration: 0.2)) {
                            quiz.qualityFeedback = nextFeedback
                        }
                        appState.recordQuizQuality(quiz: quiz, feedback: nextFeedback)
                    } label: {
                        Image(systemName: quiz.qualityFeedback == .garbage ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 11))
                            .foregroundColor(quiz.qualityFeedback == .garbage ? theme.love : theme.muted)
                            .frame(width: 24, height: 24)
                            .background(quiz.qualityFeedback == .garbage ? theme.love.opacity(0.15) : Color.clear)
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if showAnswer {
                // Answer
                VStack(alignment: .leading, spacing: 8) {
                    SelectableText(
                        quiz.answer,
                        fontSize: 13,
                        color: theme.text
                    )
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

            // Correctness feedback buttons (after answer shown)
            if showAnswer && userResponse == nil {
                HStack(spacing: 12) {
                    Text("Did you know this?")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)

                    Spacer()

                    Button {
                        quiz.userAnswered = true
                        quiz.userCorrect = true
                        appState.recordQuizAnswer(quiz: quiz, correct: true)
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundColor(theme.foam)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        quiz.userAnswered = true
                        quiz.userCorrect = false
                        appState.recordQuizAnswer(quiz: quiz, correct: false)
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
    let isAutoScroll: Bool
    let onScrollTo: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    private var showHighlight: Bool {
        if !isHighlighted { return false }
        if !isAutoScroll { return true }
        return appState.settings.autoScrollHighlightEnabled
    }

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
            SelectableText(
                footnote.content,
                fontSize: 13,
                color: theme.text,
                lineSpacing: 4
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(showHighlight ? theme.foam.opacity(0.15) : theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(showHighlight ? theme.foam : theme.overlay, lineWidth: showHighlight ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.3), value: showHighlight)
    }
}

// MARK: - Reading Speed Prompt

struct ReadingSpeedPrompt: View {
    let chapterWPM: Double?
    let liveWPM: Double?
    let liveSeconds: Double?
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
            if let wpm = resolvedWPM {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(wpm) WPM")
                        .font(.system(size: showsLiveEstimate ? 30 : 36, weight: .bold, design: .rounded))
                        .foregroundColor(theme.iris)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if showsLiveEstimate {
                        Text("Live estimate")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.muted)
                    }
                }
                .padding(.vertical, 6)
            } else if isLiveEstimateTooEarly {
                Text("Too early to estimate")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
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

    private var minimumLiveSeconds: Double { 15 }

    private var isLiveEstimateTooEarly: Bool {
        (chapterWPM ?? 0) <= 0 && (liveSeconds ?? 0) > 0 && (liveSeconds ?? 0) < minimumLiveSeconds
    }

    private var resolvedWPM: Int? {
        if let wpm = chapterWPM, wpm > 0 {
            return Int(wpm.rounded())
        }
        if let wpm = liveWPM, wpm > 0, (liveSeconds ?? 0) >= minimumLiveSeconds {
            return Int(wpm.rounded())
        }
        return nil
    }

    private var showsLiveEstimate: Bool {
        (chapterWPM ?? 0) <= 0 && (liveWPM ?? 0) > 0 && (liveSeconds ?? 0) >= minimumLiveSeconds
    }

}

// MARK: - Compact Reading Speed Prompt

struct CompactReadingSpeedPrompt: View {
    let chapterWPM: Double?
    let liveWPM: Double?
    let liveSeconds: Double?
    let averageWPM: Double
    let confidence: Double
    let onApplyAdjustment: (ReadingSpeedTracker.AdjustmentType) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var showAdjustments = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.iris)

                Text("Chapter Complete")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.text)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let wpm = resolvedWPM {
                    Text(wpmLabel(wpm, isLive: showsLiveEstimate))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(theme.iris)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if isLiveEstimateTooEarly {
                    Text("Too early to estimate")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text("Reading session in progress")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer()

                if averageWPM > 0 {
                    HStack(spacing: 6) {
                        Text("Average \(Int(averageWPM)) WPM")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.subtle)

                        Circle()
                            .fill(confidence >= 0.8 ? theme.foam : theme.gold)
                            .frame(width: 5, height: 5)

                        Text("\(Int(confidence * 100))% confident")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(confidence >= 0.8 ? theme.foam : theme.gold)
                    }
                } else {
                    Text("Still calibrating")
                        .font(.system(size: 10))
                        .foregroundColor(theme.muted)
                }
            }

            if !showAdjustments {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showAdjustments = true
                        }
                    } label: {
                        Text("Adjust speed")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.rose)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(theme.rose.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Text("Looks right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.foam)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(theme.foam.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: onDismiss) {
                        Text("I was just browsing")
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calibration")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.muted)

                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(ReadingSpeedTracker.AdjustmentType.allCases, id: \.self) { adjustment in
                            Button {
                                onApplyAdjustment(adjustment)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(adjustment.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(theme.text)

                                    Spacer()

                                    Text(adjustmentDescription(adjustment))
                                        .font(.system(size: 9))
                                        .foregroundColor(theme.muted)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(theme.overlay)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(theme.iris.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(theme.iris.opacity(0.18), lineWidth: 1)
        }
    }

    private var minimumLiveSeconds: Double { 15 }

    private var isLiveEstimateTooEarly: Bool {
        (chapterWPM ?? 0) <= 0 && (liveSeconds ?? 0) > 0 && (liveSeconds ?? 0) < minimumLiveSeconds
    }

    private var resolvedWPM: Int? {
        if let wpm = chapterWPM, wpm > 0 {
            return Int(wpm.rounded())
        }
        if let wpm = liveWPM, wpm > 0, (liveSeconds ?? 0) >= minimumLiveSeconds {
            return Int(wpm.rounded())
        }
        return nil
    }

    private var showsLiveEstimate: Bool {
        (chapterWPM ?? 0) <= 0 && (liveWPM ?? 0) > 0 && (liveSeconds ?? 0) >= minimumLiveSeconds
    }

    private func wpmLabel(_ wpm: Int, isLive: Bool) -> String {
        isLive ? "Live estimate: \(wpm) WPM" : "\(wpm) WPM"
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
    let isHighlighted: Bool
    let isAutoScroll: Bool
    let onScrollTo: () -> Void
    let onExpand: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    private var showHighlight: Bool {
        if !isHighlighted { return false }
        if !isAutoScroll { return true }
        return appState.settings.autoScrollHighlightEnabled
    }

    private var showBorder: Bool {
        showHighlight && appState.settings.activeContentBorderEnabled
    }

    var body: some View {
        Button {
            onScrollTo()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Image preview - full width with natural height per aspect ratio
                AsyncImage(url: image.imageURL) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .aspectRatio(contentMode: .fit)
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

                // Caption/prompt
                VStack(alignment: .leading, spacing: 6) {
                    Text(image.prompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle")
                            Text("Go to source")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.iris)

                        Spacer()

                        Button {
                            onExpand()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11))
                                .foregroundColor(theme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(showHighlight ? theme.iris.opacity(0.08) : theme.base)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(showBorder ? theme.iris.opacity(0.6) : theme.overlay, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onExpand()
        })
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
    }
}
