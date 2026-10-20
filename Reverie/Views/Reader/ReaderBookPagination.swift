import Foundation
import WebKit

struct ReaderPaginationMeasurement: Equatable, Sendable {
    let state: BookContentViewState
    let viewportWidth: Double
    let viewportHeight: Double
    let pageCount: Int
    let pageCapacity: Int

    init(
        state: BookContentViewState, viewportWidth: Double, viewportHeight: Double,
        pageCount: Int, pageCapacity: Int = 1
    ) {
        self.state = state
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.pageCount = pageCount
        self.pageCapacity = pageCapacity
    }
}

struct ReaderPaginationKey: Hashable, Sendable {
    let state: BookContentViewState
    let viewportWidth: Double
    let viewportHeight: Double
}

struct ReaderBookPages: Equatable, Sendable {
    /// Screen counts per chapter; a partial final screen belongs only to its chapter.
    let chapterCounts: [Int]

    var total: Int { chapterCounts.reduce(0, +) }

    func position(chapterIndex: Int, columnIndex: Int, columnsPerScreen: Int) -> Int? {
        guard chapterCounts.indices.contains(chapterIndex),
              columnIndex >= 0, columnsPerScreen > 0 else { return nil }
        let screenIndex = columnIndex / columnsPerScreen
        guard screenIndex < chapterCounts[chapterIndex] else { return nil }
        return chapterCounts.prefix(chapterIndex).reduce(0, +) + screenIndex + 1
    }
}

extension BookContentViewState {
    func htmlRenderInput(readerBridgeJS: String) -> BookContentHTMLBuilder.RenderInput {
        .init(
            contentHTML: document.contentHTML, injections: [],
            themeBase: style.themeBase, themeSurface: style.themeSurface,
            themeText: style.themeText, themeMuted: style.themeMuted,
            themeRose: style.themeRose, themeIris: style.themeIris,
            fontFamily: style.fontFamily, fontSize: style.fontSize,
            lineSpacing: style.lineSpacing, baseHref: document.baseHref,
            documentToken: document.bridgeToken, readerBridgeJS: readerBridgeJS
        )
    }
}

/// Counts screenfuls, with every chapter starting a fresh screen.
@MainActor
final class ReaderBookPaginator {
    /// Returns screen counts, not physical column counts.
    typealias Measure = @MainActor (ReaderPaginationKey) async throws -> Int
    private var cache: [ReaderPaginationKey: Int] = [:]
    private var activeKeys: [ReaderPaginationKey]?
    private var activeCurrent: ReaderPaginationMeasurement?
    private var generation = 0
    private var task: Task<Void, Never>?
    private let worker: ReaderPaginationWebView?
    private let measure: Measure
    private var onFailure: (@MainActor () -> Void)?
    private var onResult: (@MainActor (ReaderBookPages?) -> Void)?

