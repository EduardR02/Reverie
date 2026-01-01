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

struct ScrollContext: Equatable {
    let annotationId: Int64?
    let imageId: Int64?
    let footnoteRefId: String?
    let blockId: Int?
    let annotationBlockId: Int?
    let imageBlockId: Int?
    let footnoteBlockId: Int?
    let primaryType: String?
    let annotationDistance: Double
    let imageDistance: Double
    let footnoteDistance: Double
    let scrollPercent: Double
    let scrollOffset: Double
    let viewportHeight: Double
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
    let onImageMarkerDblClick: (Int64) -> Void
    let onScrollPositionChange: (_ context: ScrollContext) -> Void
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
            loadHTML(html, on: webView)
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
            for inj in pendingMarkerInjections { 
                webView.evaluateJavaScript("injectMarkerAtBlock(\(inj.annotationId), \(inj.sourceBlockId));") { _, _ in } 
            } 
            DispatchQueue.main.async { self.pendingMarkerInjections = [] }
        }
        if !pendingImageMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            for inj in pendingImageMarkerInjections { 
                webView.evaluateJavaScript("injectImageMarker(\(inj.imageId), \(inj.sourceBlockId));") { _, _ in } 
            } 
            DispatchQueue.main.async { self.pendingImageMarkerInjections = [] }
        }

        if let amount = scrollByAmount {
            webView.evaluateJavaScript("window.scrollBy({top: \(amount), behavior: 'smooth'});") { _, _ in 
                DispatchQueue.main.async { self.scrollByAmount = nil }
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
                
                /* Highlight animations */
                .highlight-active { transition: background-color 0s !important; }
                .marker-highlight { 
                    transform: scale(1.6) !important;
                    background-color: var(--highlight-color) !important;
                    box-shadow: 0 0 15px 3px var(--highlight-color) !important;
                    z-index: 100 !important;
                    transition: transform 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275), box-shadow 0.4s !important;
                }
                
                @keyframes marker-pulse-anim {
                    0% { transform: scale(1.0); }
                    25% { transform: scale(1.3); box-shadow: 0 0 12px var(--highlight-color); }
                    100% { transform: scale(1.0); }
                }
                .marker-pulse {
                    animation: marker-pulse-anim 0.6s cubic-bezier(0.2, 0.8, 0.2, 1);
                    z-index: 90;
                }
            </style>
        </head>
        <body>
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
            if let bundleURL = Bundle.main.url(forResource: "Reader_Reader", withExtension: "bundle"),
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

    private func loadHTML(_ html: String, on webView: WKWebView) {
        let fileURL = renderedChapterURL()
        let readerRootURL = readerRootDirectoryURL()
        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(fileURL, allowingReadAccessTo: readerRootURL)
        } catch {
            webView.loadHTMLString(html, baseURL: readerRootURL)
        }
    }

    private func renderedChapterURL() -> URL {
        let renderDir = LibraryPaths.publicationDirectory(for: chapter.bookId).appendingPathComponent("_reader", isDirectory: true)
        try? LibraryPaths.ensureDirectory(renderDir)
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
            case "scrollPosition":
                let aId = (body["annotationId"] as? String).flatMap(Int64.init)
                let iId = (body["imageId"] as? String).flatMap(Int64.init)
                let fId = body["footnoteRefId"] as? String
                let bId = body["blockId"] as? Int
                let aD = body["annotationDist"] as? Double ?? .infinity
                let iD = body["imageDist"] as? Double ?? .infinity
                let fD = body["footnoteDist"] as? Double ?? .infinity
                let aB = body["annotationBlockId"] as? Int
                let iB = body["imageBlockId"] as? Int
                let fB = body["footnoteBlockId"] as? Int
                let pT = body["primaryType"] as? String
                let sY = (body["scrollY"] as? Double) ?? 0
                let sP = (body["scrollPercent"] as? Double) ?? 0
                let vH = (body["viewportHeight"] as? Double) ?? 0
                let isP = (body["isProgrammatic"] as? Bool) ?? false
                let context = ScrollContext(
                    annotationId: aId,
                    imageId: iId,
                    footnoteRefId: fId,
                    blockId: bId,
                    annotationBlockId: aB,
                    imageBlockId: iB,
                    footnoteBlockId: fB,
                    primaryType: pT,
                    annotationDistance: aD,
                    imageDistance: iD,
                    footnoteDistance: fD,
                    scrollPercent: sP,
                    scrollOffset: sY,
                    viewportHeight: vH,
                    isProgrammatic: isP
                )
                parent.onScrollPositionChange(context)
            default: break
            }
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
