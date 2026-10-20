import AppKit
import SwiftUI

struct ReaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var session = ReaderSession()

    private func handleReaderKeyDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let modifiers: EventModifiers = event.modifierFlags.contains(.shift) ? [.shift] : []
        switch event.keyCode {
        case 49:
            return session.handleSpaceBar() == .handled
        case 123:
            return session.handleReaderKey(.leftArrow, modifiers: modifiers) == .handled
        case 124:
            return session.handleReaderKey(.rightArrow, modifiers: modifiers) == .handled
        case 125:
            return session.handleReaderKey(.downArrow, modifiers: modifiers) == .handled
        case 126:
            return session.handleReaderKey(.upArrow, modifiers: modifiers) == .handled
        case 116, 121:
            guard session.readingMode == .pages, !session.isRSVPMode else { return false }
            session.turnPage(event.keyCode == 116 ? -1 : 1)
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            ReaderProportionalSplitView(
                splitRatio: appState.splitRatio,
                minimumLeadingWidth: ReaderSplitLayout.readerMinimumWidth,
                minimumTrailingWidth: ReaderSplitLayout.aiMinimumWidth,
                isTrailingVisible: session.isAIPanelVisible,
                onSplitRatioChange: { appState.splitRatio = $0 },
                isReaderFocusAllowed: !session.isChatInputFocused &&
                    !session.showChapterList && session.expandedImage == nil,
                onReaderKeyDown: handleReaderKeyDown
            ) {
                ReaderBookPanel(session: session)
                    .environment(appState)
                    .environment(\.theme, theme)
            } trailing: {
                if session.isAIPanelVisible {
                    ReaderAIPanel(session: session)
                        .environment(appState)
                        .environment(\.theme, theme)
                }
            }
            Color.clear
                .onChange(of: appState.currentChapterIndex) { _, idx in 
                    session.persistCurrentProgress()
                    Task { await session.loadChapter(at: idx) } 
                }
                .onChange(of: session.aiPanelSelectedTab) { old, new in session.handleTabChange(from: old, to: new) }
                .onChange(of: session.expandedImage) { old, new in session.handleExpandedImageChange(from: old, to: new) }
                .onChange(of: session.rsvpEngine.pendingPauseContent) { _, newValue in
                    session.handleRSVPPauseContentChange(newValue)
                }
        }
        .background(theme.base)
        .overlay {
            if let image = session.expandedImage {
                ReaderImageOverlay(image: image, session: session)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task {
            session.setup(with: appState)
            await session.loadChapters()
        }
        .onAppear { session.startReadingTicker() }
        .onChange(of: appState.readingSpeedTracker.manualAutoScrollWPM) { _, newValue in
            session.rsvpEngine.setWPM(newValue)
        }
        .onChange(of: appState.settings.readingMode) { _, _ in session.readingModeDidChange() }
        .onDisappear { session.cleanup() }
    }
}

