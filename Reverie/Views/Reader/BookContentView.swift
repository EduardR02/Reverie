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

struct BookContentRenderState: Equatable {
    struct InlineImage: Equatable {
        let id: Int64?
        let sourceBlockId: Int
        let imagePath: String
    }

    let chapterId: Int64?
    let inlineAIImagesEnabled: Bool
    let inlineImages: [InlineImage]

    init(chapterId: Int64?, inlineAIImagesEnabled: Bool, images: [GeneratedImage]) {
        self.chapterId = chapterId
        self.inlineAIImagesEnabled = inlineAIImagesEnabled

        guard inlineAIImagesEnabled else {
            self.inlineImages = []
            return
        }

        self.inlineImages = images.compactMap { image in
            guard image.status == .success else {
                return nil
            }

            return InlineImage(
                id: image.id,
                sourceBlockId: image.sourceBlockId,
                imagePath: image.imagePath
            )
        }
    }
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

                /* Link styling - themed to match Rose Pine */
                a { color: var(--rose); text-decoration: none; transition: color 0.15s ease, opacity 0.15s ease; }
                a:hover { opacity: 0.8; text-decoration: underline; text-underline-offset: 2px; }
                a:visited { color: var(--rose); opacity: 0.85; }

                /* Highlight animations */
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
            <script>\(input.readerBridgeJS)</script>
        </body>
        </html>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BookContentView: NSViewRepresentable {
    typealias BindingMutationScheduler = (@escaping () -> Void) -> Void

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
    @Binding var scrollToBlockId: (Int, Int64?, String?)? // blockId, markerId, type
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
        context.coordinator.parent = self
        
        let inlineSetting = appState.settings.inlineAIImages
        let renderState = BookContentRenderState(
            chapterId: chapter.id,
            inlineAIImagesEnabled: inlineSetting,
            images: images
        )
        let hasContentNavigationRequest = scrollToAnnotationId != nil || scrollToQuote != nil || scrollToBlockId != nil

        if context.coordinator.renderState != renderState {
            context.coordinator.renderState = renderState
            context.coordinator.isContentLoaded = false
            context.coordinator.preserveScrollPositionIfNeeded(
                requestedScrollOffset: scrollToOffset,
                requestedScrollPercent: scrollToPercent,
                hasContentNavigationRequest: hasContentNavigationRequest
            )
            loadHTML(on: webView, coordinator: context.coordinator)
        }

        if let navigationRequest = context.coordinator.consumeContentNavigationRequest(
            annotationId: scrollToAnnotationId,
            quote: scrollToQuote,
            block: scrollToBlockId
        ) {
            if context.coordinator.isContentLoaded {
                context.coordinator.applyContentNavigationRequest(navigationRequest, on: webView) {
                    DispatchQueue.main.async { clearContentNavigationRequest(navigationRequest) }
                }
                context.coordinator.clearPendingContentNavigationRequest()
            } else {
                DispatchQueue.main.async { clearContentNavigationRequest(navigationRequest) }
            }
        }
        if discardBlockedExplicitScrollIfNeeded(using: context.coordinator) == nil,
           let requestedScroll = context.coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: scrollToOffset,
            requestedScrollPercent: scrollToPercent
        ) {
            if context.coordinator.isContentLoaded {
                context.coordinator.applyScrollRequest(requestedScroll, on: webView) {
                    scheduleRequestedScrollClear(requestedScroll)
                }
                context.coordinator.clearPendingScroll()
            } else {
                scheduleRequestedScrollClear(requestedScroll)
            }
        }

