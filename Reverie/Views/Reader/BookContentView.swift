import SwiftUI
import WebKit
import Foundation

enum ReaderBridgeScriptLoader {
    private static let resourceName = "ReaderBridge"
    private static let resourceExtension = "js"

    static func load() -> String {
        if let source = loadSource(primaryBundle: .main, fallbackBundle: moduleResourceBundle) {
            return source
        }

        assertionFailure("ReaderBridge.js not found in app resources")
        return ""
    }

    static func loadSource(
        primaryBundle: Bundle,
        fallbackBundle: (() -> Bundle?)? = nil
    ) -> String? {
        if let source = loadSource(scriptURL: scriptURL(in: primaryBundle)) {
            return source
        }

        guard let bundle = fallbackBundle?() else { return nil }
        return loadSource(scriptURL: scriptURL(in: bundle))
    }

    static func loadSource(scriptURL: URL?) -> String? {
        guard let scriptURL else { return nil }
        return try? String(contentsOf: scriptURL, encoding: .utf8)
    }

    static func scriptURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }

    #if SWIFT_PACKAGE
    static func moduleResourceBundle() -> Bundle? { .module }
    #else
    static func moduleResourceBundle() -> Bundle? { nil }
    #endif
}

struct MarkerInjection: Equatable {
    let annotationId: Int64
    let sourceBlockId: Int
}

struct ImageMarkerInjection: Equatable {
    let imageId: Int64
    let sourceBlockId: Int
}

struct MarkerInfo: Equatable, Identifiable {
    let id: String
    let type: String
    let y: Double
    let blockId: Int
}

struct ScrollContext: Equatable {
    let annotationId: Int64?
    let imageId: Int64?
    let footnoteRefId: String?
    let blockId: Int?
    let blockOffset: Double?
    let primaryType: String?
    let scrollPercent: Double
    let scrollOffset: Double
    let viewportHeight: Double
    let scrollHeight: Double
    let isProgrammatic: Bool
}

enum BookContentHTMLBuilder {
    struct RenderInput: Sendable, Equatable {
        struct Injection: Sendable, Equatable {
            enum Kind: Sendable, Equatable {
                case annotation(id: Int64)
                case imageMarker(id: Int64)
                case inlineImage(url: URL)
            }

            let kind: Kind
            let sourceBlockId: Int

            var parserInjection: ContentBlockParser.Injection {
                let kind: ContentBlockParser.Injection.Kind = switch kind {
                case .annotation(let id):
                    .annotation(id: id)
                case .imageMarker(let id):
                    .imageMarker(id: id)
                case .inlineImage(let url):
                    .inlineImage(url: url)
                }

                return .init(kind: kind, sourceBlockId: sourceBlockId)
            }
        }

        let contentHTML: String
        let injections: [Injection]
        let themeBase: String
        let themeSurface: String
        let themeText: String
        let themeMuted: String
        let themeRose: String
        let themeIris: String
        let fontFamily: String
        let fontSize: Double
        let lineSpacing: Double
        let baseHref: String
        let documentToken: String
        let readerBridgeJS: String
    }

    static func buildHTML(from input: RenderInput) -> String {
        let content = ContentBlockParser().augment(
            html: input.contentHTML,
            injections: input.injections.map(\.parserInjection)
        )

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <base href="\(input.baseHref)">
            <style>
                :root {
                    --base: \(input.themeBase);
                    --surface: \(input.themeSurface);
                    --text: \(input.themeText);
                    --muted: \(input.themeMuted);
                    --rose: \(input.themeRose);
                    --iris: \(input.themeIris);
                }
                html, body { margin: 0; padding: 0; background: var(--base); color: var(--text);
                             font-family: "\(input.fontFamily)", sans-serif; font-size: \(input.fontSize)px; line-height: \(input.lineSpacing); }
                body { padding: 40px 60px; position: relative; }

                #readerContent { position: relative; z-index: 1; }

                .selection-overlay { position: absolute; top: 0; left: 0; width: 100%; height: 0; pointer-events: none; overflow: visible; z-index: 0; }
                .selection-rect { position: absolute; background: var(--rose); border-radius: 2px; }

                ::selection { background: transparent !important; color: var(--base) !important; }
                ::-webkit-selection { background: transparent !important; color: var(--base) !important; }

                .annotation-marker, .image-marker {
                    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
                    margin-left: 6px; cursor: pointer; vertical-align: middle; transition: transform 0.2s, background-color 0.2s;
                }
                .annotation-marker { background: var(--rose); }
                .image-marker { background: var(--iris); }
                .generated-image { width: 100%; margin: 2em 0; border-radius: 12px; }
                .word-popup { position: fixed; background: var(--surface); border: 1px solid var(--rose); border-radius: 8px; padding: 8px; display: none; z-index: 1000; }
                .word-popup button { display: block; width: 100%; padding: 8px; background: transparent; border: none; color: var(--text); cursor: pointer; text-align: left; }
                .footnote-ref { color: var(--rose); text-decoration: none; font-size: 0.8em; vertical-align: super; margin-left: 2px; }

                a { color: var(--rose); text-decoration: none; transition: color 0.15s ease, opacity 0.15s ease; }
                a:hover { opacity: 0.8; text-decoration: underline; text-underline-offset: 2px; }
                a:visited { color: var(--rose); opacity: 0.85; }

                .highlight-active { border-radius: 4px; padding: 2px 4px; margin: -2px -4px; }
                .marker-highlight {
                    transform: scale(1.6) !important;
                    background-color: var(--highlight-color) !important;
                    box-shadow: 0 0 15px 3px var(--highlight-color) !important;
                    z-index: 100 !important;
                    transition: transform 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275), box-shadow 0.4s !important;
                }