private struct ReaderBookPanel: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ReaderChapterHeader(session: session)
            ZStack(alignment: .bottomLeading) {
                if let error = session.loadError {
                    ReaderErrorView(error: error) { Task { await session.loadChapters() } }
                } else if session.isLoadingChapters || appState.currentBook?.importStatus == .metadataOnly {
                    ReaderLoadingView(isImporting: appState.currentBook?.importStatus == .metadataOnly)
                } else if let chapter = session.currentChapter {
                    BookContentView(
                        chapter: chapter,
                        annotations: session.annotations,
                        images: session.images,
                        selectedTab: session.aiPanelSelectedTab,
                        onWordClick: { session.handleWordClick(word: $0, context: $1, blockId: $2, action: $3) },
                        onAnnotationClick: { session.handleAnnotationClick($0) },
                        onImageMarkerClick: { session.handleImageMarkerClick($0) },
                        onFootnoteClick: { session.handleFootnoteClick($0) },
                        onChapterNavigationRequest: { session.handleChapterNavigation($0, $1) },
                        onImageMarkerDblClick: { id in
                            session.handleImageMarkerDoubleClick(id)
                        },
                        onScrollPositionChange: { session.handleScrollUpdate(context: $0, chapter: chapter) },
                        onMarkersUpdated: { session.autoScroll.updateMarkers($0) },
                        onBottomTug: { session.handleQuizAutoSwitchOnTug() },
                        scrollToAnnotationId: Bindable(session).scrollToAnnotationId,
                        scrollToPercent: Bindable(session).scrollToPercent,
                        scrollToOffset: Bindable(session).scrollToOffset,
                        scrollToBlockId: Bindable(session).scrollToBlockId,
                        scrollToQuote: Bindable(session).scrollToQuote,
                        pendingMarkerInjections: Bindable(session).pendingMarkerInjections,
                        pendingImageMarkerInjections: Bindable(session).pendingImageMarkerInjections,
                        scrollByAmount: Bindable(session).scrollByAmount,
                        pageTurnRequests: session.pageTurnRequests,
                        onPageTurnsConsumed: { session.consumePageTurns($0) },
                        scrollToLocation: session.scrollToLocation,
                        onLocationNavigationConsumed: { location in
                            if session.scrollToLocation == location { session.scrollToLocation = nil }
                        },
                        onTopTug: { session.turnPage(-1) }
                    )
                    
                    if session.isRSVPMode {
                        RSVPView(
                            word: session.rsvpEngine.currentWord,
                            fontSize: appState.settings.rsvpFontSize,
                            progress: session.rsvpEngine.progress,
                            isPlaying: session.rsvpEngine.isPlaying
                        )
                        .transition(.opacity)
                        .onTapGesture {
                            session.rsvpEngine.toggle()
                        }
                        .zIndex(10) // Ensure it's above BookContentView
                    }

                    if session.showBackButton {
                        ReaderBackAnchorOverlay(session: session)
                    }
                } else {
                    ReaderNoChaptersView()
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.showBackButton)
            ReaderNavigationFooter(session: session)
        }
    }
}

private struct ReaderAIPanel: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState

    var body: some View {
        let processing = session.currentChapter?.id.flatMap { session.analyzer?.processingStates[$0] }
        AIPanel(
            chapter: session.currentChapter,
            annotations: Bindable(session).annotations,
            quizzes: Bindable(session).quizzes,
            footnotes: session.footnotes,
            images: session.images,
            orderedAnnotationItems: session.orderedAnnotationItems,
            orderedQuizItems: session.orderedQuizItems,
            sortedImages: session.sortedImages,
            currentAnnotationId: session.currentAnnotationId,
            currentImageId: session.currentImageId,
            currentFootnoteRefId: session.currentFootnoteRefId,
            isProcessingInsights: processing?.isProcessingInsights ?? false,
            isProcessingImages: processing?.isProcessingImages ?? false,
            liveInsightCount: processing?.liveInsightCount ?? 0,
            liveQuizCount: processing?.liveQuizCount ?? 0,
            liveThinking: processing?.liveThinking ?? "",
            isClassifying: session.analyzer?.isClassifying ?? false,
            classificationError: session.analyzer?.classificationError,
            analysisError: processing?.error,
            onScrollTo: { id in
                session.suppressContextAutoSwitch(); session.currentAnnotationId = id
                session.setBackAnchor(); session.scrollToAnnotationId = id
            },
            onScrollToQuote: { session.scrollToQuote = $0 },
            onScrollToFootnote: { id in
                session.suppressContextAutoSwitch(); session.currentFootnoteRefId = id
                session.setBackAnchor(); session.scrollToQuote = id
            },
            onScrollToBlockId: { bId, iId in
                if let id = iId { session.currentImageId = id }
                session.suppressContextAutoSwitch(); session.setBackAnchor()
                session.scrollToBlockId = (bId, iId, iId != nil ? "image" : nil)
            },
            onRetryImage: { image in
                await session.retryImage(image)
            },
            onRewriteAndRetryImage: { image in
                await session.rewriteAndRetryImage(image)
            },
            onGenerateMoreInsights: { session.generateMoreInsights() },
            onGenerateMoreQuestions: { session.generateMoreQuestions() },
            onForceProcess: { session.forceProcessGarbageChapter() },
            onProcessManually: { session.processCurrentChapter(force: true) },
            onRetryClassification: { session.retryClassification() },
            onCancelAnalysis: { session.cancelAnalysis() },
            onDiscardSession: { appState.readingSpeedTracker.discardSession() },
            autoScrollHighlightEnabled: appState.settings.autoScrollHighlightEnabled,
            isProgrammaticScroll: session.isProgrammaticScroll,
            externalTabSelection: Bindable(session).externalTabSelection,
            selectedTab: Bindable(session).aiPanelSelectedTab,
            pendingChatPrompt: Bindable(session).pendingChatPrompt,
            isChatInputFocused: Bindable(session).isChatInputFocused,
            isRSVPMode: session.isRSVPMode,
            isRSVPPlaying: session.isRSVPMode ? session.rsvpEngine.isPlaying : session.autoScroll.isActive,
            rsvpWPM: session.rsvpEngine.wpm,
            onRSVPModeToggle: { enabled in
                session.setRSVPMode(enabled)
            },
            onRSVPTogglePlay: {
                if session.isRSVPMode { session.rsvpEngine.toggle() }
                else { session.setAutoScrollEnabled(!session.autoScroll.isActive) }
            },
            isAtChapterBottom: session.isAtChapterBottom,
            onApplyAdjustment: { appState.readingSpeedTracker.applyAdjustment($0) },
            onToggleAutoScroll: { session.setAutoScrollEnabled($0) },
            expandedImage: Bindable(session).expandedImage,
            visibleAnnotationIds: session.visibleAnnotationIds,
            visibleImageIds: session.visibleImageIds,
            isOnLastPage: session.isOnLastPage
        )
    }
}

