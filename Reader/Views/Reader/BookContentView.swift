import SwiftUI
import WebKit

struct MarkerInjection: Equatable {
    let annotationId: Int64
    let sourceBlockId: Int
}

struct BookContentView: NSViewRepresentable {
    let chapter: Chapter
    let annotations: [Annotation]
    let images: [GeneratedImage]
    let onWordClick: (String, String, Int, WordAction) -> Void  // word, context, blockId, action
    let onAnnotationClick: (Annotation) -> Void
    let onFootnoteClick: (String) -> Void
    let onScrollPositionChange: (_ annotationId: Int64?, _ footnoteRefId: String?, _ focusType: String?, _ scrollPercent: Double, _ scrollOffset: Double, _ viewportHeight: Double) -> Void
    @Binding var scrollToAnnotationId: Int64?
    @Binding var scrollToPercent: Double?
    @Binding var scrollToOffset: Double?
    @Binding var scrollToBlockId: Int?
    @Binding var scrollToQuote: String?
    @Binding var pendingMarkerInjections: [MarkerInjection]
    @Binding var scrollByAmount: Double?

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
            let chapterBaseURL = chapterDirectoryURL()
            let readerRootURL = readerRootDirectoryURL()
            let html = buildHTML(baseHrefURL: chapterBaseURL)
            webView.loadHTMLString(html, baseURL: readerRootURL)
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

