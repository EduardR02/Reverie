import SwiftUI
import WebKit

struct BookContentView: NSViewRepresentable {
    let chapter: Chapter
    let annotations: [Annotation]
    let images: [GeneratedImage]
    let onWordClick: (String, String, Int, WordAction) -> Void
    let onAnnotationClick: (Annotation) -> Void
    let onScrollPositionChange: (_ annotationId: Int64?, _ scrollPercent: Double, _ scrollOffset: Double) -> Void
    @Binding var scrollToAnnotationId: Int64?
    @Binding var scrollToPercent: Double?
    @Binding var scrollToOffset: Double?
    @Binding var scrollToQuote: String?

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    enum WordAction {
        case explain
        case generateImage
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "readerBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if chapter changed
        if context.coordinator.currentChapterId != chapter.id {
            context.coordinator.currentChapterId = chapter.id
            context.coordinator.isContentLoaded = false
            let html = buildHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }

        // Scroll to annotation if requested
        if let annotationId = scrollToAnnotationId {
            let js = "scrollToAnnotation(\(annotationId));"
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.async {
                    self.scrollToAnnotationId = nil
                }
            }
        }

        // Scroll to quote if requested (for quizzes)
        if let quote = scrollToQuote {
            let escapedQuote = quote
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let js = "scrollToQuote('\(escapedQuote)');"
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.async {
                    self.scrollToQuote = nil
                }
            }
        }

        if let offset = scrollToOffset {
            context.coordinator.pendingScrollOffset = offset
            if context.coordinator.isContentLoaded {
                let js = "scrollToOffset(\(offset));"
                webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.async {
                        self.scrollToOffset = nil
                    }
                }
                context.coordinator.pendingScrollOffset = nil
            }
        } else if let percent = scrollToPercent {
            context.coordinator.pendingScrollPercent = percent
            if context.coordinator.isContentLoaded {
                let clamped = max(0, min(percent, 1))
                let js = "scrollToPercent(\(clamped));"
                webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.async {
                        self.scrollToPercent = nil
                    }
                }
                context.coordinator.pendingScrollPercent = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Build HTML

    private func buildHTML() -> String {
        let settings = appState.settings

        // Inject annotation markers into content
        var content = chapter.contentHTML
        for annotation in annotations.sorted(by: { $0.sourceOffset > $1.sourceOffset }) {
            content = injectMarker(content, for: annotation)
        }

        // Inject images
        for image in images.sorted(by: { $0.sourceOffset > $1.sourceOffset }) {
            content = injectImage(content, for: image)
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                :root {
                    --base: \(theme.base.hexString);
                    --surface: \(theme.surface.hexString);
                    --text: \(theme.text.hexString);
                    --muted: \(theme.muted.hexString);
                    --rose: \(theme.rose.hexString);
                    --iris: \(theme.iris.hexString);
                }

                * {
                    box-sizing: border-box;
                    -webkit-font-smoothing: antialiased;
                }

                html, body {
                    margin: 0;
                    padding: 0;
                    background: var(--base);
                    color: var(--text);
                    font-family: "\(settings.fontFamily)", -apple-system, sans-serif;
                    font-size: \(settings.fontSize)px;
                    line-height: \(settings.lineSpacing);
                }

                body {
                    padding: 32px 48px;
                    max-width: none;
                    margin: 0;
                }

                h1, h2, h3, h4, h5, h6 {
                    color: var(--text);
                    margin-top: 1.5em;
                    margin-bottom: 0.5em;
                    font-weight: 600;
                }

                h1 { font-size: 1.8em; }
                h2 { font-size: 1.4em; }
                h3 { font-size: 1.2em; }

                p {
                    margin: 1em 0;
                    text-align: justify;
                    hyphens: auto;
                }

                a {
                    color: var(--rose);
                    text-decoration: none;
                }

                blockquote {
                    border-left: 3px solid var(--rose);
                    margin: 1.5em 0;
                    padding-left: 1em;
                    color: var(--muted);
                    font-style: italic;
                }

                /* Annotation marker */
                .annotation-marker {
                    display: inline-block;
                    width: 8px;
                    height: 8px;
                    background: var(--rose);
                    border-radius: 50%;
                    margin-left: 4px;
                    cursor: pointer;
                    opacity: 0.8;
                    transition: all 0.15s ease;
                    vertical-align: middle;
                }

                .annotation-marker:hover {
                    opacity: 1;
                    transform: scale(1.3);
                    box-shadow: 0 0 8px var(--rose);
                }

                /* Inline image */
                .generated-image {
                    width: 100%;
                    margin: 2em 0;
                    border-radius: 8px;
                    box-shadow: 0 4px 20px rgba(0,0,0,0.3);
                }

                /* Selection - WebKit forces ~75% opacity on selection backgrounds.
                   Workaround: Use a brighter/saturated version that looks correct when dimmed */
                ::selection {
                    background-color: #f5d0ce !important;  /* Boosted rose to counter WebKit dimming */
                    color: var(--base) !important;
                }
                ::-webkit-selection {
                    background-color: #f5d0ce !important;  /* Boosted rose to counter WebKit dimming */
                    color: var(--base) !important;
                }
                * {
                    -webkit-tap-highlight-color: var(--rose);
                }

                /* Word popup */
                .word-popup {
                    position: fixed;
                    background: var(--surface);
                    border: 1px solid var(--rose);
                    border-radius: 8px;
                    padding: 8px;
                    display: none;
                    z-index: 1000;
                    box-shadow: 0 4px 20px rgba(0,0,0,0.3);
                }

                .word-popup button {
                    display: block;
                    width: 100%;
                    padding: 8px 12px;
                    margin: 4px 0;
                    background: transparent;
                    border: none;
                    color: var(--text);
                    font-size: 13px;
                    cursor: pointer;
                    border-radius: 4px;
                    text-align: left;
                }

                .word-popup button:hover {
                    background: var(--rose);
                    color: var(--base);
                }
            </style>
        </head>
        <body>
            \(content)

            <div id="wordPopup" class="word-popup">
                <button onclick="handleExplain()">Explain</button>
                <button onclick="handleGenerateImage()">Generate Image</button>
                <button onclick="handleDefine()">Define</button>
            </div>

            <script>
                let selectedWord = '';
                let selectedContext = '';
                let selectedOffset = 0;
                let hadSelectionOnMouseDown = false;

                // Track if we had selection before mousedown (to detect deselect clicks)
                document.addEventListener('mousedown', (e) => {
                    const selection = window.getSelection();
                    hadSelectionOnMouseDown = selection && !selection.isCollapsed && selection.toString().trim().length > 0;

                    // Hide popup when clicking outside
                    if (!e.target.closest('.word-popup')) {
                        document.getElementById('wordPopup').style.display = 'none';
                    }
                });

                // Handle text selection
                document.addEventListener('mouseup', (e) => {
                    // If we had a selection before mousedown, this is a deselect click - don't show popup
                    if (hadSelectionOnMouseDown) {
                        hadSelectionOnMouseDown = false;
                        return;
                    }

                    const selection = window.getSelection();
                    const text = selection.toString().trim();

                    // Only show popup if there's a real new selection
                    if (text && text.length > 0 && !selection.isCollapsed) {
                        selectedWord = text;

                        // Get surrounding context (paragraph)
                        const range = selection.getRangeAt(0);
                        const container = range.startContainer.parentElement;
                        selectedContext = container.textContent || '';

                        // Get offset
                        selectedOffset = getTextOffset(range.startContainer, range.startOffset);

                        // Show popup
                        const popup = document.getElementById('wordPopup');
                        popup.style.left = e.clientX + 'px';
                        popup.style.top = (e.clientY + 10) + 'px';
                        popup.style.display = 'block';
                    }
                });

                function getTextOffset(node, offset) {
                    // Simplified offset calculation
                    return document.body.innerText.indexOf(selectedWord);
                }

                function handleExplain() {
                    webkit.messageHandlers.readerBridge.postMessage({
                        type: 'explain',
                        word: selectedWord,
                        context: selectedContext,
                        offset: selectedOffset
                    });
                    document.getElementById('wordPopup').style.display = 'none';
                }

                function handleGenerateImage() {
                    webkit.messageHandlers.readerBridge.postMessage({
                        type: 'generateImage',
                        word: selectedWord,
                        context: selectedContext,
                        offset: selectedOffset
                    });
                    document.getElementById('wordPopup').style.display = 'none';
                }

                function handleDefine() {
                    webkit.messageHandlers.readerBridge.postMessage({
                        type: 'define',
                        word: selectedWord
                    });
                    document.getElementById('wordPopup').style.display = 'none';
                }

                // Annotation marker click
                document.addEventListener('click', (e) => {
                    if (e.target.classList.contains('annotation-marker')) {
                        const id = e.target.dataset.annotationId;
                        webkit.messageHandlers.readerBridge.postMessage({
                            type: 'annotationClick',
                            id: id
                        });
                    }
                });

                // Scroll tracking
                let lastScrollPosition = 0;
                let scrollTicking = false;
                window.addEventListener('scroll', () => {
                    if (scrollTicking) { return; }
                    scrollTicking = true;

                    window.requestAnimationFrame(() => {
                        const scrollY = window.scrollY;
                        const docHeight = document.documentElement.scrollHeight;
                        const viewportHeight = window.innerHeight;
                        const maxScroll = Math.max(0, docHeight - viewportHeight);
                        const scrollPercent = maxScroll > 0 ? (scrollY / maxScroll) : 0;

                        // Find which annotation marker is closest to viewport center
                        const markers = document.querySelectorAll('.annotation-marker');
                        const viewportCenter = scrollY + viewportHeight / 2;

                        let closestMarker = null;
                        let closestDistance = Infinity;

                        markers.forEach(marker => {
                            const rect = marker.getBoundingClientRect();
                            const markerY = rect.top + scrollY;
                            const distance = Math.abs(markerY - viewportCenter);
                            if (distance < closestDistance) {
                                closestDistance = distance;
                                closestMarker = marker;
                            }
                        });

                        const annotationId = closestMarker && closestDistance < 300
                            ? closestMarker.dataset.annotationId
                            : null;

                        webkit.messageHandlers.readerBridge.postMessage({
                            type: 'scrollPosition',
                            annotationId: annotationId,
                            scrollY: scrollY,
                            scrollPercent: scrollPercent
                        });

                        scrollTicking = false;
                    });
                });

                // Scroll to annotation
                function scrollToAnnotation(annotationId) {
                    const marker = document.querySelector('[data-annotation-id="' + annotationId + '"]');
                    if (marker) {
                        marker.scrollIntoView({ behavior: 'smooth', block: 'center' });

                        // Highlight the marker
                        marker.style.transform = 'scale(2)';
                        marker.style.boxShadow = '0 0 16px var(--rose)';
                        setTimeout(() => {
                            marker.style.transform = '';
                            marker.style.boxShadow = '';
                        }, 1500);

                        // Also highlight the parent paragraph briefly
                        const parent = marker.parentElement;
                        if (parent) {
                            parent.style.backgroundColor = 'rgba(235, 188, 186, 0.2)';  // Rose with opacity
                            parent.style.transition = 'background-color 2s ease';
                            setTimeout(() => {
                                parent.style.backgroundColor = '';
                            }, 100);  // Start fade immediately
                        }
                    }
                }

                // Scroll to offset
                function scrollToPercent(percent) {
                    const docHeight = document.documentElement.scrollHeight;
                    const viewportHeight = window.innerHeight;
                    const maxScroll = Math.max(0, docHeight - viewportHeight);
                    const target = maxScroll * percent;
                    window.scrollTo({ top: target, behavior: 'auto' });
                }

                function scrollToOffset(offset) {
                    window.scrollTo({ top: offset, behavior: 'auto' });
                }

                // Scroll to quote text and highlight it
                function scrollToQuote(quote) {
                    // Find the text in the document
                    const walker = document.createTreeWalker(
                        document.body,
                        NodeFilter.SHOW_TEXT,
                        null,
                        false
                    );

                    let node;
                    while (node = walker.nextNode()) {
                        const idx = node.textContent.indexOf(quote);
                        if (idx !== -1) {
                            // Found it - create a range and scroll to it
                            const range = document.createRange();
                            range.setStart(node, idx);
                            range.setEnd(node, Math.min(idx + quote.length, node.textContent.length));

                            // Create highlight span
                            const highlight = document.createElement('span');
                            highlight.className = 'quote-highlight';
                            highlight.style.cssText = 'background: var(--rose); color: var(--base); border-radius: 2px; transition: background 2s ease;';

                            try {
                                range.surroundContents(highlight);
                                highlight.scrollIntoView({ behavior: 'smooth', block: 'center' });

                                // Fade out highlight
                                setTimeout(() => {
                                    highlight.style.background = 'transparent';
                                    highlight.style.color = 'inherit';
                                }, 100);

                                // Remove highlight span after animation
                                setTimeout(() => {
                                    const text = document.createTextNode(highlight.textContent);
                                    highlight.parentNode.replaceChild(text, highlight);
                                }, 2500);
                            } catch (e) {
                                // If surroundContents fails (crosses element boundaries), just scroll
                                node.parentElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
                            }
                            return;
                        }
                    }
                }
            </script>
        </body>
        </html>
        """
    }

    // MARK: - Inject Markers

    private func injectMarker(_ content: String, for annotation: Annotation) -> String {
        let marker = "<span class=\"annotation-marker\" data-annotation-id=\"\(annotation.id ?? 0)\"></span>"

        // Find the source quote and inject marker after it
        if let range = content.range(of: annotation.sourceQuote) {
            return content.replacingCharacters(
                in: range,
                with: annotation.sourceQuote + marker
            )
        }
        return content
    }

    private func injectImage(_ content: String, for image: GeneratedImage) -> String {
        let imgTag = """
        <img class="generated-image" src="file://\(image.imagePath)" alt="Generated illustration">
        """

        // Find nearby paragraph and inject image after it
        // Simplified: inject at approximate offset
        let index = content.index(content.startIndex, offsetBy: min(image.sourceOffset, content.count - 1))
        if let paragraphEnd = content[index...].range(of: "</p>") {
            return content.replacingCharacters(in: paragraphEnd, with: "</p>" + imgTag)
        }
        return content
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BookContentView
        var currentChapterId: Int64?
        var isContentLoaded = false
        var pendingScrollPercent: Double?
        var pendingScrollOffset: Double?

        init(_ parent: BookContentView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isContentLoaded = true

            if let offset = pendingScrollOffset {
                let js = "scrollToOffset(\(offset));"
                webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.async {
                        self.parent.scrollToOffset = nil
                    }
                }
                pendingScrollOffset = nil
            } else if let percent = pendingScrollPercent {
                let clamped = max(0, min(percent, 1))
                let js = "scrollToPercent(\(clamped));"
                webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.async {
                        self.parent.scrollToPercent = nil
                    }
                }
                pendingScrollPercent = nil
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "explain":
                if let word = body["word"] as? String,
                   let context = body["context"] as? String,
                   let offset = body["offset"] as? Int {
                    parent.onWordClick(word, context, offset, .explain)
                }

            case "generateImage":
                if let word = body["word"] as? String,
                   let context = body["context"] as? String,
                   let offset = body["offset"] as? Int {
                    parent.onWordClick(word, context, offset, .generateImage)
                }

            case "define":
                if let word = body["word"] as? String {
                    // Use macOS Dictionary
                    NSWorkspace.shared.open(
                        URL(string: "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)")!
                    )
                }

            case "annotationClick":
                if let idString = body["id"] as? String,
                   let id = Int64(idString),
                   let annotation = parent.annotations.first(where: { $0.id == id }) {
                    parent.onAnnotationClick(annotation)
                }

            case "scrollPosition":
                let annotationId: Int64?
                if let idString = body["annotationId"] as? String,
                   let id = Int64(idString) {
                    annotationId = id
                } else {
                    annotationId = nil
                }

                let scrollY = (body["scrollY"] as? Double) ?? (body["scrollY"] as? NSNumber)?.doubleValue ?? 0
                let scrollPercent = (body["scrollPercent"] as? Double) ?? (body["scrollPercent"] as? NSNumber)?.doubleValue ?? 0
                parent.onScrollPositionChange(annotationId, scrollPercent, scrollY)

            default:
                break
            }
        }
    }
}

// MARK: - Color to Hex

extension Color {
    var hexString: String {
        let nsColor = NSColor(self)
        // Use sRGB for web-compatible colors
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            // Fallback to deviceRGB
            guard let deviceColor = nsColor.usingColorSpace(.deviceRGB) else {
                return "#000000"
            }
            let r = Int(deviceColor.redComponent * 255)
            let g = Int(deviceColor.greenComponent * 255)
            let b = Int(deviceColor.blueComponent * 255)
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