private struct ReaderChapterHeader: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var showsReadingLayout = false

    private var showsControls: Bool {
        isHovered || showsReadingLayout || session.showChapterList
    }

    var body: some View {
        ZStack {
            ReaderWindowHeader()
            Text(appState.currentBook?.title ?? "")
                .font(.system(size: 11))
                .foregroundColor(theme.subtle)
                .lineLimit(1)
                .padding(.horizontal, 176)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                Button { appState.closeBook() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .help("Back to Library")
                .accessibilityLabel("Back to Library")
                Spacer(minLength: 0)
                Button { session.showChapterList.toggle() } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .help(session.currentChapter?.title ?? "Chapters")
                .accessibilityLabel("Chapters")
                .popover(isPresented: Bindable(session).showChapterList) {
                    ReaderChapterListPopover(session: session)
                }
                Button { showsReadingLayout.toggle() } label: {
                    Image(systemName: readingLayoutIcon)
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .help("Reading layout")
                .accessibilityLabel("Reading layout")
                .popover(isPresented: $showsReadingLayout, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("READING LAYOUT")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1)
                            .foregroundColor(theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        layoutOption("Scroll", icon: "scroll", mode: .scroll)
                        layoutOption("One column", icon: "doc.text", mode: .pages, layout: .single)
                        layoutOption("Two columns", icon: "book.pages", mode: .pages, layout: .spread)
                    }
                    .padding(8)
                    .frame(width: 210)
                    .background(theme.surface)
                }
                Button { session.setAIPanelVisible(!session.isAIPanelVisible) } label: {
                    Image(systemName: "sidebar.right")
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .help(session.isAIPanelVisible ? "Hide AI sidebar and pause AI" : "Show AI sidebar and resume AI")
                .accessibilityLabel(session.isAIPanelVisible ? "Hide AI sidebar" : "Show AI sidebar")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.subtle)
            .buttonStyle(.plain)
            .padding(.leading, 84)
            .padding(.trailing, 12)
            .opacity(showsControls ? 1 : 0)
        }
        .frame(height: ReaderMetrics.readingHeaderHeight)
        .background(theme.base)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: showsControls)
    }

    private var readingLayoutIcon: String {
        guard appState.settings.readingMode == .pages else { return "scroll" }
        return appState.settings.pageLayout == .spread ? "book.pages" : "doc.text"
    }

    private func layoutOption(_ title: String, icon: String, mode: ReaderReadingMode, layout: ReaderPageLayout? = nil) -> some View {
        let selected = appState.settings.readingMode == mode &&
            (layout == nil || appState.settings.pageLayout == layout)
        return Button {
            if let layout { session.setPageLayout(layout) }
            session.setReadingMode(mode)
            showsReadingLayout = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.rose)
                }
            }
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .foregroundColor(theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(selected ? theme.overlay : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct ReaderChapterListPopover: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.chapters) { chapter in
                        Button {
                            appState.currentChapterIndex = chapter.index
                            session.showChapterList = false
                        } label: {
                            HStack {
                                Text(chapter.title).font(.system(size: 13))
                                    .foregroundColor(chapter.id == session.currentChapter?.id ? theme.rose : theme.text)
                                Spacer()
                                if let id = chapter.id, let state = session.analyzer?.processingStates[id], (state.isProcessingInsights || state.isProcessingImages) {
                                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                                } else if chapter.processed {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(theme.foam)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(chapter.id == session.currentChapter?.id ? theme.overlay : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).id(chapter.id)
                    }
                }
            }
            .onAppear { if let id = session.currentChapter?.id { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(width: 280, height: min(CGFloat(session.chapters.count) * 36 + 16, 400)).background(theme.surface)
    }
}

private struct ReaderNavigationFooter: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        ZStack {
            HStack {
                if isPaged {
                    pageButton(direction: -1)
                    Spacer()
                    pageButton(direction: 1)
                } else {
                    chapterButton(direction: -1)
                    Spacer()
                    chapterButton(direction: 1)
                }
            }
            .opacity(isHovered ? 1 : 0)
            Text(positionLabel)
                .overlay {
                    if isHovered, let total = positionTotal {
                        GeometryReader { geometry in
                            Text(" / \(total)")
                                .fixedSize()
                                .frame(height: geometry.size.height)
                                .offset(x: geometry.size.width)
                        }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(theme.subtle)
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityLabel(positionAccessibilityLabel)
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.readingFooterHeight)
        .background(theme.base)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .overlay(alignment: .top) {
            ZStack {
                if session.autoScroll.showIndicator, let targetDate = session.autoScroll.countdownTargetDate {
                    AutoScrollFuse(
                        targetDate: targetDate, duration: session.autoScroll.countdownDuration, theme: theme
                    ).transition(.opacity)
                }
            }.animation(.easeInOut, value: session.autoScroll.showIndicator)
        }
    }

    private var isPaged: Bool {
        appState.settings.readingMode == .pages && !session.isRSVPMode
    }

    private var positionLabel: String {
        guard isPaged else { return "\(appState.currentChapterIndex + 1)" }
        if session.bookPaginationFailed { return "Page count unavailable" }
        guard let page = session.bookPageNumber, session.bookPageCount != nil else { return "Paginating…" }
        return "\(page)"
    }

    private var positionTotal: Int? {
        guard isPaged else { return session.chapters.count }
        return session.bookPaginationFailed || session.bookPageNumber == nil ? nil : session.bookPageCount
    }

    private var positionAccessibilityLabel: String {
        guard let total = positionTotal else { return positionLabel }
        return "\(isPaged ? "Page" : "Chapter") \(positionLabel) of \(total)"
    }

    private func pageButton(direction: Int) -> some View {
        let backward = direction < 0
        let disabled = backward
            ? session.pageIndex == nil || ((session.pageIndex ?? 0) == 0 && appState.currentChapterIndex == 0)
            : !session.canAdvancePage
        return Button { session.turnPage(direction) } label: {
            HStack(spacing: 5) {
                if backward { Image(systemName: "chevron.left") }
                Text(backward ? "Previous" : "Next")
                if !backward { Image(systemName: "chevron.right") }
            }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? theme.muted.opacity(0.4) : theme.subtle)
                .frame(height: ReaderMetrics.readingFooterHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(backward ? "Previous page" : session.isOnLastPage ? "Continue after chapter" : "Next page")
        .accessibilityLabel(backward ? "Previous page" : "Next page")
    }

    private func chapterButton(direction: Int) -> some View {
        let backward = direction < 0
        let disabled = backward
            ? appState.currentChapterIndex == 0
            : appState.currentChapterIndex >= session.chapters.count - 1
        return Button {
            if backward { appState.previousChapter() }
            else { appState.nextChapter() }
        } label: {
            HStack(spacing: 5) {
                if backward { Image(systemName: "chevron.left") }
                Text(backward ? "Previous" : "Next")
                if !backward { Image(systemName: "chevron.right") }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(disabled ? theme.muted.opacity(0.4) : theme.subtle)
            .frame(height: ReaderMetrics.readingFooterHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(backward ? "Previous chapter" : "Next chapter")
    }
}

private struct ReaderBackAnchorOverlay: View {
    let session: ReaderSession
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Button { session.returnToBackAnchor() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .black))
                    Text("RETURN").font(.system(size: 10, weight: .bold)).kerning(1.2)
                }
                .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 12)
                .background(Color.black.opacity(0.001)).contentShape(Rectangle())
            }
            .buttonStyle(BackAnchorButtonStyle(accentColor: theme.rose))
            Rectangle().fill(theme.overlay).frame(width: 1, height: 18)
            Button { session.dismissBackAnchor() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.001)).contentShape(Rectangle())
            }
            .buttonStyle(BackAnchorButtonStyle(accentColor: theme.muted))
        }
        .background(Capsule().fill(theme.surface).shadow(color: Color.black.opacity(0.1), radius: 15, y: 8))
        .overlay { Capsule().stroke(theme.rose.opacity(0.2), lineWidth: 1) }
        .padding(24).transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ReaderImageOverlay: View {
    let image: GeneratedImage
    let session: ReaderSession
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.2)) { session.expandedImage = nil } }
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.2)) { session.expandedImage = nil } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 32)).foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                }.padding(.horizontal, 30).padding(.top, 20)
                AsyncImage(url: image.imageURL) { phase in
                    if case .success(let loaded) = phase {
                        loaded.resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.5), radius: 20)
                    } else if case .failure = phase {
                        VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(.system(size: 48)); Text("Failed to load image").font(.system(size: 16)) }.foregroundColor(.white.opacity(0.6))
                    } else { ProgressView().progressViewStyle(.circular).scaleEffect(1.5) }
                }.padding(.horizontal, 60)
                Text(image.displayExcerpt).font(.system(size: 14)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 80).padding(.bottom, 30)
            }
        }
    }
}