        if !pendingMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            let snapshots = pendingMarkerInjections
            let injectionsToApply = context.coordinator.markerInjectionsNeedingJavaScript(snapshots)
            context.coordinator.recordRenderedMarkers(snapshots)
            for inj in injectionsToApply {
                webView.evaluateJavaScript("injectMarkerAtBlock(\(inj.annotationId), \(inj.sourceBlockId));") { _, _ in }
            }
            DispatchQueue.main.async {
                self.pendingMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
            }
        }
        if !pendingImageMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            let snapshots = pendingImageMarkerInjections
            let injectionsToApply = context.coordinator.imageMarkerInjectionsNeedingJavaScript(snapshots)
            context.coordinator.recordRenderedImageMarkers(snapshots)
            for inj in injectionsToApply {
                webView.evaluateJavaScript("injectImageMarker(\(inj.imageId), \(inj.sourceBlockId));") { _, _ in }
            }
            DispatchQueue.main.async {
                self.pendingImageMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
            }
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

    func makeHTMLRenderInput() -> BookContentHTMLBuilder.RenderInput {
        let settings = appState.settings
        var injections: [BookContentHTMLBuilder.RenderInput.Injection] = []

        for ann in annotations {
            injections.append(.init(kind: .annotation(id: ann.id ?? 0), sourceBlockId: ann.sourceBlockId))
        }

        for img in images {
            injections.append(.init(kind: .imageMarker(id: img.id ?? 0), sourceBlockId: img.sourceBlockId))
            if settings.inlineAIImages && img.status == .success {
                injections.append(.init(kind: .inlineImage(url: img.imageURL), sourceBlockId: img.sourceBlockId))
            }
        }

        return BookContentHTMLBuilder.RenderInput(
            contentHTML: chapter.contentHTML,
            injections: injections,
            themeBase: theme.base.hexString,
            themeSurface: theme.surface.hexString,
            themeText: theme.text.hexString,
            themeMuted: theme.muted.hexString,
            themeRose: theme.rose.hexString,
            themeIris: theme.iris.hexString,
            fontFamily: settings.fontFamily,
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            baseHref: chapterDirectoryURL().absoluteString,
            readerBridgeJS: Self.readerBridgeJS
        )
    }

    /// Cached JavaScript bridge content
    private static let readerBridgeJS = ReaderBridgeScriptLoader.load()

    private func chapterDirectoryURL() -> URL {
        let root = LibraryPaths.publicationDirectory(for: chapter.bookId)
        if let path = chapter.resourcePath, !path.isEmpty { return root.appendingPathComponent(path).deletingLastPathComponent() }
        return root
    }
    private func readerRootDirectoryURL() -> URL { LibraryPaths.readerRoot }

    private func loadHTML(on webView: WKWebView, coordinator: Coordinator) {
        let renderInput = makeHTMLRenderInput()
        let fileURL = renderedChapterURL()
        let readerRootURL = readerRootDirectoryURL()

        coordinator.recordRenderedContent(
            annotationIDs: Set(annotations.compactMap(\.id)),
            imageIDs: Set(images.compactMap(\.id))
        )
        
        coordinator.loadTask?.cancel()
        coordinator.loadTask = Task { @MainActor in
            let success = await Task.detached(priority: .userInitiated) {
                do {
                    let html = BookContentHTMLBuilder.buildHTML(from: renderInput)
                    try LibraryPaths.ensureDirectory(fileURL.deletingLastPathComponent())
                    try html.write(to: fileURL, atomically: true, encoding: .utf8)
                    return true
                } catch {
                    return false
                }
            }.value

            if Task.isCancelled { return }
            
            if success {
                webView.loadFileURL(fileURL, allowingReadAccessTo: readerRootURL)
            } else {
                let html = await Task.detached(priority: .userInitiated) {
                    BookContentHTMLBuilder.buildHTML(from: renderInput)
                }.value

                if Task.isCancelled { return }
                webView.loadHTMLString(html, baseURL: readerRootURL)
            }
        }
    }

    private func renderedChapterURL() -> URL {
        let renderDir = LibraryPaths.publicationDirectory(for: chapter.bookId).appendingPathComponent("_reader", isDirectory: true)
        let idComponent = chapter.id.map(String.init) ?? "index-\(chapter.index)"
        return renderDir.appendingPathComponent("chapter-\(idComponent).html")
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

        var parent: BookContentView
        var renderState: BookContentRenderState?
        var isContentLoaded = false
        var pendingScroll: ScrollRequest?
        var pendingScrollSource: PendingScrollSource?
        var lastScrollPercent: Double?
        var lastScrollOffset: Double?
        var loadTask: Task<Void, Never>?
        var pendingContentNavigationRequest: ContentNavigationRequest?
        private var renderedAnnotationIDs = Set<Int64>()
        private var renderedImageIDs = Set<Int64>()
        private var consumedExplicitScroll: ScrollRequest?
        private var consumedContentNavigationRequest: ContentNavigationRequest?

        init(parent: BookContentView) { self.parent = parent }

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
            pendingContentNavigationRequest = request
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
            pendingScroll = request
            pendingScrollSource = .explicit
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
                pendingScroll = .offset(lastScrollOffset)
                pendingScrollSource = .preserved
                return
            }

            if let lastScrollPercent {
                pendingScroll = .percent(lastScrollPercent)
                pendingScrollSource = .preserved
            }
        }

        func clearPendingScroll() {
            pendingScroll = nil
            pendingScrollSource = nil
        }

        func clearPendingContentNavigationRequest() {
            pendingContentNavigationRequest = nil
        }

        func recordRenderedContent(annotationIDs: Set<Int64>, imageIDs: Set<Int64>) {
            renderedAnnotationIDs = annotationIDs
            renderedImageIDs = imageIDs
        }

        func markerInjectionsNeedingJavaScript(_ injections: [MarkerInjection]) -> [MarkerInjection] {
            injections.filter { !renderedAnnotationIDs.contains($0.annotationId) }
        }

        func imageMarkerInjectionsNeedingJavaScript(_ injections: [ImageMarkerInjection]) -> [ImageMarkerInjection] {
            injections.filter { !renderedImageIDs.contains($0.imageId) }
        }

        func recordRenderedMarkers(_ injections: [MarkerInjection]) {
            for injection in injections {
                renderedAnnotationIDs.insert(injection.annotationId)
            }
        }

        func recordRenderedImageMarkers(_ injections: [ImageMarkerInjection]) {
            for injection in injections {
                renderedImageIDs.insert(injection.imageId)
            }
        }

        func applyScrollRequest(_ request: ScrollRequest, on webView: WKWebView, completion: (() -> Void)? = nil) {
            webView.evaluateJavaScript(request.javaScript) { _, _ in
                completion?()
            }
        }

        func applyContentNavigationRequest(_ request: ContentNavigationRequest, on webView: WKWebView, completion: (() -> Void)? = nil) {
            webView.evaluateJavaScript(request.javaScript) { _, _ in
                completion?()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isContentLoaded = true
            if let pendingContentNavigationRequest {
                applyContentNavigationRequest(pendingContentNavigationRequest, on: webView)
                clearPendingContentNavigationRequest()
                clearPendingScroll()
            } else if let pendingScroll {
                applyScrollRequest(pendingScroll, on: webView)
                clearPendingScroll()
            }

            if !parent.pendingMarkerInjections.isEmpty {
                let snapshots = parent.pendingMarkerInjections
                let injectionsToApply = markerInjectionsNeedingJavaScript(snapshots)
                recordRenderedMarkers(snapshots)
                for inj in injectionsToApply {
                    webView.evaluateJavaScript("injectMarkerAtBlock(\(inj.annotationId), \(inj.sourceBlockId));") { _, _ in }
                }
                DispatchQueue.main.async { 
                    self.parent.pendingMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
                }
            }
            if !parent.pendingImageMarkerInjections.isEmpty {
                let snapshots = parent.pendingImageMarkerInjections
                let injectionsToApply = imageMarkerInjectionsNeedingJavaScript(snapshots)
                recordRenderedImageMarkers(snapshots)
                for inj in injectionsToApply {
                    webView.evaluateJavaScript("injectImageMarker(\(inj.imageId), \(inj.sourceBlockId));") { _, _ in }
                }
                DispatchQueue.main.async { 
                    self.parent.pendingImageMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
                }
            }
            
            // Trigger initial scroll report to ensure dimensions are known immediately
            webView.evaluateJavaScript("window.dispatchEvent(new Event('scroll'));")
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "annotationClick": 
                if let id = (body["id"] as? String).flatMap(Int64.init), let a = parent.annotations.first(where: { $0.id == id }) { 
                    parent.onAnnotationClick(a) 
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
                if let word = body["word"] as? String, let context = body["context"] as? String, let bId = body["blockId"] as? Int {
                    parent.onWordClick(word, context, bId, .explain)
                }
            case "generateImage":
                if let word = body["word"] as? String, let context = body["context"] as? String, let bId = body["blockId" ] as? Int {
                    parent.onWordClick(word, context, bId, .generateImage)
                }
            case "bottomTug": parent.onBottomTug()
            case "markersUpdated":
                if let stationsData = body["stations"] as? [[String: Any]] {
                    let markers = stationsData.compactMap { d -> MarkerInfo? in
                        guard let id = d["id"] as? String,
                              let type = d["type"] as? String,
                              let y = d["y"] as? Double,
                              let blockId = d["blockId"] as? Int else { return nil }
                        return MarkerInfo(id: id, type: type, y: y, blockId: blockId)
                    }
                    parent.onMarkersUpdated(markers)
                }
            case "chapterNavigation":
                if let path = body["path"] as? String {
                    let anchor = body["anchor"] as? String
                    parent.onChapterNavigationRequest?(path, anchor)
                }
            case "scrollPosition":
                let aId = (body["annotationId"] as? String).flatMap(Int64.init)
                let iId = (body["imageId"] as? String).flatMap(Int64.init)
                let fId = body["footnoteRefId"] as? String
                let bId = body["blockId"] as? Int
                let bOffset = (body["blockOffset"] as? Double) ?? (body["blockOffset"] as? Int).map(Double.init)
                let pT = body["primaryType"] as? String
                let sY = (body["scrollY"] as? Double) ?? 0
                let sP = (body["scrollPercent"] as? Double) ?? 0
                let vH = (body["viewportHeight"] as? Double) ?? 0
                let sH = (body["scrollHeight"] as? Double) ?? 0
                let isP = (body["isProgrammatic"] as? Bool) ?? false

                lastScrollOffset = sY
                lastScrollPercent = sP
                
                let context = ScrollContext(
                    annotationId: aId,
                    imageId: iId,
                    footnoteRefId: fId,
                    blockId: bId,
                    blockOffset: bOffset,
                    primaryType: pT,
                    scrollPercent: sP,
                    scrollOffset: sY,
                    viewportHeight: vH,
                    scrollHeight: sH,
                    isProgrammatic: isP
                )
                parent.onScrollPositionChange(context)
            default: break
            }
        }

        // Intercept link navigation
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Intercept internal EPUB links (they will be file:// URLs pointing to the publication directory)
            if url.isFileURL {
                let publicationRoot = LibraryPaths.publicationDirectory(for: parent.chapter.bookId)
                let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let standardizedRoot = publicationRoot.standardizedFileURL.resolvingSymlinksInPath()
                let standardizedRendered = parent.renderedChapterURL().standardizedFileURL.resolvingSymlinksInPath()

                let urlPath = standardizedURL.path
                let rootPath = standardizedRoot.path
                let renderedPath = standardizedRendered.path

                // Security check: ensure the URL is within the publication directory
                let rootPathWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard urlPath.hasPrefix(rootPathWithSlash) || urlPath == rootPath else {
                    decisionHandler(.cancel)
                    return
                }

                // If it's the RENDERED HTML file, allow it (same-document anchor)
                if urlPath == renderedPath {
                    decisionHandler(.allow)
                    return
                }

                // If it's a link activation, it's an internal chapter link
                if navigationAction.navigationType == .linkActivated {
                    var relativePath = String(urlPath.dropFirst(rootPath.count))
                    if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                    
                    // Decode URL-encoded path
                    relativePath = relativePath.removingPercentEncoding ?? relativePath
                    
                    // Security check: ensure no path traversal components remain
                    if relativePath.components(separatedBy: "/").contains("..") {
                        decisionHandler(.cancel)
                        return
                    }

                    let anchor = url.fragment
                    parent.onChapterNavigationRequest?(relativePath, anchor)
                    decisionHandler(.cancel)
                    return
                }
                
                // Allow other file URLs (images, styles, or non-link navigations like initial load)
                decisionHandler(.allow)
                return
            }

            // Allow same-document anchor navigation (handled by browser)
            if url.scheme == nil || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            // Block external http/https URLs - don't navigate away from reader
            if url.scheme == "http" || url.scheme == "https" {
                decisionHandler(.cancel)
                return
            }

            // Allow other navigation (e.g., javascript:)
            decisionHandler(.allow)
        }
    }
}

extension Color {
    var hexString: String {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(rgbColor.redComponent * 255), Int(rgbColor.greenComponent * 255), Int(rgbColor.blueComponent * 255))
    }
}
