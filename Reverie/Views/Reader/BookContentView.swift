import SwiftUI
import WebKit
import Foundation

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

struct BookContentView: NSViewRepresentable {
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
        if context.coordinator.currentChapterId != chapter.id || context.coordinator.currentInlineAIImages != inlineSetting {
            context.coordinator.currentChapterId = chapter.id
            context.coordinator.currentInlineAIImages = inlineSetting
            context.coordinator.isContentLoaded = false
            let html = buildHTML()
            loadHTML(html, on: webView, coordinator: context.coordinator)
        }

        if let id = scrollToAnnotationId {
            webView.evaluateJavaScript("scrollToAnnotation(\(id));") { _, _ in 
                DispatchQueue.main.async { self.scrollToAnnotationId = nil }
            }
        }
        if let quote = scrollToQuote {
            let escaped = quote.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("scrollToQuote('\(escaped)');") { _, _ in 
                DispatchQueue.main.async { self.scrollToQuote = nil }
            }
        }
        if let (blockId, markerId, type) = scrollToBlockId {
            let mId = markerId != nil ? "\(markerId!)" : "null"
            let t = type != nil ? "'\(type!)'" : "null"
            webView.evaluateJavaScript("scrollToBlock(\(blockId), \(mId), \(t));") { _, _ in 
                DispatchQueue.main.async { self.scrollToBlockId = nil }
            }
        }
        if let offset = scrollToOffset {
            if context.coordinator.isContentLoaded {
                webView.evaluateJavaScript("scrollToOffset(\(offset));") { _, _ in 
                    DispatchQueue.main.async { self.scrollToOffset = nil }
                }
            } else { context.coordinator.pendingScrollOffset = offset }
        } else if let percent = scrollToPercent {
            if context.coordinator.isContentLoaded {
                webView.evaluateJavaScript("scrollToPercent(\(percent));") { _, _ in 
                    DispatchQueue.main.async { self.scrollToPercent = nil }
                }
            } else { context.coordinator.pendingScrollPercent = percent }
        }

        if !pendingMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            let snapshots = pendingMarkerInjections
            for inj in snapshots { 
                webView.evaluateJavaScript("injectMarkerAtBlock(\(inj.annotationId), \(inj.sourceBlockId));") { _, _ in } 
            } 
            DispatchQueue.main.async { 
                self.pendingMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
            }
        }
        if !pendingImageMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            let snapshots = pendingImageMarkerInjections
            for inj in snapshots { 
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

    private func buildHTML() -> String {
        let settings = appState.settings
        let blockParser = ContentBlockParser()
        
        // 1. Prepare injections
        var injections: [ContentBlockParser.Injection] = []
        
        for ann in annotations {
            injections.append(.init(kind: .annotation(id: ann.id ?? 0), sourceBlockId: ann.sourceBlockId))
        }
        
        for img in images {
            injections.append(.init(kind: .imageMarker(id: img.id ?? 0), sourceBlockId: img.sourceBlockId))
            if settings.inlineAIImages {
                injections.append(.init(kind: .inlineImage(url: img.imageURL), sourceBlockId: img.sourceBlockId))
            }
        }
        
        // 2. Perform single-pass augmentation
        let content = blockParser.augment(html: chapter.contentHTML, injections: injections)

        let themeBase = theme.base.hexString
        let themeSurface = theme.surface.hexString
        let themeText = theme.text.hexString
        let themeMuted = theme.muted.hexString
        let themeRose = theme.rose.hexString
        let themeIris = theme.iris.hexString
        let fontFamily = settings.fontFamily
        let fontSize = settings.fontSize
        let lineSpacing = settings.lineSpacing
        let baseHref = chapterDirectoryURL().absoluteString
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <base href="\(baseHref)">
            <style>
                :root {
                    --base: \(themeBase);
                    --surface: \(themeSurface);
                    --text: \(themeText);
                    --muted: \(themeMuted);
                    --rose: \(themeRose);
                    --iris: \(themeIris);
                }
                html, body { margin: 0; padding: 0; background: var(--base); color: var(--text); 
                             font-family: "\(fontFamily)", sans-serif; font-size: \(fontSize)px; line-height: \(lineSpacing); }
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
            <script>\(Self.readerBridgeJS)</script>
        </body>
        </html>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cached JavaScript bridge content
    private static let readerBridgeJS: String = {
        let bundleCandidates: [Bundle] = {
            var candidates = [Bundle.main, Bundle(for: Coordinator.self)]
            #if SWIFT_PACKAGE
            candidates.append(Bundle.module)
            #endif
            if let bundleURL = Bundle.main.url(forResource: "Reverie_Reverie", withExtension: "bundle"),
               let b = Bundle(url: bundleURL) {
                candidates.append(b)
            }
            return candidates
        }()
        
        for bundle in bundleCandidates {
            if let url = bundle.url(forResource: "ReaderBridge", withExtension: "js"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        return "console.error('ReaderBridge.js not found');"
    }()

    private func chapterDirectoryURL() -> URL {
        let root = LibraryPaths.publicationDirectory(for: chapter.bookId)
        if let path = chapter.resourcePath, !path.isEmpty { return root.appendingPathComponent(path).deletingLastPathComponent() }
        return root
    }
    private func readerRootDirectoryURL() -> URL { LibraryPaths.readerRoot }

    private func loadHTML(_ html: String, on webView: WKWebView, coordinator: Coordinator) {
        let fileURL = renderedChapterURL()
        let readerRootURL = readerRootDirectoryURL()
        
        coordinator.loadTask?.cancel()
        coordinator.loadTask = Task { @MainActor in
            let success = await Task.detached(priority: .userInitiated) {
                do {
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
                webView.loadHTMLString(html, baseURL: readerRootURL)
            }
        }
    }

    private func renderedChapterURL() -> URL {
        let renderDir = LibraryPaths.publicationDirectory(for: chapter.bookId).appendingPathComponent("_reader", isDirectory: true)
        let idComponent = chapter.id.map(String.init) ?? "index-\(chapter.index)"
        return renderDir.appendingPathComponent("chapter-\(idComponent).html")
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BookContentView
        var currentChapterId: Int64?
        var currentInlineAIImages: Bool?
        var isContentLoaded = false
        var pendingScrollPercent: Double?
        var pendingScrollOffset: Double?
        var lastScrollPercent: Double?
        var lastScrollOffset: Double?
        var loadTask: Task<Void, Never>?

        init(parent: BookContentView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isContentLoaded = true
            if let o = pendingScrollOffset { 
                webView.evaluateJavaScript("scrollToOffset(\(o))")
                pendingScrollOffset = nil 
            } else if let p = pendingScrollPercent { 
                webView.evaluateJavaScript("scrollToPercent(\(p))")
                pendingScrollPercent = nil 
            }

            if !parent.pendingMarkerInjections.isEmpty {
                let snapshots = parent.pendingMarkerInjections
                for inj in snapshots {
                    webView.evaluateJavaScript("injectMarkerAtBlock(\(inj.annotationId), \(inj.sourceBlockId));") { _, _ in }
                }
                DispatchQueue.main.async { 
                    self.parent.pendingMarkerInjections.removeAll { item in snapshots.contains(where: { $0 == item }) }
                }
            }
            if !parent.pendingImageMarkerInjections.isEmpty {
                let snapshots = parent.pendingImageMarkerInjections
                for inj in snapshots {
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