private struct ReaderErrorView: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 16) {
            Spacer(); Image(systemName: "exclamationmark.triangle").font(.system(size: 48, weight: .light)).foregroundColor(theme.love)
            Text("Failed to load chapter").font(.system(size: 18, weight: .semibold)).foregroundColor(theme.text)
            Text(error).font(.system(size: 14)).foregroundColor(theme.muted).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button(action: onRetry) {
                HStack(spacing: 8) { Image(systemName: "arrow.clockwise"); Text("Retry") }
                    .font(.system(size: 14, weight: .medium)).foregroundColor(theme.base)
                    .padding(.horizontal, 20).padding(.vertical, 10).background(theme.rose).clipShape(Capsule())
            }.buttonStyle(.plain); Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.base)
    }
}

private struct ReaderLoadingView: View {
    let isImporting: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text(isImporting ? "Importing book content..." : "Loading chapters...").font(.system(size: 14)).foregroundColor(theme.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.base)
    }
}

private struct ReaderNoChaptersView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 16) {
            Spacer(); Image(systemName: "book.closed").font(.system(size: 48, weight: .light)).foregroundColor(theme.muted)
            Text("No chapters found").font(.system(size: 18, weight: .semibold)).foregroundColor(theme.text)
            Text("This book doesn't appear to have any readable content.").font(.system(size: 14)).foregroundColor(theme.muted); Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.base)
    }
}

