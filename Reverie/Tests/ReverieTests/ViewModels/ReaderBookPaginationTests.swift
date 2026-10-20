import XCTest
@testable import Reverie

@MainActor
final class ReaderBookPaginationTests: XCTestCase {
    func testBookPositionCountsScreensAcrossChapterBoundaries() {
        let pages = ReaderBookPages(chapterCounts: [2, 3, 1])
        XCTAssertEqual(pages.total, 6)
        XCTAssertEqual(pages.position(chapterIndex: 0, columnIndex: 0, columnsPerScreen: 2), 1)
        XCTAssertEqual(pages.position(chapterIndex: 0, columnIndex: 1, columnsPerScreen: 2), 1)
        XCTAssertEqual(pages.position(chapterIndex: 0, columnIndex: 2, columnsPerScreen: 2), 2)
        XCTAssertEqual(pages.position(chapterIndex: 1, columnIndex: 0, columnsPerScreen: 2), 3)
        XCTAssertEqual(pages.position(chapterIndex: 1, columnIndex: 4, columnsPerScreen: 2), 5)
        XCTAssertEqual(pages.position(chapterIndex: 2, columnIndex: 0, columnsPerScreen: 2), 6)
        XCTAssertNil(pages.position(chapterIndex: 2, columnIndex: 2, columnsPerScreen: 2))
        XCTAssertNil(pages.position(chapterIndex: 0, columnIndex: -1, columnsPerScreen: 2))
        XCTAssertNil(pages.position(chapterIndex: -1, columnIndex: 0, columnsPerScreen: 2))
        XCTAssertNil(pages.position(chapterIndex: 3, columnIndex: 0, columnsPerScreen: 2))
        XCTAssertNil(pages.position(chapterIndex: 0, columnIndex: 0, columnsPerScreen: 0))
        XCTAssertEqual(pages.position(chapterIndex: 1, columnIndex: 2, columnsPerScreen: 1), 5)
    }

    func testOddChapterColumnCountsRoundEachChapterSeparately() async throws {
        let chapters = (0..<3).map { state(chapter: $0) }
        // Injected measurements already return screen counts: ceil(5/2), ceil(1/2).
        let paginator = ReaderBookPaginator { key in
            key.state.document.chapterIndex == 1 ? 3 : 1
        }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        paginator.request(chapters: chapters, current: .init(
            state: chapters[0], viewportWidth: 901, viewportHeight: 601,
            pageCount: 3, pageCapacity: 2
        )) { pages = $0 }
        try await settle { pages != nil }
        XCTAssertEqual(pages?.chapterCounts, [2, 3, 1])
        XCTAssertEqual(pages?.total, 6, "Chapter tails cannot share a screen with the next chapter")
    }

    func testCurrentCapacityReflowChangesScreenCountWithoutUsingTailVisibility() async throws {
        let chapter = state(chapter: 0)
        let paginator = ReaderBookPaginator { _ in
            XCTFail("The current chapter must reuse its visible WebKit measurement")
            return 1
        }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        for (capacity, expected) in [(2, 4), (1, 7), (2, 4)] {
            pages = nil
            paginator.request(chapters: [chapter], current: .init(
                state: chapter, viewportWidth: 901, viewportHeight: 601,
                pageCount: 7, pageCapacity: capacity
            )) { pages = $0 }
            try await settle { pages != nil }
            XCTAssertEqual(pages?.total, expected)
            XCTAssertEqual(
                pages?.position(chapterIndex: 0, columnIndex: 6, columnsPerScreen: capacity),
                expected
            )
        }
    }

    func testCurrentMeasurementReuseAndPageTurnsDoNotRecountOtherChapters() async throws {
        let first = state(chapter: 0)
        let second = state(chapter: 1)
        var calls: [ReaderPaginationKey] = []
        let paginator = ReaderBookPaginator { key in
            calls.append(key)
            return 5
        }
        defer { paginator.cancel() }
        let current = ReaderPaginationMeasurement(state: first, viewportWidth: 900, viewportHeight: 600, pageCount: 3)
        var pages: ReaderBookPages?
        paginator.request(chapters: [first, second], current: current) { pages = $0 }
        try await settle { pages != nil }
        XCTAssertEqual(calls.map(\.state.document.chapterIndex), [1])
        XCTAssertEqual(pages?.total, 8)
        for _ in 0..<10 {
            paginator.request(chapters: [first, second], current: current) { pages = $0 }
        }
        XCTAssertEqual(calls.count, 1)
        let nextChapter = ReaderPaginationMeasurement(state: second, viewportWidth: 900, viewportHeight: 600, pageCount: 5)
        pages = nil
        paginator.request(chapters: [first, second], current: nextChapter) { pages = $0 }
        try await settle { pages != nil }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(pages?.position(chapterIndex: 1, columnIndex: 0, columnsPerScreen: 1), 4)
    }