                @keyframes marker-pulse-anim {
                    0% { background-color: var(--highlight-color); box-shadow: 0 0 0 0 rgba(0,0,0,0); }
                    30% { background-color: #ffffff; box-shadow: 0 0 8px 3px var(--highlight-color), 0 0 5px 2px rgba(255,255,255,0.9); }
                    60% { background-color: var(--highlight-color); box-shadow: 0 0 0 0 rgba(0,0,0,0); }
                    100% { background-color: var(--highlight-color); box-shadow: 0 0 0 0 rgba(0,0,0,0); }
                }
                .marker-pulse {
                    animation: marker-pulse-anim 0.5s ease-out;
                    z-index: 90;
                }
            </style>
        </head>
        <body>
            <div id="selectionOverlay" class="selection-overlay"></div>
            <div id="readerContent">\(content)</div>
            <div id="wordPopup" class="word-popup">
                <button onclick="handleExplain()">Explain</button>
                <button onclick="handleGenerateImage()">Generate Image</button>
            </div>
            <script>window.__readerDocumentToken = '\(input.documentToken.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))';</script>
            <script>\(input.readerBridgeJS)</script>
        </body>
        </html>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BookContentView: NSViewRepresentable {
    typealias BindingMutationScheduler = (@MainActor @Sendable @escaping () -> Void) -> Void

    let chapter: Chapter
    let annotations: [Annotation]
    let images: [GeneratedImage]
    let selectedTab: AIPanel.Tab
    let onWordClick: (String, String, Int, WordAction) -> Void
    let onAnnotationClick: (Annotation) -> Void
    let onImageMarkerClick: (Int64) -> Void
    let onFootnoteClick: (String) -> Void
    let onChapterNavigationRequest: ((String, String?) -> Void)?
    let onImageMarkerDblClick: (Int64) -> Void
    let onScrollPositionChange: (_ context: ScrollContext) -> Void
    let onMarkersUpdated: ([MarkerInfo]) -> Void
    let onBottomTug: () -> Void
    @Binding var scrollToAnnotationId: Int64?
    @Binding var scrollToPercent: Double?
    @Binding var scrollToOffset: Double?
    @Binding var scrollToBlockId: (Int, Int64?, String?)?
    @Binding var scrollToQuote: String?
    @Binding var pendingMarkerInjections: [MarkerInjection]
    @Binding var pendingImageMarkerInjections: [ImageMarkerInjection]
    @Binding var scrollByAmount: Double?

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    enum WordAction { case explain, generateImage }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "readerBridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let state = makeViewState()
        coordinator.setDesiredState(state)

        let hasContentNavigationRequest = scrollToAnnotationId != nil || scrollToQuote != nil || scrollToBlockId != nil
        if coordinator.needsDocumentLoad(for: state.document) {
            coordinator.prepareForDocumentLoad(
                state: state,
                requestedScrollOffset: scrollToOffset,
                requestedScrollPercent: scrollToPercent,
                hasContentNavigationRequest: hasContentNavigationRequest
            )
            loadHTML(on: webView, coordinator: coordinator, state: state)
        }

        if let navigationRequest = coordinator.consumeContentNavigationRequest(
            annotationId: scrollToAnnotationId,
            quote: scrollToQuote,
            block: scrollToBlockId
        ) {
            if coordinator.isContentLoaded {
                coordinator.pendingContentNavigationClearAction = {
                    DispatchQueue.main.async {
                        clearContentNavigationRequest(navigationRequest)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    clearContentNavigationRequest(navigationRequest)
                }
            }
        }

        if discardBlockedExplicitScrollIfNeeded(using: coordinator) == nil,
           let requestedScroll = coordinator.consumeExplicitScrollRequest(
                requestedScrollOffset: scrollToOffset,
                requestedScrollPercent: scrollToPercent
           ) {
            if coordinator.isContentLoaded {
                coordinator.pendingScrollClearAction = {
                    scheduleRequestedScrollClear(requestedScroll)
                }
            } else {
                scheduleRequestedScrollClear(requestedScroll)
            }
        }

        if coordinator.isContentLoaded {
            coordinator.flush(on: webView)
        }

        if let amount = scrollByAmount {
            webView.evaluateJavaScript("window.scrollBy({top: \(amount), behavior: 'smooth'});") { _, _ in
                DispatchQueue.main.async {
                    if self.scrollByAmount == amount {
                        self.scrollByAmount = nil
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeHTMLRenderInput(for state: BookContentViewState) -> BookContentHTMLBuilder.RenderInput {
        BookContentHTMLBuilder.RenderInput(
            contentHTML: state.document.contentHTML,
            injections: [],
            themeBase: state.style.themeBase,
            themeSurface: state.style.themeSurface,
            themeText: state.style.themeText,
            themeMuted: state.style.themeMuted,
            themeRose: state.style.themeRose,
            themeIris: state.style.themeIris,
            fontFamily: state.style.fontFamily,
            fontSize: state.style.fontSize,
            lineSpacing: state.style.lineSpacing,
            baseHref: state.document.baseHref,
            documentToken: state.document.bridgeToken,
            readerBridgeJS: Self.readerBridgeJS
        )
    }

    func makeViewState() -> BookContentViewState {
        let settings = appState.settings
        let style = BookContentStyleState(
            themeBase: theme.base.hexString,
            themeSurface: theme.surface.hexString,
            themeText: theme.text.hexString,
            themeMuted: theme.muted.hexString,
            themeRose: theme.rose.hexString,
            themeIris: theme.iris.hexString,
            fontFamily: settings.fontFamily,
            fontSize: Double(settings.fontSize),
            lineSpacing: Double(settings.lineSpacing)
        )
        let document = BookContentDocumentState(
            chapterId: chapter.id,
            chapterIndex: chapter.index,
            contentHTML: chapter.contentHTML,
            baseHref: chapterDirectoryURL().absoluteString
        )
        let decorations = BookContentDecorationState(
            annotations: annotations,
            images: images,
            inlineAIImagesEnabled: settings.inlineAIImages,
            pendingMarkers: pendingMarkerInjections,
            pendingImageMarkers: pendingImageMarkerInjections
        )

        return BookContentViewState(document: document, style: style, decorations: decorations)
    }

    private static let readerBridgeJS = ReaderBridgeScriptLoader.load()

    private func chapterDirectoryURL() -> URL {
        let root = LibraryPaths.publicationDirectory(for: chapter.bookId)
        if let path = chapter.resourcePath, !path.isEmpty {
            return root.appendingPathComponent(path).deletingLastPathComponent()
        }
        return root
    }

    private func readerRootDirectoryURL() -> URL { LibraryPaths.readerRoot }

    @MainActor
    private func loadHTML(on webView: WKWebView, coordinator: Coordinator, state: BookContentViewState) {
        let renderInput = makeHTMLRenderInput(for: state)
        let fileURL = renderedChapterURL()
        let readerRootURL = readerRootDirectoryURL()
        let documentGeneration = coordinator.currentDocumentGenerationForTesting

        coordinator.loadTask?.cancel()
        coordinator.loadTask = Task { @MainActor in
            let shouldReuseRenderedHTML = coordinator.shouldReuseRenderedHTML(at: fileURL, for: state.document)
            let persistenceResult = await Task.detached(priority: .userInitiated) {
                do {
                    try LibraryPaths.ensureDirectory(fileURL.deletingLastPathComponent())

                    if shouldReuseRenderedHTML {
                        return RenderedHTMLPersistenceResult.reused
                    }

                    let html = BookContentHTMLBuilder.buildHTML(from: renderInput)
                    try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    return RenderedHTMLPersistenceResult.wroteFile
                } catch {
                    return RenderedHTMLPersistenceResult.failed
                }
            }.value

            if Task.isCancelled {
                return
            }

            guard coordinator.isCurrentDocumentGeneration(documentGeneration) else {
                return
            }

            if persistenceResult == .wroteFile {
                coordinator.recordRenderedHTMLPersistenceSuccess(at: fileURL, for: state.document)
            }

            if persistenceResult != .failed {
                let navigation = webView.loadFileURL(fileURL, allowingReadAccessTo: readerRootURL)
                coordinator.registerNavigation(navigation, documentGeneration: documentGeneration)
                return
            }

            let html = await Task.detached(priority: .userInitiated) {
                BookContentHTMLBuilder.buildHTML(from: renderInput)
            }.value

            if Task.isCancelled {
                return
            }

            guard coordinator.isCurrentDocumentGeneration(documentGeneration) else {
                return
            }

            let navigation = webView.loadHTMLString(html, baseURL: readerRootURL)
            coordinator.registerNavigation(navigation, documentGeneration: documentGeneration)
        }
    }

    private func renderedChapterURL() -> URL {
        let renderDir = LibraryPaths.publicationDirectory(for: chapter.bookId)
            .appendingPathComponent("_reader", isDirectory: true)
        let idComponent = chapter.id.map(String.init) ?? "index-\(chapter.index)"
        return renderDir.appendingPathComponent("chapter-\(idComponent).html")
    }

    private enum RenderedHTMLPersistenceResult {
        case reused
        case wroteFile
        case failed
    }

    private func clearRequestedScroll(_ request: Coordinator.ScrollRequest) {
        switch request {
        case .offset(let offset):
            if scrollToOffset == offset {
                scrollToOffset = nil
            }
        case .percent(let percent):
            if scrollToPercent == percent {
                scrollToPercent = nil
            }
        }
    }

    private func scheduleRequestedScrollClear(
        _ request: Coordinator.ScrollRequest,
        scheduler: @escaping BindingMutationScheduler = { action in
            DispatchQueue.main.async(execute: action)
        }
    ) {
        scheduler {
            clearRequestedScroll(request)
        }
    }

    @discardableResult
    func discardBlockedExplicitScrollIfNeeded(
        using coordinator: Coordinator,
        scheduler: @escaping BindingMutationScheduler = { action in
            DispatchQueue.main.async(execute: action)
        }
    ) -> Coordinator.ScrollRequest? {
        guard let blockedScroll = coordinator.blockedExplicitScrollRequest(
            requestedScrollOffset: scrollToOffset,
            requestedScrollPercent: scrollToPercent
        ) else {
            return nil
        }

        scheduleRequestedScrollClear(blockedScroll, scheduler: scheduler)
        return blockedScroll
    }

    private func clearContentNavigationRequest(_ request: Coordinator.ContentNavigationRequest) {
        switch request {
        case .annotation(let id):
            if scrollToAnnotationId == id {
                scrollToAnnotationId = nil
            }
        case .quote(let quote):
            if scrollToQuote == quote {
                scrollToQuote = nil
            }
        case .block(let target):
            if let current = scrollToBlockId,
               current.0 == target.blockId,
               current.1 == target.markerId,
               current.2 == target.type {
                scrollToBlockId = nil
            }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        struct BlockNavigationTarget: Equatable {
            let blockId: Int
            let markerId: Int64?
            let type: String?
        }

        enum ScrollRequest: Equatable {
            case offset(Double)
            case percent(Double)

            init?(offset: Double?, percent: Double?) {
                if let offset {
                    self = .offset(offset)
                } else if let percent {
                    self = .percent(percent)
                } else {
                    return nil
                }
            }

            var javaScript: String {
                switch self {
                case .offset(let offset):
                    return "scrollToOffset(\(offset));"
                case .percent(let percent):
                    return "scrollToPercent(\(percent));"
                }
            }
        }

        enum ContentNavigationRequest: Equatable {
            case annotation(Int64)
            case quote(String)
            case block(BlockNavigationTarget)

            init?(annotationId: Int64?, quote: String?, block: (Int, Int64?, String?)?) {
                if let annotationId {
                    self = .annotation(annotationId)
                } else if let quote {
                    self = .quote(quote)
                } else if let block {
                    self = .block(.init(blockId: block.0, markerId: block.1, type: block.2))
                } else {
                    return nil
                }
            }

            var javaScript: String {
                switch self {
                case .annotation(let id):
                    return "scrollToAnnotation(\(id));"
                case .quote(let quote):
                    let escaped = quote
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    return "scrollToQuote('\(escaped)');"
                case .block(let target):
                    let markerId = target.markerId.map(String.init) ?? "null"
                    let type = target.type.map { "'\($0)'" } ?? "null"
                    return "scrollToBlock(\(target.blockId), \(markerId), \(type));"
                }
            }
        }

        enum PendingScrollSource: Equatable {
            case explicit
            case preserved
        }

        struct PendingRequest<Request: Equatable> {
            private(set) var request: Request?
            private(set) var requestID: Int?
            var clearAction: (() -> Void)?

            mutating func replace(with request: Request, id: Int) {
                self.request = request
                self.requestID = id
                self.clearAction = nil
            }

            mutating func clear() {
                request = nil
                requestID = nil
                clearAction = nil
            }

            func matches(id: Int) -> Bool {
                requestID == id
            }
        }

        var parent: BookContentView
        var isContentLoaded = false
        var pendingScroll: ScrollRequest? { pendingScrollState.request }
        var pendingScrollSource: PendingScrollSource?
        var lastScrollPercent: Double?
        var lastScrollOffset: Double?
        var loadTask: Task<Void, Never>?
        var pendingContentNavigationRequest: ContentNavigationRequest? { pendingContentNavigationState.request }
        var pendingScrollClearAction: (() -> Void)? {
            get { pendingScrollState.clearAction }
            set { pendingScrollState.clearAction = newValue }
        }
        var pendingContentNavigationClearAction: (() -> Void)? {
            get { pendingContentNavigationState.clearAction }
            set { pendingContentNavigationState.clearAction = newValue }
        }

        private var desiredState: BookContentViewState?
        private var currentDocumentState: BookContentDocumentState?
        private var appliedStyle: BookContentStyleState?
        private var appliedMarkerPayload: BookContentDecorationState.MarkerPayload = .empty
        private var appliedInlineImagePayload: BookContentDecorationState.InlineImagePayload = .empty
        private var isFlushing = false
        private var needsFlushAfterCurrent = false
        private var renderedHTMLCache: [String: Int] = [:]
        private var pendingScrollState = PendingRequest<ScrollRequest>()
        private var pendingContentNavigationState = PendingRequest<ContentNavigationRequest>()
        private var nextPendingRequestID = 1
        private var currentDocumentGeneration = 0
        private var currentDocumentTokenStorage = ""
        private var nextNavigationLoadID = 1
        private var activeNavigationLoadID: Int?
        private var activeNavigationDocumentGeneration: Int?
        private var acceptedBridgeDocumentToken: String?
        private var navigationLoadIDsByObjectIdentifier: [ObjectIdentifier: Int] = [:]
        private var consumedExplicitScroll: ScrollRequest?
        private var consumedContentNavigationRequest: ContentNavigationRequest?

        var appliedStyleForTesting: BookContentStyleState? {
            appliedStyle
        }

        var appliedDecorationsForTesting: BookContentDecorationState {
            .init(
                annotationMarkers: appliedMarkerPayload.annotations,
                imageMarkers: appliedMarkerPayload.imageMarkers,
                inlineAIImagesEnabled: appliedInlineImagePayload.inlineAIImagesEnabled,
                inlineImages: appliedInlineImagePayload.inlineImages
            )
        }

        var pendingScrollRequestIDForTesting: Int? {
            pendingScrollState.requestID
        }

        var pendingContentNavigationRequestIDForTesting: Int? {
            pendingContentNavigationState.requestID
        }

        var currentDocumentGenerationForTesting: Int {
            currentDocumentGeneration
        }

        var currentDocumentToken: String {
            currentDocumentTokenStorage
        }

        var currentDocumentTokenForTesting: String {
            currentDocumentTokenStorage
        }

        var acceptedBridgeDocumentTokenForTesting: String? {
            acceptedBridgeDocumentToken
        }

        init(parent: BookContentView) {
            self.parent = parent
        }

        func setDesiredState(_ state: BookContentViewState) {
            desiredState = state
        }

        func needsDocumentLoad(for document: BookContentDocumentState) -> Bool {
            currentDocumentState != document
        }

        func prepareForDocumentLoad(
            state: BookContentViewState,
            requestedScrollOffset: Double?,
            requestedScrollPercent: Double?,
            hasContentNavigationRequest: Bool
        ) {
            currentDocumentGeneration += 1
            currentDocumentTokenStorage = state.document.bridgeToken
            currentDocumentState = state.document
            appliedStyle = nil
            appliedMarkerPayload = .empty
            appliedInlineImagePayload = .empty
            isContentLoaded = false
            isFlushing = false
            needsFlushAfterCurrent = false
            activeNavigationLoadID = nil
            activeNavigationDocumentGeneration = nil
            acceptedBridgeDocumentToken = nil
            preserveScrollPositionIfNeeded(
                requestedScrollOffset: requestedScrollOffset,
                requestedScrollPercent: requestedScrollPercent,
                hasContentNavigationRequest: hasContentNavigationRequest
            )
        }

        func isCurrentDocumentGeneration(_ documentGeneration: Int) -> Bool {
            currentDocumentGeneration == documentGeneration
        }

        @discardableResult
        func registerNavigationLoadForTesting(documentGeneration: Int? = nil) -> Int {
            let navigationLoadID = makeNavigationLoadID()
            activeNavigationLoadID = navigationLoadID
            activeNavigationDocumentGeneration = documentGeneration ?? currentDocumentGeneration
            return navigationLoadID
        }

        func registerNavigation(_ navigation: WKNavigation?, documentGeneration: Int) {
            let navigationLoadID = registerNavigationLoadForTesting(documentGeneration: documentGeneration)
            if let navigation {
                navigationLoadIDsByObjectIdentifier[ObjectIdentifier(navigation)] = navigationLoadID
            }
        }

        func shouldReuseRenderedHTML(at fileURL: URL, for document: BookContentDocumentState) -> Bool {
            renderedHTMLCache[fileURL.path] == document.renderSignature &&
            FileManager.default.fileExists(atPath: fileURL.path)
        }

        func recordRenderedHTMLPersistenceSuccess(at fileURL: URL, for document: BookContentDocumentState) {
            renderedHTMLCache[fileURL.path] = document.renderSignature
        }

        @discardableResult
        func consumeContentNavigationRequest(annotationId: Int64?, quote: String?, block: (Int, Int64?, String?)?) -> ContentNavigationRequest? {
            guard let request = ContentNavigationRequest(annotationId: annotationId, quote: quote, block: block) else {
                consumedContentNavigationRequest = nil
                return nil
            }

            guard consumedContentNavigationRequest != request else {
                return nil
            }

            consumedContentNavigationRequest = request
            assignPendingContentNavigationRequest(request)
            clearPendingScroll()
            return request
        }

        @discardableResult
        func consumeExplicitScrollRequest(requestedScrollOffset: Double?, requestedScrollPercent: Double?) -> ScrollRequest? {
            guard pendingContentNavigationRequest == nil else {
                return nil
            }

            guard let request = ScrollRequest(offset: requestedScrollOffset, percent: requestedScrollPercent) else {
                consumedExplicitScroll = nil
                return nil
            }

            guard consumedExplicitScroll != request else {
                return nil
            }

            consumedExplicitScroll = request
            assignPendingScroll(request, source: .explicit)
            return request
        }

        func blockedExplicitScrollRequest(requestedScrollOffset: Double?, requestedScrollPercent: Double?) -> ScrollRequest? {
            guard pendingContentNavigationRequest != nil else {
                return nil
            }

            return ScrollRequest(offset: requestedScrollOffset, percent: requestedScrollPercent)
        }

        func preserveScrollPositionIfNeeded(
            requestedScrollOffset: Double?,
            requestedScrollPercent: Double?,
            hasContentNavigationRequest: Bool
        ) {
            guard requestedScrollOffset == nil, requestedScrollPercent == nil else {
                return
            }

            if hasContentNavigationRequest || pendingContentNavigationRequest != nil {
                if pendingScrollSource == .preserved {
                    clearPendingScroll()
                }
                return
            }

            guard pendingScrollSource != .explicit else {
                return
            }

            if let lastScrollOffset, lastScrollOffset > 0 {
                assignPendingScroll(.offset(lastScrollOffset), source: .preserved)
                return
            }

            if let lastScrollPercent {
                assignPendingScroll(.percent(lastScrollPercent), source: .preserved)
            }
        }

        func clearPendingScroll() {
            pendingScrollState.clear()
            pendingScrollSource = nil
        }

        func clearPendingContentNavigationRequest() {
            pendingContentNavigationState.clear()
        }

        func flush(on webView: WKWebView, triggerInitialScrollReport: Bool = false) {
            guard isContentLoaded else {
                return
            }

            guard !isFlushing else {
                needsFlushAfterCurrent = true
                return
            }

            isFlushing = true
            flushNext(on: webView, triggerInitialScrollReport: triggerInitialScrollReport)
        }

        private func flushNext(on webView: WKWebView, triggerInitialScrollReport: Bool) {
            guard isContentLoaded else {
                finishFlush(on: webView)
                return
            }

            if let style = desiredState?.style,
               appliedStyle != style,
               let javaScript = javaScriptInvocation(function: "applyReaderStyle", payload: style) {
                let documentGeneration = currentDocumentGeneration
                webView.evaluateJavaScript(javaScript) { _, error in
                    _ = self.completeStyleSync(style, documentGeneration: documentGeneration, error: error)
                    self.continueFlushAfterJavaScriptEvaluation(
                        documentGeneration: documentGeneration,
                        error: error,
                        on: webView,
                        triggerInitialScrollReport: triggerInitialScrollReport
                    )
                }
                return
            }

            if let decorations = desiredState?.decorations {
                let decorationPlan = BookContentDecorationUpdatePlan(
                    previous: appliedDecorationsForTesting,
                    desired: decorations
                )
                if decorationPlan.needsMarkerSync,
                   let javaScript = javaScriptInvocation(function: "syncMarkers", payload: decorations.markerPayload) {
                    let documentGeneration = currentDocumentGeneration
                    let markerSnapshot = parent.pendingMarkerInjections
                    let imageMarkerSnapshot = parent.pendingImageMarkerInjections
                    webView.evaluateJavaScript(javaScript) { _, error in
                        _ = self.completeMarkerSync(
                            decorations.markerPayload,
                            markerSnapshot: markerSnapshot,
                            imageMarkerSnapshot: imageMarkerSnapshot,
                            documentGeneration: documentGeneration,
                            error: error
                        )
                        self.continueFlushAfterJavaScriptEvaluation(
                            documentGeneration: documentGeneration,
                            error: error,
                            on: webView,
                            triggerInitialScrollReport: triggerInitialScrollReport
                        )
                    }
                    return
                }

                if decorationPlan.needsInlineImageSync,
                   let javaScript = javaScriptInvocation(function: "syncInlineImages", payload: decorations.inlineImagePayload) {
                    let documentGeneration = currentDocumentGeneration
                    webView.evaluateJavaScript(javaScript) { _, error in
                        _ = self.completeInlineImageSync(
                            decorations.inlineImagePayload,
                            documentGeneration: documentGeneration,
                            error: error
                        )
                        self.continueFlushAfterJavaScriptEvaluation(
                            documentGeneration: documentGeneration,
                            error: error,
                            on: webView,
                            triggerInitialScrollReport: triggerInitialScrollReport
                        )
                    }
                    return
                }
            }

            if let request = pendingContentNavigationRequest,
               let requestID = pendingContentNavigationState.requestID {
                let documentGeneration = currentDocumentGeneration
                applyContentNavigationRequest(request, on: webView) { error in
                    _ = self.completeContentNavigationSync(
                        requestID: requestID,
                        documentGeneration: documentGeneration,
                        error: error
                    )
                    self.continueFlushAfterJavaScriptEvaluation(
                        documentGeneration: documentGeneration,
                        error: error,
                        on: webView,
                        triggerInitialScrollReport: triggerInitialScrollReport
                    )
                }
                return
            }

            if let request = pendingScroll,
               let requestID = pendingScrollState.requestID {
                let documentGeneration = currentDocumentGeneration
                applyScrollRequest(request, on: webView) { error in
                    _ = self.completeScrollSync(
                        requestID: requestID,
                        documentGeneration: documentGeneration,
                        error: error
                    )
                    self.continueFlushAfterJavaScriptEvaluation(
                        documentGeneration: documentGeneration,
                        error: error,
                        on: webView,
                        triggerInitialScrollReport: triggerInitialScrollReport
                    )
                }
                return
            }

            guard triggerInitialScrollReport else {
                finishFlush(on: webView)
                return
            }

            webView.evaluateJavaScript("window.dispatchEvent(new Event('scroll'));") { _, _ in
                self.finishFlush(on: webView)
            }
        }

        private func finishFlush(on webView: WKWebView) {
            isFlushing = false
            guard needsFlushAfterCurrent else {
                return
            }

            needsFlushAfterCurrent = false
            flush(on: webView)
        }

        private func continueFlushAfterJavaScriptEvaluation(
            documentGeneration: Int,
            error: Error?,
            on webView: WKWebView,
            triggerInitialScrollReport: Bool
        ) {
            guard currentDocumentGeneration == documentGeneration else {
                return
            }

            guard error == nil else {
                stopFlushAfterJavaScriptFailure()
                return
            }

            flushNext(on: webView, triggerInitialScrollReport: triggerInitialScrollReport)
        }

        private func stopFlushAfterJavaScriptFailure() {
            isFlushing = false
            needsFlushAfterCurrent = false
        }

        @discardableResult
        func completeStyleSync(_ style: BookContentStyleState, documentGeneration: Int, error: Error?) -> Bool {
            guard error == nil, currentDocumentGeneration == documentGeneration else {
                return false
            }

            appliedStyle = style
            return true
        }

        @discardableResult
        func completeDecorationSync(
            _ decorations: BookContentDecorationState,
            markerSnapshot: [MarkerInjection],
            imageMarkerSnapshot: [ImageMarkerInjection],
            documentGeneration: Int,
            error: Error?
        ) -> Bool {
            let markerDidSync = completeMarkerSync(
                decorations.markerPayload,
                markerSnapshot: markerSnapshot,
                imageMarkerSnapshot: imageMarkerSnapshot,
                documentGeneration: documentGeneration,
                error: error
            )
            let inlineImagesDidSync = completeInlineImageSync(
                decorations.inlineImagePayload,
                documentGeneration: documentGeneration,
                error: error
            )
            return markerDidSync && inlineImagesDidSync
        }

        @discardableResult
        func completeMarkerSync(
            _ markerPayload: BookContentDecorationState.MarkerPayload,
            markerSnapshot: [MarkerInjection],
            imageMarkerSnapshot: [ImageMarkerInjection],
            documentGeneration: Int,
            error: Error?
        ) -> Bool {
            guard error == nil, currentDocumentGeneration == documentGeneration else {
                return false
            }

            appliedMarkerPayload = markerPayload
            clearPendingInjections(
                markerSnapshot: markerSnapshot,
                imageMarkerSnapshot: imageMarkerSnapshot
            )
            return true
        }

        @discardableResult
        func completeInlineImageSync(
            _ inlineImagePayload: BookContentDecorationState.InlineImagePayload,
            documentGeneration: Int,
            error: Error?
        ) -> Bool {
            guard error == nil, currentDocumentGeneration == documentGeneration else {
                return false
            }

            appliedInlineImagePayload = inlineImagePayload
            return true
        }

        @discardableResult
        func completeContentNavigationSync(requestID: Int, documentGeneration: Int, error: Error?) -> Bool {
            guard error == nil,
                  currentDocumentGeneration == documentGeneration,
                  pendingContentNavigationState.matches(id: requestID) else {
                return false
            }

            pendingContentNavigationState.clearAction?()
            clearPendingContentNavigationRequest()
            clearPendingScroll()
            return true
        }

        @discardableResult
        func completeScrollSync(requestID: Int, documentGeneration: Int, error: Error?) -> Bool {
            guard error == nil,
                  currentDocumentGeneration == documentGeneration,
                  pendingScrollState.matches(id: requestID) else {
                return false
            }

            pendingScrollState.clearAction?()
            clearPendingScroll()
            return true
        }

        private func assignPendingScroll(_ request: ScrollRequest, source: PendingScrollSource) {
            pendingScrollState.replace(with: request, id: makePendingRequestID())
            pendingScrollSource = source
        }

        private func assignPendingContentNavigationRequest(_ request: ContentNavigationRequest) {
            pendingContentNavigationState.replace(with: request, id: makePendingRequestID())
        }

        private func makePendingRequestID() -> Int {
            let requestID = nextPendingRequestID
            nextPendingRequestID += 1
            return requestID
        }

        private func makeNavigationLoadID() -> Int {
            let navigationLoadID = nextNavigationLoadID
            nextNavigationLoadID += 1
            return navigationLoadID
        }

        @discardableResult
        func completeDocumentLoadIfCurrent(navigationLoadID: Int, documentGeneration: Int) -> Bool {
            guard currentDocumentGeneration == documentGeneration,
                  activeNavigationLoadID == navigationLoadID,
                  activeNavigationDocumentGeneration == documentGeneration else {
                return false
            }

            acceptedBridgeDocumentToken = currentDocumentTokenStorage
            isContentLoaded = true
            return true
        }

        func shouldAcceptBridgeMessage(documentToken: String?) -> Bool {
            isContentLoaded && documentToken == acceptedBridgeDocumentToken
        }

        private func clearPendingInjections(
            markerSnapshot: [MarkerInjection],
            imageMarkerSnapshot: [ImageMarkerInjection]
        ) {
            guard !markerSnapshot.isEmpty || !imageMarkerSnapshot.isEmpty else {
                return
            }

            DispatchQueue.main.async {
                if !markerSnapshot.isEmpty {
                    self.parent.pendingMarkerInjections.removeAll { item in
                        markerSnapshot.contains(where: { $0 == item })
                    }
                }

                if !imageMarkerSnapshot.isEmpty {
                    self.parent.pendingImageMarkerInjections.removeAll { item in
                        imageMarkerSnapshot.contains(where: { $0 == item })
                    }
                }
            }
        }

        private func javaScriptInvocation<Payload: Encodable>(function: String, payload: Payload) -> String? {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return "\(function)(\(json));"
        }

        func applyScrollRequest(_ request: ScrollRequest, on webView: WKWebView, completion: ((Error?) -> Void)? = nil) {
            webView.evaluateJavaScript(request.javaScript) { _, error in
                completion?(error)
            }
        }

        func applyContentNavigationRequest(_ request: ContentNavigationRequest, on webView: WKWebView, completion: ((Error?) -> Void)? = nil) {
            webView.evaluateJavaScript(request.javaScript) { _, error in
                completion?(error)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation,
                  let navigationLoadID = navigationLoadIDsByObjectIdentifier.removeValue(forKey: ObjectIdentifier(navigation)),
                  let documentGeneration = activeNavigationDocumentGeneration,
                  completeDocumentLoadIfCurrent(
                    navigationLoadID: navigationLoadID,
                    documentGeneration: documentGeneration
                  ) else {
                return
            }

            flush(on: webView, triggerInitialScrollReport: true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            guard shouldAcceptBridgeMessage(documentToken: body["documentToken"] as? String) else {
                return
            }

            switch type {
            case "annotationClick":
                if let id = (body["id"] as? String).flatMap(Int64.init),
                   let annotation = parent.annotations.first(where: { $0.id == id }) {
                    parent.onAnnotationClick(annotation)
                }
            case "imageMarkerClick":
                if let id = (body["id"] as? String).flatMap(Int64.init) {
                    parent.onImageMarkerClick(id)
                }
            case "imageMarkerDblClick":
                if let id = (body["id"] as? String).flatMap(Int64.init) {
                    parent.onImageMarkerDblClick(id)
                }
            case "explain":
                if let word = body["word"] as? String,
                   let context = body["context"] as? String,
                   let blockId = body["blockId"] as? Int {
                    parent.onWordClick(word, context, blockId, .explain)
                }
            case "generateImage":
                if let word = body["word"] as? String,
                   let context = body["context"] as? String,
                   let blockId = body["blockId"] as? Int {
                    parent.onWordClick(word, context, blockId, .generateImage)
                }
            case "bottomTug":
                parent.onBottomTug()
            case "markersUpdated":
                if let stationsData = body["stations"] as? [[String: Any]] {
                    let markers = stationsData.compactMap { data -> MarkerInfo? in
                        guard let id = data["id"] as? String,
                              let type = data["type"] as? String,
                              let y = data["y"] as? Double,
                              let blockId = data["blockId"] as? Int else {
                            return nil
                        }

                        return MarkerInfo(id: id, type: type, y: y, blockId: blockId)
                    }
                    parent.onMarkersUpdated(markers)
                }
            case "chapterNavigation":
                if let path = body["path"] as? String {
                    parent.onChapterNavigationRequest?(path, body["anchor"] as? String)
                }
            case "scrollPosition":
                let annotationId = (body["annotationId"] as? String).flatMap(Int64.init)
                let imageId = (body["imageId"] as? String).flatMap(Int64.init)
                let footnoteRefId = body["footnoteRefId"] as? String
                let blockId = body["blockId"] as? Int
                let blockOffset = (body["blockOffset"] as? Double) ?? (body["blockOffset"] as? Int).map(Double.init)
                let primaryType = body["primaryType"] as? String
                let scrollOffset = (body["scrollY"] as? Double) ?? 0
                let scrollPercent = (body["scrollPercent"] as? Double) ?? 0
                let viewportHeight = (body["viewportHeight"] as? Double) ?? 0
                let scrollHeight = (body["scrollHeight"] as? Double) ?? 0
                let isProgrammatic = (body["isProgrammatic"] as? Bool) ?? false

                lastScrollOffset = scrollOffset
                lastScrollPercent = scrollPercent

                parent.onScrollPositionChange(.init(
                    annotationId: annotationId,
                    imageId: imageId,
                    footnoteRefId: footnoteRefId,
                    blockId: blockId,
                    blockOffset: blockOffset,
                    primaryType: primaryType,
                    scrollPercent: scrollPercent,
                    scrollOffset: scrollOffset,
                    viewportHeight: viewportHeight,
                    scrollHeight: scrollHeight,
                    isProgrammatic: isProgrammatic
                ))
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.isFileURL {
                let publicationRoot = LibraryPaths.publicationDirectory(for: parent.chapter.bookId)
                let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let standardizedRoot = publicationRoot.standardizedFileURL.resolvingSymlinksInPath()
                let standardizedRendered = parent.renderedChapterURL().standardizedFileURL.resolvingSymlinksInPath()

                let urlPath = standardizedURL.path
                let rootPath = standardizedRoot.path
                let renderedPath = standardizedRendered.path
                let rootPathWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

                guard urlPath.hasPrefix(rootPathWithSlash) || urlPath == rootPath else {
                    decisionHandler(.cancel)
                    return
                }

                if urlPath == renderedPath {
                    decisionHandler(.allow)
                    return
                }

                if navigationAction.navigationType == .linkActivated {
                    var relativePath = String(urlPath.dropFirst(rootPath.count))
                    if relativePath.hasPrefix("/") {
                        relativePath.removeFirst()
                    }

                    relativePath = relativePath.removingPercentEncoding ?? relativePath
                    if relativePath.components(separatedBy: "/").contains("..") {
                        decisionHandler(.cancel)
                        return
                    }

                    parent.onChapterNavigationRequest?(relativePath, url.fragment)
                    decisionHandler(.cancel)
                    return
                }

                decisionHandler(.allow)
                return
            }

            if url.scheme == nil || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "http" || url.scheme == "https" {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

extension Color {
    var hexString: String {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(rgbColor.redComponent * 255),
            Int(rgbColor.greenComponent * 255),
            Int(rgbColor.blueComponent * 255)
        )
    }
}