        // Scroll to block if requested (for images/quizzes)
        if let blockId = scrollToBlockId {
            let js = "scrollToBlock(\(blockId));"
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.async {
                    self.scrollToBlockId = nil
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

        // Inject markers for newly generated insights
        if !pendingMarkerInjections.isEmpty && context.coordinator.isContentLoaded {
            for injection in pendingMarkerInjections {
                let js = "injectMarkerAtBlock(\(injection.annotationId), \(injection.sourceBlockId));"
                webView.evaluateJavaScript(js) { _, _ in }
            }
            DispatchQueue.main.async {
                self.pendingMarkerInjections = []
            }
        }

        // Scroll by amount (for arrow key navigation)
        if let amount = scrollByAmount, context.coordinator.isContentLoaded {
            let js = "scrollByPixels(\(amount));"
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.async {
                    self.scrollByAmount = nil
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Build HTML

    private func buildHTML(baseHrefURL: URL) -> String {
        let settings = appState.settings
        let baseHref = baseHrefURL.absoluteString

        // Parse chapter into blocks for injection
        let blockParser = ContentBlockParser()
        let (blocks, _) = blockParser.parse(html: chapter.contentHTML)

        // Inject annotation markers into content using block IDs
        var content = chapter.contentHTML
        // Sort by blockId descending to preserve offsets during injection
        for annotation in annotations.sorted(by: { $0.sourceBlockId > $1.sourceBlockId }) {
            content = injectMarkerAtBlock(content, for: annotation, blocks: blocks)
        }

        // Inject images using block IDs
        for image in images.sorted(by: { $0.sourceBlockId > $1.sourceBlockId }) {
            content = injectImageAtBlock(content, for: image, blocks: blocks, baseURL: baseHrefURL)
        }

        let selectionColor = selectionColorHexString(
            foreground: theme.rose,
            background: theme.base,
            enforcedAlpha: 0.3
        )

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <base href="\(baseHref)">
            <style>
                :root {
                    --base: \(theme.base.hexString);
                    --surface: \(theme.surface.hexString);
                    --text: \(theme.text.hexString);
                    --muted: \(theme.muted.hexString);
                    --rose: \(theme.rose.hexString);
                    --iris: \(theme.iris.hexString);
                    --selection: \(selectionColor);
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

                /* Selection - compensate for WebKit's forced alpha */
                ::selection {
                    background-color: var(--selection) !important;
                    color: var(--text) !important;
                }
                ::-webkit-selection {
                    background-color: var(--selection) !important;
                    color: var(--text) !important;
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
                let selectedBlockId = 0;
                let lastSelectionRange = null;
                const footnoteSelectors = [
                    'a[epub\\\\:type="noteref"]',
                    'a[role="doc-noteref"]',
                    'a[class*="footnote"]',
                    'sup a[href^="#fn"]',
                    'sup a[href^="#note"]',
                    'sup a[href^="#endnote"]',
                    'a[href^="#fn"]',
                    'a[href^="#note"]',
                    'a[href^="#endnote"]'
                ];

                function tagFootnoteRefs() {
                    const refs = new Set();
                    footnoteSelectors.forEach((selector) => {
                        document.querySelectorAll(selector).forEach((link) => refs.add(link));
                    });
                    refs.forEach((link) => link.classList.add('footnote-ref'));
                }

                function getFootnoteRefId(link) {
                    const href = link.getAttribute('href') || '';
                    const hashIndex = href.indexOf('#');
                    if (hashIndex === -1) { return null; }
                    const refId = href.slice(hashIndex + 1);
                    return refId || null;
                }

                document.addEventListener('mousedown', (e) => {
                    // Hide popup when clicking outside
                    if (!e.target.closest('.word-popup')) {
                        document.getElementById('wordPopup').style.display = 'none';
                    }
                });

                // Handle text selection
                document.addEventListener('mouseup', (e) => {
                    const selection = window.getSelection();
                    const text = selection ? selection.toString().trim() : '';

                    if (!selection || selection.isCollapsed || !text) {
                        lastSelectionRange = null;
                        return;
                    }

                    const range = selection.getRangeAt(0);
                    if (lastSelectionRange &&
                        range.startContainer === lastSelectionRange.startNode &&
                        range.startOffset === lastSelectionRange.startOffset &&
                        range.endContainer === lastSelectionRange.endNode &&
                        range.endOffset === lastSelectionRange.endOffset) {
                        return;
                    }

                    lastSelectionRange = {
                        startNode: range.startContainer,
                        startOffset: range.startOffset,
                        endNode: range.endContainer,
                        endOffset: range.endOffset
                    };

                    selectedWord = text;

                    // Get surrounding context (paragraph)
                    const container = range.startContainer.parentElement;
                    selectedContext = container.textContent || '';

                    // Get block ID from nearest marker or estimate from element
                    selectedBlockId = getBlockIdForElement(container);

                    // Show popup
                    const popup = document.getElementById('wordPopup');
                    popup.style.left = e.clientX + 'px';
                    popup.style.top = (e.clientY + 10) + 'px';
                    popup.style.display = 'block';
                });

                tagFootnoteRefs();

                // Find block ID for an element by looking for nearby markers
                function getBlockIdForElement(element) {
                    // Check for data-block-id attribute on the element or ancestors
                    let current = element;
                    while (current && current !== document.body) {
                        const blockId = current.dataset?.blockId;
                        if (blockId) {
                            return parseInt(blockId, 10);
                        }
                        // Check for nearby annotation marker
                        const marker = current.querySelector('.annotation-marker');
                        if (marker && marker.dataset.blockId) {
                            return parseInt(marker.dataset.blockId, 10);
                        }
                        current = current.parentElement;
                    }
                    // Estimate based on paragraph position
                    const paragraphs = document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li');
                    let blockNum = 1;
                    for (const para of paragraphs) {
                        if (para.contains(element) || para === element) {
                            return blockNum;
                        }
                        blockNum++;
                    }
                    return 1;
                }

                function handleExplain() {
                    webkit.messageHandlers.readerBridge.postMessage({
                        type: 'explain',
                        word: selectedWord,
                        context: selectedContext,
                        blockId: selectedBlockId
                    });
                    document.getElementById('wordPopup').style.display = 'none';
                }

                function handleGenerateImage() {
                    webkit.messageHandlers.readerBridge.postMessage({
                        type: 'generateImage',
                        word: selectedWord,
                        context: selectedContext,
                        blockId: selectedBlockId
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
                    const footnoteLink = e.target.closest('a.footnote-ref');
                    if (footnoteLink) {
                        const refId = getFootnoteRefId(footnoteLink);
                        if (refId) {
                            webkit.messageHandlers.readerBridge.postMessage({
                                type: 'footnoteClick',
                                refId: refId
                            });
                        }
                        e.preventDefault();
                        return;
                    }

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

                        // Find which footnote reference is closest to viewport center
                        const footnoteLinks = document.querySelectorAll('.footnote-ref');
                        let closestFootnote = null;
                        let closestFootnoteDistance = Infinity;

                        footnoteLinks.forEach(link => {
                            const rect = link.getBoundingClientRect();
                            const linkY = rect.top + scrollY;
                            const distance = Math.abs(linkY - viewportCenter);
                            if (distance < closestFootnoteDistance) {
                                closestFootnoteDistance = distance;
                                closestFootnote = link;
                            }
                        });

                        const footnoteRefId = closestFootnote && closestFootnoteDistance < 300
                            ? getFootnoteRefId(closestFootnote)
                            : null;

                        let focusType = null;
                        const annotationDistance = annotationId ? closestDistance : Infinity;
                        const footnoteDistance = footnoteRefId ? closestFootnoteDistance : Infinity;
                        if (annotationDistance < footnoteDistance) {
                            focusType = 'annotation';
                        } else if (footnoteDistance < Infinity) {
                            focusType = 'footnote';
                        }

                        webkit.messageHandlers.readerBridge.postMessage({
                            type: 'scrollPosition',
                            annotationId: annotationId,
                            footnoteRefId: footnoteRefId,
                            focusType: focusType,
                            scrollY: scrollY,
                            scrollPercent: scrollPercent,
                            viewportHeight: viewportHeight
                        });

                        scrollTicking = false;
                    });
                });

                // Scroll to annotation - tries marker first, falls back to notifying Swift for quote-based scroll
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
                    } else {
                        // Marker not found - notify Swift to try quote-based scroll
                        webkit.messageHandlers.readerBridge.postMessage({
                            type: 'scrollToAnnotationFailed',
                            annotationId: annotationId
                        });
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

                function scrollByPixels(pixels) {
                    window.scrollBy({ top: pixels, behavior: 'smooth' });
                }

                // Scroll to a specific block by ID
                function scrollToBlock(blockId) {
                    // First try to find a marker with this block ID
                    const marker = document.querySelector('[data-block-id="' + blockId + '"]');
                    if (marker) {
                        marker.scrollIntoView({ behavior: 'smooth', block: 'center' });

                        // Highlight the parent element
                        const parent = marker.parentElement;
                        if (parent) {
                            parent.style.backgroundColor = 'rgba(235, 188, 186, 0.3)';
                            parent.style.transition = 'background-color 2s ease';
                            setTimeout(() => {
                                parent.style.backgroundColor = '';
                            }, 2000);
                        }
                        return;
                    }

                    // Fallback: find the Nth block element
                    const blockElements = document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li');
                    if (blockId > 0 && blockId <= blockElements.length) {
                        const element = blockElements[blockId - 1];
                        element.scrollIntoView({ behavior: 'smooth', block: 'center' });

                        // Add temporary highlight
                        element.style.backgroundColor = 'rgba(235, 188, 186, 0.3)';
                        element.style.transition = 'background-color 2s ease';
                        setTimeout(() => {
                            element.style.backgroundColor = '';
                        }, 2000);
                    }
                }

                // Inject marker at a specific block (for dynamically generated insights)
                function injectMarkerAtBlock(annotationId, blockId) {
                    // Check if marker already exists
                    if (document.querySelector('[data-annotation-id="' + annotationId + '"]')) {
                        return true;
                    }

                    // Find the block element
                    const blockElements = document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li');
                    if (blockId > 0 && blockId <= blockElements.length) {
                        const block = blockElements[blockId - 1];

                        // Create and append marker
                        const markerSpan = document.createElement('span');
                        markerSpan.className = 'annotation-marker';
                        markerSpan.dataset.annotationId = annotationId;
                        markerSpan.dataset.blockId = blockId;
                        block.appendChild(markerSpan);
                        return true;
                    }
                    return false;
                }

                // Scroll to quote text and highlight it
                // Normalize text for matching (collapse whitespace, handle entities)
                function normalizeText(text) {
                    return text
                        .replace(/&nbsp;/g, ' ')
                        .replace(/\\s+/g, ' ')
                        .trim();
                }

                // Find text using various matching strategies
                function findTextInDocument(quote) {
                    const normalizedQuote = normalizeText(quote);
                    const walker = document.createTreeWalker(
                        document.body,
                        NodeFilter.SHOW_TEXT,
                        null,
                        false
                    );

                    // Strategy 1: Exact match
                    walker.currentNode = document.body;
                    let node;
                    while (node = walker.nextNode()) {
                        const idx = node.textContent.indexOf(quote);
                        if (idx !== -1) {
                            return { node, idx, length: quote.length };
                        }
                    }

                    // Strategy 2: Normalized match
                    walker.currentNode = document.body;
                    while (node = walker.nextNode()) {
                        const normalizedContent = normalizeText(node.textContent);
                        const idx = normalizedContent.indexOf(normalizedQuote);
                        if (idx !== -1) {
                            // Find approximate original index
                            const origIdx = node.textContent.indexOf(normalizedQuote.substring(0, 20));
                            if (origIdx !== -1) {
                                return { node, idx: origIdx, length: Math.min(quote.length, node.textContent.length - origIdx) };
                            }
                        }
                    }

                    // Strategy 3: Partial match (first 40 chars)
                    if (quote.length > 40) {
                        const partial = normalizeText(quote.substring(0, 40));
                        walker.currentNode = document.body;
                        while (node = walker.nextNode()) {
                            const normalizedContent = normalizeText(node.textContent);
                            const idx = normalizedContent.indexOf(partial);
                            if (idx !== -1) {
                                const origIdx = node.textContent.search(new RegExp(partial.substring(0, 15).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'i'));
                                if (origIdx !== -1) {
                                    return { node, idx: origIdx, length: Math.min(50, node.textContent.length - origIdx) };
                                }
                            }
                        }
                    }

                    // Strategy 4: First significant words (for very different quotes)
                    const words = normalizedQuote.split(' ').filter(w => w.length > 3).slice(0, 4);
                    if (words.length >= 2) {
                        const searchPattern = words.join('.*?');
                        const regex = new RegExp(searchPattern, 'i');
                        walker.currentNode = document.body;
                        while (node = walker.nextNode()) {
                            const match = node.textContent.match(regex);
                            if (match) {
                                return { node, idx: match.index, length: match[0].length };
                            }
                        }
                    }

                    return null;
                }

                function scrollToQuote(quote) {
                    const found = findTextInDocument(quote);
                    if (!found) {
                        console.log('[ScrollToQuote] Quote not found:', quote.substring(0, 50));
                        return;
                    }

                    const { node, idx, length } = found;

                    // Create a range and scroll to it
                    const range = document.createRange();
                    range.setStart(node, idx);
                    range.setEnd(node, Math.min(idx + length, node.textContent.length));

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
                }

            </script>
        </body>
        </html>
        """
    }

    // MARK: - Block-Based Injection

    private func injectMarkerAtBlock(_ content: String, for annotation: Annotation, blocks: [ContentBlock]) -> String {
        let marker = "<span class=\"annotation-marker\" data-annotation-id=\"\(annotation.id ?? 0)\" data-block-id=\"\(annotation.sourceBlockId)\"></span>"

        // Find the block and inject marker at its end
        guard let block = blocks.first(where: { $0.id == annotation.sourceBlockId }),
              block.htmlEndOffset <= content.count else {
            return content
        }

        let insertIndex = content.index(content.startIndex, offsetBy: block.htmlEndOffset)
        var result = content
        result.insert(contentsOf: marker, at: insertIndex)
        return result
    }

    private func injectImageAtBlock(_ content: String, for image: GeneratedImage, blocks: [ContentBlock], baseURL: URL) -> String {
        let imageURL = URL(fileURLWithPath: image.imagePath)
        let relativePath = relativePath(from: baseURL, to: imageURL) ?? imageURL.path
        let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        let imgTag = """
        <img class="generated-image" data-block-id="\(image.sourceBlockId)" src="\(encodedPath)" alt="Generated illustration">
        """

        // Find the block and inject image after it
        guard let block = blocks.first(where: { $0.id == image.sourceBlockId }),
              block.htmlEndOffset <= content.count else {
            return content
        }

        let insertIndex = content.index(content.startIndex, offsetBy: block.htmlEndOffset)
        var result = content
        result.insert(contentsOf: imgTag, at: insertIndex)
        return result
    }

    private func chapterDirectoryURL() -> URL {
        let publicationRoot = LibraryPaths.publicationDirectory(for: chapter.bookId)
        guard let resourcePath = chapter.resourcePath, !resourcePath.isEmpty else {
            return ensureDirectoryURL(publicationRoot)
        }

        let chapterURL = publicationRoot.appendingPathComponent(resourcePath)
        let baseDir = chapterURL.deletingLastPathComponent()
        return ensureDirectoryURL(baseDir)
    }

    private func readerRootDirectoryURL() -> URL {
        ensureDirectoryURL(LibraryPaths.readerRoot)
    }

    private func ensureDirectoryURL(_ url: URL) -> URL {
        url.hasDirectoryPath ? url : url.appendingPathComponent("", isDirectory: true)
    }

    private func selectionColorHexString(
        foreground: Color,
        background: Color,
        enforcedAlpha: Double = 0.75
    ) -> String {
        let fg = NSColor(foreground).usingColorSpace(.sRGB) ?? NSColor.white
        let bg = NSColor(background).usingColorSpace(.sRGB) ?? NSColor.black
        let alpha = CGFloat(enforcedAlpha)

        func adjust(_ channel: CGFloat, _ base: CGFloat) -> CGFloat {
            guard alpha > 0 else { return channel }
            let value = (channel - (1 - alpha) * base) / alpha
            return min(max(value, 0), 1)
        }

        let r = adjust(fg.redComponent, bg.redComponent)
        let g = adjust(fg.greenComponent, bg.greenComponent)
        let b = adjust(fg.blueComponent, bg.blueComponent)

        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String? {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        guard !baseComponents.isEmpty, !targetComponents.isEmpty else { return nil }

        var index = 0
        while index < baseComponents.count,
              index < targetComponents.count,
              baseComponents[index] == targetComponents[index] {
            index += 1
        }

        if index == 0 {
            return nil
        }

        let upLevels = Array(repeating: "..", count: baseComponents.count - index)
        let downLevels = Array(targetComponents[index...])
        return (upLevels + downLevels).joined(separator: "/")
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
                   let blockId = body["blockId"] as? Int {
                    parent.onWordClick(word, context, blockId, .explain)
                }

            case "generateImage":
                if let word = body["word"] as? String,
                   let context = body["context"] as? String,
                   let blockId = body["blockId"] as? Int {
                    parent.onWordClick(word, context, blockId, .generateImage)
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

            case "scrollToAnnotationFailed":
                // Marker not found, fall back to block-based scroll
                if let annotationId = body["annotationId"] as? Int,
                   let annotation = self.parent.annotations.first(where: { $0.id == Int64(annotationId) }) {
                    DispatchQueue.main.async { [self] in
                        self.parent.scrollToBlockId = annotation.sourceBlockId
                    }
                }

            case "footnoteClick":
                if let refId = body["refId"] as? String {
                    parent.onFootnoteClick(refId)
                }

            case "scrollPosition":
                let annotationId: Int64?
                if let idString = body["annotationId"] as? String,
                   let id = Int64(idString) {
                    annotationId = id
                } else {
                    annotationId = nil
                }

                let footnoteRefId = body["footnoteRefId"] as? String
                let focusType = body["focusType"] as? String
                let scrollY = (body["scrollY"] as? Double) ?? (body["scrollY"] as? NSNumber)?.doubleValue ?? 0
                let scrollPercent = (body["scrollPercent"] as? Double) ?? (body["scrollPercent"] as? NSNumber)?.doubleValue ?? 0
                let viewportHeight = (body["viewportHeight"] as? Double) ?? (body["viewportHeight"] as? NSNumber)?.doubleValue ?? 0
                parent.onScrollPositionChange(annotationId, footnoteRefId, focusType, scrollPercent, scrollY, viewportHeight)

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