    func testCachedChapterSwitchPublishesSynchronouslyWithoutClearingKnownTotal() async throws {
        let chapters = [state(chapter: 0), state(chapter: 1)]
        var calls = 0
        let paginator = ReaderBookPaginator { _ in calls += 1; return 5 }
        defer { paginator.cancel() }
        var publications: [ReaderBookPages?] = []
        paginator.request(chapters: chapters, current: .init(
            state: chapters[0], viewportWidth: 900, viewportHeight: 600, pageCount: 3
        )) { publications.append($0) }
        try await settle { (publications.last ?? nil)?.total == 8 }
        publications.removeAll()

        paginator.request(chapters: chapters, current: .init(
            state: chapters[1], viewportWidth: 900, viewportHeight: 600, pageCount: 5
        )) { publications.append($0) }
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(try XCTUnwrap(publications.first ?? nil).total, 8)
        XCTAssertEqual(calls, 1, "Crossing a chapter boundary must not start a new WebKit measurement")
    }

    func testChapterSwitchKeepsInflightWorkerAndSkipsNewVisibleChapter() async throws {
        let chapters = (0..<3).map { state(chapter: $0) }
        var continuations: [CheckedContinuation<Int, Error>] = []
        var measured: [Int] = []
        let paginator = ReaderBookPaginator { key in
            measured.append(key.state.document.chapterIndex)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        paginator.request(chapters: chapters, current: .init(
            state: chapters[0], viewportWidth: 900, viewportHeight: 600, pageCount: 2
        )) { pages = $0 }
        try await settle { continuations.count == 1 }
        paginator.request(chapters: chapters, current: .init(
            state: chapters[2], viewportWidth: 900, viewportHeight: 600, pageCount: 4
        )) { pages = $0 }
        continuations[0].resume(returning: 5)
        try await settle { pages != nil }
        XCTAssertEqual(measured, [1])
        XCTAssertEqual(pages?.chapterCounts, [2, 5, 4])
    }

    func testVisibleMeasurementSupersedesInflightWorkerFailure() async throws {
        let chapters = [state(chapter: 0), state(chapter: 1)]
        var continuation: CheckedContinuation<Int, Error>?
        var workerReturned = false
        let paginator = ReaderBookPaginator { _ in
            defer { workerReturned = true }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        var failures = 0
        var publications = 0
        paginator.request(chapters: chapters, current: .init(
            state: chapters[0], viewportWidth: 900, viewportHeight: 600, pageCount: 2
        ), onFailure: { failures += 1 }) { pages = $0 }
        try await settle { continuation != nil }
        paginator.request(chapters: chapters, current: .init(
            state: chapters[1], viewportWidth: 900, viewportHeight: 600, pageCount: 4
        ), onFailure: { failures += 1 }) { pages = $0; publications += 1 }
        XCTAssertEqual(pages?.total, 6)
        continuation?.resume(throwing: CocoaError(.fileReadNoSuchFile))
        try await settle { workerReturned }
        XCTAssertEqual(publications, 1, "A now-unnecessary worker is cancelled, not allowed to republish")
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(pages?.chapterCounts, [2, 4])
    }

    func testMarkerAndSuccessfulInlineImageChangesRemeasureOnlyChangedChapter() async throws {
        let current = state(chapter: 0)
        var other = state(chapter: 1)
        var calls = 0
        let paginator = ReaderBookPaginator { _ in calls += 1; return 5 }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        func request() {
            pages = nil
            paginator.request(chapters: [current, other], current: .init(
                state: current, viewportWidth: 900, viewportHeight: 600, pageCount: 2
            )) { pages = $0 }
        }
        request()
        try await settle { pages != nil }
        for imageURL in ["file:///one.png", "file:///two.png"] {
            other = .init(
                document: other.document, style: other.style,
                decorations: .init(
                    annotationMarkers: [.init(annotationId: 7, sourceBlockId: 1)],
                    imageMarkers: [.init(imageId: 8, sourceBlockId: 1)],
                    inlineAIImagesEnabled: true,
                    inlineImages: [.init(key: "image-8", imageId: 8, sourceBlockId: 1, imageURL: imageURL)]
                ),
                readingMode: .pages, pageLayout: .spread
            )
            request()
            try await settle { pages != nil }
        }
        XCTAssertEqual(calls, 3)
    }

    func testResizingDiscardsHistoricalGeometryInsteadOfAccumulatingChapterCaches() async throws {
        let first = state(chapter: 0)
        let second = state(chapter: 1)
        var measuredWidths: [Double] = []
        let paginator = ReaderBookPaginator { key in
            measuredWidths.append(key.viewportWidth)
            return 5
        }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        for width in [900.0, 600.0, 900.0] {
            pages = nil
            paginator.request(chapters: [first, second], current: .init(
                state: first, viewportWidth: width, viewportHeight: 600, pageCount: 3
            )) { pages = $0 }
            try await settle { pages != nil }
        }
        XCTAssertEqual(measuredWidths, [900, 600, 900])
        XCTAssertEqual(pages?.total, 8)
    }

    func testTypographyViewportLayoutContentAndInlineImagesInvalidateCachedCounts() async throws {
        var currentState = state(chapter: 0)
        var other = state(chapter: 1)
        var calls = 0
        let paginator = ReaderBookPaginator { _ in calls += 1; return 5 }
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        func request(width: Double = 900) {
            pages = nil
            paginator.request(chapters: [currentState, other], current: .init(
                state: currentState, viewportWidth: width, viewportHeight: 600, pageCount: 3
            )) { pages = $0 }
        }
        request()
        try await settle { pages != nil }
        XCTAssertEqual(calls, 1)
        currentState = state(chapter: 0, fontSize: 24)
        other = state(chapter: 1, fontSize: 24)
        request()
        try await settle { pages != nil }
        XCTAssertEqual(calls, 2)
        request(width: 650)
        try await settle { pages != nil }
        XCTAssertEqual(calls, 3)
        currentState.pageLayout = .single
        other.pageLayout = .single
        request(width: 650)
        try await settle { pages != nil }
        XCTAssertEqual(calls, 4)
        other = state(chapter: 1, fontSize: 24, html: "<p>Changed content</p>", layout: .single)
        request(width: 650)
        try await settle { pages != nil }
        XCTAssertEqual(calls, 5)
        other = state(chapter: 1, fontSize: 24, html: "<p>Changed content</p>", layout: .single, inlineImages: true)
        request(width: 650)
        try await settle { pages != nil }
        XCTAssertEqual(calls, 6)
    }

    func testCancelledGenerationCannotPublishOrPoisonNextLayoutCache() async throws {
        let first = state(chapter: 0)
        let second = state(chapter: 1)
        var continuations: [CheckedContinuation<Int, Error>] = []
        var measured: [ReaderPaginationKey] = []
        let paginator = ReaderBookPaginator { key in
            measured.append(key)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        defer { paginator.cancel() }
        var published: [ReaderBookPages] = []
        paginator.request(chapters: [first, second], current: .init(
            state: first, viewportWidth: 900, viewportHeight: 600, pageCount: 2
        )) { if let result = $0 { published.append(result) } }
        try await settle { continuations.count == 1 }
        paginator.request(chapters: [first, second], current: .init(
            state: first, viewportWidth: 600, viewportHeight: 600, pageCount: 3
        )) { if let result = $0 { published.append(result) } }
        try await settle { continuations.count == 2 }
        continuations[0].resume(returning: 99)
        continuations[1].resume(returning: 4)
        try await settle { !published.isEmpty }
        XCTAssertEqual(published.map(\.total), [7])
        XCTAssertEqual(measured.map(\.viewportWidth), [900, 600])
        paginator.cancel()
        var cached: ReaderBookPages?
        paginator.request(chapters: [first, second], current: .init(
            state: first, viewportWidth: 600, viewportHeight: 600, pageCount: 3
        )) { cached = $0 }
        try await settle { cached != nil }
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(cached?.total, 7)
    }

    func testCurrentFailureSettlesButCancelledFailureCannotOverrideNewGeneration() async throws {
        let first = state(chapter: 0)
        let second = state(chapter: 1)
        var continuations: [CheckedContinuation<Int, Error>] = []
        let paginator = ReaderBookPaginator { _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        defer { paginator.cancel() }
        var failures = 0
        var pages: ReaderBookPages?
        func request(width: Double) {
            paginator.request(chapters: [first, second], current: .init(
                state: first, viewportWidth: width, viewportHeight: 600, pageCount: 2
            ), onFailure: { failures += 1 }) { pages = $0 }
        }
        request(width: 900)
        try await settle { continuations.count == 1 }
        request(width: 600)
        try await settle { continuations.count == 2 }
        continuations[0].resume(throwing: CocoaError(.fileReadNoSuchFile))
        continuations[1].resume(returning: 4)
        try await settle { pages != nil }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(pages?.total, 6)

        request(width: 500)
        XCTAssertNil(pages)
        try await settle { continuations.count == 3 }
        continuations[2].resume(throwing: CocoaError(.fileReadNoSuchFile))
        try await settle { failures == 1 }
        XCTAssertNil(pages)
        request(width: 500)
        XCTAssertEqual(continuations.count, 3, "A failed layout is not automatically retried")
        XCTAssertEqual(failures, 1)
    }

    func testRealWebKitMeasuresAllContentUsingReaderBuilderAndSpreadGeometry() async throws {
        let first = state(chapter: 0)
        let longHTML = (0..<80).map { "<p>Paragraph \($0). " + String(repeating: "A measured reader page contains real text. ", count: 12) + "</p>" }.joined()
        let other = state(chapter: 1, html: longHTML)
        let paginator = ReaderBookPaginator()
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        paginator.request(chapters: [first, other], current: .init(
            state: first, viewportWidth: 900, viewportHeight: 600, pageCount: 1
        )) { pages = $0 }
        try await settle(timeout: 15) { pages != nil }
        let measured = try XCTUnwrap(pages)
        XCTAssertEqual(measured.chapterCounts[0], 1)
        XCTAssertGreaterThan(measured.chapterCounts[1], 2)
        XCTAssertEqual(measured.position(chapterIndex: 1, columnIndex: 0, columnsPerScreen: 2), 2)
        XCTAssertEqual(measured.total, measured.chapterCounts[1] + 1)
    }

    func testRealWebKitRoundsOddColumnsAndUsesActualNarrowFallbackCapacity() async throws {
        let forcedColumns = (0..<7).map { index in
            "<p style=\"\(index == 0 ? "" : "break-before:column;")\">Physical column \(index + 1).</p>"
        }.joined()
        let current = state(chapter: 0)
        let paginator = ReaderBookPaginator()
        defer { paginator.cancel() }
        var pages: ReaderBookPages?
        for (width, layout, expected) in [
            (901.0, ReaderPageLayout.spread, 4),
            (560.0, ReaderPageLayout.spread, 7),
            (901.0, ReaderPageLayout.single, 7),
            (901.0, ReaderPageLayout.spread, 4)
        ] {
            let chapter = state(chapter: 1, html: forcedColumns, layout: layout)
            pages = nil
            paginator.request(chapters: [current, chapter], current: .init(
                state: current, viewportWidth: width, viewportHeight: 601,
                pageCount: 1, pageCapacity: 1
            )) { pages = $0 }
            try await settle(timeout: 15) { pages != nil }
            XCTAssertEqual(pages?.chapterCounts, [1, expected], "\(layout) at \(width) points")
            XCTAssertEqual(pages?.total, expected + 1)
        }
    }

    private func state(chapter: Int, fontSize: Double = 18, html: String = "<p>Text</p>", layout: ReaderPageLayout = .spread, inlineImages: Bool = false) -> BookContentViewState {
        .init(
            document: .init(chapterId: Int64(chapter + 1), chapterIndex: chapter, contentHTML: html, baseHref: LibraryPaths.readerRoot.absoluteString),
            style: .init(themeBase: "#191724", themeSurface: "#1f1d2e", themeText: "#e0def4", themeMuted: "#6e6a86", themeRose: "#ebbcba", themeIris: "#c4a7e7", fontFamily: "Georgia", fontSize: fontSize, lineSpacing: 1.5),
            decorations: .init(annotationMarkers: [], imageMarkers: [], inlineAIImagesEnabled: inlineImages, inlineImages: []),
            readingMode: .pages, pageLayout: layout
        )
    }

    private func settle(timeout: TimeInterval = 2, until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Pagination did not settle")
    }
}