private struct BackAnchorButtonStyle: ButtonStyle {
    let accentColor: Color
    @State private var isHovered = false
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        let highlight = accentColor == theme.muted ? theme.text : accentColor
        configuration.label.foregroundColor(configuration.isPressed ? highlight : (isHovered ? highlight : theme.muted))
            .background(isHovered ? highlight.opacity(0.06) : Color.clear)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hovering in isHovered = hovering; hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
    }
}

private struct AutoScrollFuse: View {
    let targetDate: Date
    let duration: TimeInterval
    let theme: Theme
    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let progress = 1.0 - (targetDate.timeIntervalSince(now) / duration)
            GeometryReader { proxy in
                let width = proxy.size.width
                let isOvertime = progress >= 1.0
                let fillWidth = width * min(1.0, max(0, progress))
                ZStack(alignment: .leading) {
                    Rectangle().fill(LinearGradient(stops: [.init(color: theme.rose.opacity(0.0), location: 0), .init(color: theme.rose.opacity(0.5), location: 0.7), .init(color: theme.rose, location: 1.0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: fillWidth).shadow(color: theme.rose.opacity(0.5), radius: 3)
                    let sparkSize: CGFloat = isOvertime ? 4 : 3
                    let pulse = isOvertime ? (sin(now.timeIntervalSince(targetDate) * 15) * 0.5 + 0.5) : 0
                    Circle().fill(Color.white).frame(width: sparkSize, height: sparkSize).shadow(color: .white, radius: 2 + pulse).shadow(color: theme.rose, radius: 6 + (pulse * 4)).offset(x: fillWidth - (sparkSize / 2)).opacity(progress > 0.01 ? 1 : progress * 100)
                }
            }
        }.frame(height: 2).allowsHitTesting(false)
    }
}
