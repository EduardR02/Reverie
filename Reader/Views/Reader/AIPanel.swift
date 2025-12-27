import SwiftUI

struct AIPanel: View {
    let chapter: Chapter?
    let annotations: [Annotation]
    let quizzes: [Quiz]
    let footnotes: [Footnote]
    let images: [GeneratedImage]
    let currentAnnotationId: Int64?
    let isProcessing: Bool
    let isGeneratingMore: Bool
    let onScrollTo: (Int64) -> Void  // Scroll to annotation by ID
    let onScrollToQuote: (String) -> Void  // Scroll to quote text (for quizzes)
    let onScrollToFootnote: (String) -> Void  // Scroll to footnote reference by refId
    let onGenerateMoreInsights: () -> Void
    let onGenerateMoreQuestions: () -> Void
    @Binding var externalTabSelection: Tab?  // External control for tab switching

    // Reading speed tracking
    let scrollPercent: Double
    let chapterWPM: Double?  // WPM for current chapter session
    let onApplyAdjustment: (ReadingSpeedTracker.AdjustmentType) -> Void

    @State private var highlightedFootnoteId: String?
    @State private var showedSpeedPromptForChapter: Int64?  // Track which chapter we showed prompt for

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var selectedTab: Tab = .insights
    @State private var chatInput = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var isLoading = false
    @State private var expandedAnnotationId: Int64?

    enum Tab: String, CaseIterable {
        case insights = "Insights"
        case quiz = "Quiz"
        case footnotes = "Notes"
        case chat = "Chat"

        var icon: String {
            switch self {
            case .insights: return "lightbulb"
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

            // Content
            switch selectedTab {
            case .insights:
                insightsTab
            case .quiz:
                quizTab
            case .footnotes:
                footnotesTab
            case .chat:
                chatTab
            }
        }
        .background(theme.surface)
        .onChange(of: currentAnnotationId) { _, newId in
            // Auto-expand the current annotation when scrolling through text
            if let newId = newId, selectedTab == .insights {
                withAnimation(.easeOut(duration: 0.2)) {
                    expandedAnnotationId = newId
                }
            }
        }
        .onChange(of: externalTabSelection) { _, newTab in
            // External tab control (e.g., auto-switch to quiz at chapter end)
            if let tab = newTab {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedTab = tab
                }
                // Reset external selection after applying
                DispatchQueue.main.async {
                    externalTabSelection = nil
                }
            }
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
                    .foregroundColor(selectedTab == tab ? theme.rose : theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .background(
                        selectedTab == tab ? theme.overlay : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 48)
        .background(theme.surface)
    }

    // MARK: - Insights Tab

    private var insightsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Processing indicator
                    if isProcessing {
                        processingBanner(text: "Generating insights...")
                    }

                    if annotations.isEmpty && !isProcessing {
                        emptyState(
                            icon: "lightbulb",
                            title: "No insights yet",
                            subtitle: "Insights will appear as you read"
                        )
                    } else if !annotations.isEmpty {
                        ForEach(annotations) { annotation in
                            AnnotationCard(
                                annotation: annotation,
                                isExpanded: expandedAnnotationId == annotation.id,
                                isCurrent: currentAnnotationId == annotation.id,
                                onToggle: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        if expandedAnnotationId == annotation.id {
                                            expandedAnnotationId = nil
                                        } else {
                                            expandedAnnotationId = annotation.id
                                            // Auto-scroll to passage when expanding
                                            onScrollTo(annotation.id!)
                                        }
                                    }
                                },
                                onScrollTo: {
                                    onScrollTo(annotation.id!)
                                }
                            )
                            .id(annotation.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: currentAnnotationId) { oldValue, newValue in
                // Auto-scroll to current insight and expand it
                if let id = newValue {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                        expandedAnnotationId = id
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

                // Reading speed prompt (shows near chapter end)
                if scrollPercent > 0.9 && showedSpeedPromptForChapter != chapter?.id {
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
            }
            .padding(16)
        }
    }

    // MARK: - Quiz Tab

    private var quizTab: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
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
                                onScrollToQuote(quiz.sourceQuote)
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
        }
    }

    // MARK: - Chat Tab

    private var chatTab: some View {
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
                }
                .padding(16)
            }

            // Input
            chatInputBar
        }
    }

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this chapter...", text: $chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
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
        .padding(12)
        .background(theme.overlay)
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

    // MARK: - Actions

    private func sendMessage() {
        guard !chatInput.isEmpty, let chapter = chapter else { return }

        let userMessage = ChatMessage(role: .user, content: chatInput)
        chatMessages.append(userMessage)
        let query = chatInput
        chatInput = ""

        // Add empty assistant message for streaming
        var assistantMessage = ChatMessage(role: .assistant, content: "", thinking: nil)
        chatMessages.append(assistantMessage)
        let messageIndex = chatMessages.count - 1

        isLoading = true

        Task {
            do {
                var contentBuffer = ""
                var thinkingBuffer = ""

                let stream = appState.llmService.chatStreaming(
                    message: query,
                    chapterContent: chapter.contentHTML,
                    rollingSummary: chapter.rollingSummary,
                    settings: appState.settings
                )

                for try await chunk in stream {
                    if chunk.isThinking {
                        thinkingBuffer += chunk.text
                        chatMessages[messageIndex].thinking = thinkingBuffer
                    } else {
                        contentBuffer += chunk.text
                        chatMessages[messageIndex].content = contentBuffer
                    }
                }

                // Finalize message
                if contentBuffer.isEmpty && !thinkingBuffer.isEmpty {
                    chatMessages[messageIndex].content = "(Reasoning only - no response)"
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                chatMessages[messageIndex].content = message
            }

            isLoading = false
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

                    // Source quote
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(theme.rose)
                            .frame(width: 2)

                        Text(annotation.sourceQuote)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.subtle)
                            .italic()
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }

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
                        Text("I was just skimming")
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