    init(measure: Measure? = nil) {
        if let measure {
            worker = nil
            self.measure = measure
        } else {
            let worker = ReaderPaginationWebView()
            self.worker = worker
            self.measure = { try await worker.measure($0) }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        worker?.cancel()
        activeKeys = nil
        activeCurrent = nil
        onFailure = nil
        onResult = nil
    }

    func request(
        chapters: [BookContentViewState], current: ReaderPaginationMeasurement,
        onFailure: @escaping @MainActor () -> Void = {},
        onResult: @escaping @MainActor (ReaderBookPages?) -> Void
    ) {
        let keys = chapters.map {
            ReaderPaginationKey(state: $0, viewportWidth: current.viewportWidth, viewportHeight: current.viewportHeight)
        }
        guard keys != activeKeys || activeCurrent != current else { return }
        let sameLayout = keys == activeKeys
        if !sameLayout { cancel() }
        activeKeys = keys
        activeCurrent = current
        self.onFailure = onFailure
        self.onResult = onResult
        if !sameLayout {
            let requestedKeys = Set(keys)
            cache = cache.filter { requestedKeys.contains($0.key) }
        }
        let currentKey = ReaderPaginationKey(state: current.state, viewportWidth: current.viewportWidth, viewportHeight: current.viewportHeight)
        if keys.contains(currentKey), current.pageCount > 0 {
            let capacity = max(1, current.pageCapacity)
            cache[currentKey] = current.pageCount / capacity + (current.pageCount % capacity == 0 ? 0 : 1)
        }
        if let pages = cachedPages(for: keys) {
            task?.cancel()
            task = nil
            worker?.cancel()
            onResult(pages)
            return
        }
        // Moving the visible chapter does not invalidate an unchanged book layout or
        // restart its in-flight worker. Keep only the latest publication callbacks.
        guard !sameLayout else { return }
        onResult(nil)
        let expectedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == expectedGeneration { self.task = nil } }
            do {
                for key in keys {
                    try Task.checkCancellation()
                    guard self.cache[key] == nil else { continue }
                    let count = try await self.measure(key)
                    try Task.checkCancellation()
                    guard self.generation == expectedGeneration else { return }
                    // A visible measurement received while WebKit was working is newer.
                    if self.cache[key] == nil {
                        guard count > 0 else { throw CocoaError(.coderInvalidValue) }
                        self.cache[key] = count
                    }
                }
                guard !Task.isCancelled, self.generation == expectedGeneration else { return }
                self.onResult?(self.cachedPages(for: keys))
            } catch {
                guard !Task.isCancelled, self.generation == expectedGeneration else { return }
                if let pages = self.cachedPages(for: keys) {
                    self.onResult?(pages)
                } else {
                    self.onFailure?()
                }
            }
        }
    }

    private func cachedPages(for keys: [ReaderPaginationKey]) -> ReaderBookPages? {
        var counts: [Int] = []
        counts.reserveCapacity(keys.count)
        for key in keys {
            guard let count = cache[key] else { return nil }
            counts.append(count)
        }
        return ReaderBookPages(chapterCounts: counts)
    }
}

@MainActor
private final class ReaderPaginationMessageSink: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}

/// One reusable browser, using exactly the visible reader's builder and bridge phases.
@MainActor
private final class ReaderPaginationWebView: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero)
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var activeNavigation: WKNavigation?
    private var renderedURL: URL?
    private let bridge = ReaderBridgeScriptLoader.load()

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(ReaderPaginationMessageSink(), name: "readerBridge")
    }

    func cancel() {
        webView.stopLoading()
        activeNavigation = nil
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil
        removeRenderedFile()
    }

    func measure(_ key: ReaderPaginationKey) async throws -> Int {
        try Task.checkCancellation()
        webView.frame = CGRect(x: 0, y: 0, width: key.viewportWidth, height: key.viewportHeight)
        let url = LibraryPaths.readerRoot.appendingPathComponent("pagination-\(UUID().uuidString).html")
        try LibraryPaths.ensureDirectory(LibraryPaths.readerRoot)
        let html = BookContentHTMLBuilder.buildHTML(from: key.state.htmlRenderInput(readerBridgeJS: bridge))
        try html.write(to: url, atomically: true, encoding: .utf8)
        removeRenderedFile()
        renderedURL = url
        defer { if renderedURL == url { removeRenderedFile() } }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            activeNavigation = webView.loadFileURL(url, allowingReadAccessTo: LibraryPaths.readerRoot)
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        let markers = String(decoding: try encoder.encode(key.state.decorations.markerPayload), as: UTF8.self)
        let images = String(decoding: try encoder.encode(key.state.decorations.inlineImagePayload), as: UTF8.self)
        let style = String(decoding: try encoder.encode(key.state.style), as: UTF8.self)
        let script = """
        window.applyReaderStyle(\(style));
        window.setPageLayout('\(key.state.pageLayout.rawValue)');
        window.setReadingMode('pages');
        window.syncMarkers(\(markers));
        window.syncInlineImages(\(images));
        const metadata = await window.measurePagination({ offscreen: true });
        return Math.ceil(metadata.pageCount / metadata.pageCapacity);
        """
        let value = try await webView.callAsyncJavaScript(
            script, arguments: [:], in: nil, contentWorld: .page
        )
        guard let count = value as? Int, count > 0 else {
            throw CocoaError(.coderInvalidValue)
        }
        try Task.checkCancellation()
        return count
    }

    private func removeRenderedFile() {
        if let renderedURL { try? FileManager.default.removeItem(at: renderedURL) }
        renderedURL = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        activeNavigation = nil
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishFailure(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishFailure(navigation, error: error)
    }

    private func finishFailure(_ navigation: WKNavigation?, error: Error) {
        guard navigation === activeNavigation else { return }
        activeNavigation = nil
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}
