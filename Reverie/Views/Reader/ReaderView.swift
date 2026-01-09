import AppKit
import SwiftUI

struct ReaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var session = ReaderSession()

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                ReaderBookPanel(session: session)
                    .frame(minWidth: 400, idealWidth: proxy.size.width * appState.splitRatio)
                ReaderAIPanel(session: session)
                    .frame(minWidth: 280, idealWidth: proxy.size.width * (1 - appState.splitRatio))
            }
        }
        .background(theme.base)
        .overlay {
            if let image = session.expandedImage {
                ReaderImageOverlay(image: image, session: session)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(appState.currentBook?.title ?? "").font(.system(size: 14, weight: .medium)).foregroundColor(theme.text)
            }
        }
        .task {
            session.setup(with: appState)
            await session.loadChapters()
        }
        .onAppear { session.startReadingTicker() }
        .onDisappear { session.cleanup() }
        .onKeyPress(.space) { session.handleSpaceBar() }
        .onKeyPress { session.handleKeyPress($0) }
        .onChange(of: appState.currentChapterIndex) { _, idx in Task { await session.loadChapter(at: idx) } }
        .onChange(of: session.aiPanelSelectedTab) { old, new in session.handleTabChange(from: old, to: new) }
        .onChange(of: session.expandedImage) { old, new in session.handleExpandedImageChange(from: old, to: new) }
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
                            if let img = session.images.first(where: { $0.id == id }) {
                                withAnimation(.easeOut(duration: 0.2)) { session.expandedImage = img }
                            }
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
                        scrollByAmount: Bindable(session).scrollByAmount
                    )
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
            onGenerateMoreInsights: { session.generateMoreInsights() },
            onGenerateMoreQuestions: { session.generateMoreQuestions() },
            onForceProcess: { session.forceProcessGarbageChapter() },
            onProcessManually: { session.processCurrentChapter() },
            onRetryClassification: { session.retryClassification() },
            onCancelAnalysis: { session.cancelAnalysis() },
            onCancelImages: { session.cancelAnalysis() },
            autoScrollHighlightEnabled: appState.settings.autoScrollHighlightEnabled,
            isProgrammaticScroll: session.isProgrammaticScroll,
            externalTabSelection: Bindable(session).externalTabSelection,
            selectedTab: Bindable(session).aiPanelSelectedTab,
            pendingChatPrompt: Bindable(session).pendingChatPrompt,
            isChatInputFocused: Bindable(session).isChatInputFocused,
            scrollPercent: session.lastScrollPercent,
            chapterWPM: session.chapterWPM,
            onApplyAdjustment: { appState.readingSpeedTracker.applyAdjustment($0) },
            expandedImage: Bindable(session).expandedImage
        )
    }
}

private struct ReaderChapterHeader: View {
    let session: ReaderSession
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Button { appState.closeBook() } label: {
                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Library") }
                    .font(.system(size: 13, weight: .medium)).foregroundColor(theme.subtle)
                    .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, -12)
            Spacer()
            Button { session.showChapterList.toggle() } label: {
                HStack(spacing: 6) {
                    Text(session.currentChapter?.title ?? (session.isLoadingChapters ? "Loading..." : "No Chapter"))
                        .font(.system(size: 14, weight: .medium)).foregroundColor(theme.text).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.muted)
                }
                .padding(.vertical, 8).padding(.horizontal, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Bindable(session).showChapterList) {
                ReaderChapterListPopover(session: session)
            }
            Spacer()
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.headerHeight).background(theme.surface)
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

    var body: some View {
        HStack {
            Button { appState.previousChapter() } label: {
                HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Previous") }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appState.currentChapterIndex > 0 ? theme.text : theme.muted)
                    .padding(.vertical, 8).padding(.horizontal, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(appState.currentChapterIndex <= 0)
            Spacer()
            Text("\(appState.currentChapterIndex + 1) / \(session.chapters.count)")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(theme.muted)
            Spacer()
            Button { appState.nextChapter() } label: {
                HStack(spacing: 4) { Text("Next"); Image(systemName: "chevron.right") }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appState.currentChapterIndex < session.chapters.count - 1 ? theme.text : theme.muted)
                    .padding(.vertical, 8).padding(.horizontal, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(appState.currentChapterIndex >= session.chapters.count - 1)
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.footerHeight).background(theme.surface)
        .overlay(alignment: .top) {
            ZStack {
                Rectangle().fill(theme.overlay).frame(height: 1).opacity(session.autoScroll.showIndicator ? 0 : 1)
                if session.autoScroll.showIndicator, let targetDate = session.autoScroll.countdownTargetDate {
                    AutoScrollFuse(
                        targetDate: targetDate, duration: session.autoScroll.countdownDuration, theme: theme
                    ).transition(.opacity)
                }
            }.animation(.easeInOut, value: session.autoScroll.showIndicator)
        }
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
                Text(image.prompt).font(.system(size: 14)).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 80).padding(.bottom, 30)
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
