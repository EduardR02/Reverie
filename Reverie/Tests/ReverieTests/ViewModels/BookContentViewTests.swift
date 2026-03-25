import XCTest
import SwiftUI
@testable import Reverie

private let noScrollOffset: Double? = nil
private let noScrollPercent: Double? = nil
private let noAnnotationId: Int64? = nil
private let noQuote: String? = nil
private let noBlockNavigation: (Int, Int64?, String?)? = nil

/// Helper class to simulate the logic pattern used in BookContentView for marker injections.
/// We use this because testing NSViewRepresentable directly is difficult and prone to flakiness.
class MarkerQueueManager<T: Equatable> {
    var queue: [T] = []
    
    func add(_ item: T) {
        queue.append(item)
    }
    
    func process(injection: ([T]) -> Void) {
        // This simulates the logic in BookContentView.updateNSView:
        // 1. Snapshot current queue
        let snapshots = queue
        
        // 2. Perform "injection" (e.g. webView.evaluateJavaScript)
        injection(snapshots)
        
        // 3. Remove ONLY the processed items from the queue
        // In BookContentView this is done inside DispatchQueue.main.async
        // but for the purpose of testing the logic we can do it here.
        queue.removeAll { item in snapshots.contains(where: { $0 == item }) }
    }
}

final class BookContentViewTests: XCTestCase {
    
    func testMarkerQueueRaceConditionFix() {
        // 1. Initialize manager with some markers [A, B, C]
        let manager = MarkerQueueManager<String>()
        manager.add("A")
        manager.add("B")
        manager.add("C")
        
        XCTAssertEqual(manager.queue, ["A", "B", "C"])
        
        // 2. Start "injection" processing
        manager.process { snapshots in
            XCTAssertEqual(snapshots, ["A", "B", "C"])
            
            // 3. SIMULATE RACE CONDITION:
            // New marker D arrives while we are "processing" A, B, C
            // (In real app, this happens if updateNSView is called again or a binding updates)
            manager.add("D")
            
            XCTAssertEqual(manager.queue, ["A", "B", "C", "D"], "Queue should contain A, B, C and the new D")
        }
        
        // 4. ASSERTION:
        // After processing completes, only A, B, C should be removed.
        // D must remain in the queue.
        XCTAssertEqual(manager.queue, ["D"], "Only processed markers should be removed. D must stay in the queue.")
    }
    
    func testOriginalBugScenario() {
        // This test demonstrates how the bug would behave if we used simple 'removeAll()'
        var queue = ["A", "B", "C"]
        
        // Start processing
        let snapshots = queue
        // ... inject snapshots ...
        
        // Race condition: D arrives
        queue.append("D")
        
        // THE BUG: Clearing everything instead of just processed ones
        // If we did: queue.removeAll()
        let useFixedLogic = true // Set to false to see the bug behavior (conceptually)
        
        if useFixedLogic {
            queue.removeAll { item in snapshots.contains(where: { $0 == item }) }
            XCTAssertEqual(queue, ["D"])
        } else {
            queue.removeAll()
            XCTAssertEqual(queue, []) // D is LOST!
        }
    }
    
    func testMarkerInjectionEquality() {
        // Ensure MarkerInjection Equatable works as expected since the fix depends on it
        let m1 = MarkerInjection(annotationId: 1, sourceBlockId: 10)
        let m2 = MarkerInjection(annotationId: 1, sourceBlockId: 10)
        let m3 = MarkerInjection(annotationId: 2, sourceBlockId: 10)
        
        XCTAssertEqual(m1, m2)
        XCTAssertNotEqual(m1, m3)
    }

    func testImageMarkerInjectionEquality() {
        // Ensure ImageMarkerInjection Equatable works as expected
        let m1 = ImageMarkerInjection(imageId: 1, sourceBlockId: 10)
        let m2 = ImageMarkerInjection(imageId: 1, sourceBlockId: 10)
        let m3 = ImageMarkerInjection(imageId: 2, sourceBlockId: 10)
        
        XCTAssertEqual(m1, m2)
        XCTAssertNotEqual(m1, m3)
    }

    func testBookContentRenderStateChangesWhenInlineImageBecomesSuccessful() {
        let failedState = BookContentRenderState(
            chapterId: 1,
            inlineAIImagesEnabled: true,
            images: [
                GeneratedImage(
                    id: 9,
                    chapterId: 1,
                    excerpt: "Excerpt",
                    prompt: "Prompt",
                    imagePath: "",
                    sourceBlockId: 3,
                    status: .failed,
                    failureReason: "Blocked"
                )
            ]
        )

        let successState = BookContentRenderState(
            chapterId: 1,
            inlineAIImagesEnabled: true,
            images: [
                GeneratedImage(
                    id: 9,
                    chapterId: 1,
                    excerpt: "Excerpt",
                    prompt: "Prompt",
                    imagePath: "/tmp/image.png",
                    sourceBlockId: 3,
                    status: .success
                )
            ]
        )

        XCTAssertNotEqual(failedState, successState)
        XCTAssertTrue(failedState.inlineImages.isEmpty)
        XCTAssertEqual(successState.inlineImages.count, 1)
    }

    func testBookContentRenderStateIgnoresFailedImageOnlyChanges() {
        let original = BookContentRenderState(
            chapterId: 1,
            inlineAIImagesEnabled: true,
            images: [
                GeneratedImage(
                    id: 9,
                    chapterId: 1,
                    excerpt: "Excerpt",
                    prompt: "Prompt",
                    imagePath: "",
                    sourceBlockId: 3,
                    status: .failed,
                    failureReason: "Blocked"
                )
            ]
        )

        let updatedFailure = BookContentRenderState(
            chapterId: 1,
            inlineAIImagesEnabled: true,
            images: [
                GeneratedImage(
                    id: 9,
                    chapterId: 1,
                    excerpt: "Excerpt",
                    prompt: "Prompt",
                    imagePath: "",
                    sourceBlockId: 3,
                    status: .failed,
                    failureReason: "Still blocked"
                )
            ]
        )

        XCTAssertEqual(original, updatedFailure)
    }

    @MainActor
    func testCoordinatorPreservesLastScrollOffsetWhenReloadingContent() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, BookContentView.Coordinator.PendingScrollSource.preserved)
    }

    @MainActor
    func testCoordinatorDoesNotOverrideExplicitScrollRequestWhenReloadingContent() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: 120,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
    }

    @MainActor
    func testCoordinatorKeepsQueuedExplicitScrollAcrossLateReloadPreparation() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)
        coordinator.lastScrollOffset = 120
        coordinator.lastScrollPercent = 0.2

        let request = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 480, requestedScrollPercent: noScrollPercent)
        XCTAssertEqual(request, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, BookContentView.Coordinator.PendingScrollSource.explicit)

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: noScrollPercent)
        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, BookContentView.Coordinator.PendingScrollSource.explicit)
    }

    @MainActor
    func testCoordinatorDoesNotPreserveScrollWhenAnchorNavigationIsQueued() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        let request = coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)

        XCTAssertEqual(request, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))

        coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: noQuote, block: noBlockNavigation)
        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
    }

    @MainActor
    func testCoordinatorSkipsPreservedScrollWhenNewAnchorNavigationArrives() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )
        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.offset(480))

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: true
        )
        let request = coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)

        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(request, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
    }

    @MainActor
    func testCoordinatorClearsPendingExplicitScrollWhenContentNavigationArrives() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)

        let scrollRequest = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 480, requestedScrollPercent: noScrollPercent)
        XCTAssertEqual(scrollRequest, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, BookContentView.Coordinator.PendingScrollSource.explicit)

        let navigationRequest = coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)

        XCTAssertEqual(navigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
    }

    @MainActor
    func testCoordinatorDoesNotQueueExplicitScrollBehindPendingContentNavigation() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)

        let navigationRequest = coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)
        let scrollRequest = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: 0.4)

        XCTAssertEqual(navigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
        XCTAssertNil(scrollRequest)
        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, BookContentView.Coordinator.ContentNavigationRequest.quote("note-1"))
    }

    @MainActor
    func testBlockedExplicitScrollClearIsDeferredWhileContentNavigationPending() {
        var scrollToOffset: Double? = 480
        var scrollToPercent: Double?
        let scheduler = ManualBindingMutationScheduler()
        let view = makeBookContentView(
            scrollToPercent: Binding(
                get: { scrollToPercent },
                set: { scrollToPercent = $0 }
            ),
            scrollToOffset: Binding(
                get: { scrollToOffset },
                set: { scrollToOffset = $0 }
            )
        )
        let coordinator = BookContentView.Coordinator(parent: view)

        coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)

        let discardedScroll = view.discardBlockedExplicitScrollIfNeeded(using: coordinator, scheduler: scheduler.schedule)

        XCTAssertEqual(discardedScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(scrollToOffset, 480)
        XCTAssertNil(scrollToPercent)
        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(scheduler.pendingMutationCount, 1)

        scheduler.runPendingMutations()

        XCTAssertNil(scrollToOffset)
        XCTAssertNil(scrollToPercent)
    }

    @MainActor
    func testDeferredBlockedExplicitScrollClearDoesNotWipeNewBindingValue() {
        var scrollToOffset: Double? = 480
        let scheduler = ManualBindingMutationScheduler()
        let view = makeBookContentView(
            scrollToOffset: Binding(
                get: { scrollToOffset },
                set: { scrollToOffset = $0 }
            )
        )
        let coordinator = BookContentView.Coordinator(parent: view)

        coordinator.consumeContentNavigationRequest(annotationId: noAnnotationId, quote: "note-1", block: noBlockNavigation)

        let discardedScroll = view.discardBlockedExplicitScrollIfNeeded(using: coordinator, scheduler: scheduler.schedule)

        XCTAssertEqual(discardedScroll, BookContentView.Coordinator.ScrollRequest.offset(480))
        XCTAssertEqual(scrollToOffset, 480)

        scrollToOffset = 640
        scheduler.runPendingMutations()

        XCTAssertEqual(scrollToOffset, 640)
    }

    @MainActor
    func testCoordinatorConsumesSameExplicitScrollOnlyOnceUntilBindingClears() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)

        let first = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: 0.4)
        let duplicate = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: 0.4)

        XCTAssertEqual(first, BookContentView.Coordinator.ScrollRequest.percent(0.4))
        XCTAssertNil(duplicate)
        XCTAssertEqual(coordinator.pendingScroll, BookContentView.Coordinator.ScrollRequest.percent(0.4))

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: noScrollPercent)

        let afterClear = coordinator.consumeExplicitScrollRequest(requestedScrollOffset: noScrollOffset, requestedScrollPercent: 0.4)
        XCTAssertEqual(afterClear, BookContentView.Coordinator.ScrollRequest.percent(0.4))
    }

    @MainActor
    func testCoordinatorSkipsQueuedImageMarkerWhenReloadAlreadyRenderedIt() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)

        coordinator.recordRenderedContent(annotationIDs: [], imageIDs: [41])

        let injections = [
            ImageMarkerInjection(imageId: 41, sourceBlockId: 3),
            ImageMarkerInjection(imageId: 42, sourceBlockId: 4)
        ]

        XCTAssertEqual(
            coordinator.imageMarkerInjectionsNeedingJavaScript(injections),
            [ImageMarkerInjection(imageId: 42, sourceBlockId: 4)]
        )

        coordinator.recordRenderedImageMarkers(injections)
        XCTAssertTrue(coordinator.imageMarkerInjectionsNeedingJavaScript(injections).isEmpty)
    }

    @MainActor
    func testCoordinatorSkipsQueuedAnnotationMarkerWhenReloadAlreadyRenderedIt() {
        let view = makeBookContentView()
        let coordinator = BookContentView.Coordinator(parent: view)

        coordinator.recordRenderedContent(annotationIDs: [7], imageIDs: [])

        let injections = [
            MarkerInjection(annotationId: 7, sourceBlockId: 1),
            MarkerInjection(annotationId: 8, sourceBlockId: 2)
        ]

        XCTAssertEqual(
            coordinator.markerInjectionsNeedingJavaScript(injections),
            [MarkerInjection(annotationId: 8, sourceBlockId: 2)]
        )
    }

    func testBuildHTMLIncludesAugmentedContentAndBridgeScript() {
        let html = BookContentHTMLBuilder.buildHTML(from: BookContentHTMLBuilder.RenderInput(
            contentHTML: "<p>Alpha</p>",
            injections: [
                BookContentHTMLBuilder.RenderInput.Injection(kind: .annotation(id: 7), sourceBlockId: 1),
                BookContentHTMLBuilder.RenderInput.Injection(kind: .inlineImage(url: URL(fileURLWithPath: "/tmp/example.png")), sourceBlockId: 1)
            ],
            themeBase: "#191724",
            themeSurface: "#1f1d2e",
            themeText: "#e0def4",
            themeMuted: "#6e6a86",
            themeRose: "#eb6f92",
            themeIris: "#c4a7e7",
            fontFamily: "Georgia",
            fontSize: 18,
            lineSpacing: 1.6,
            baseHref: "file:///tmp/book/",
            readerBridgeJS: "window.__readerBridgeLoaded = true;"
        ))

        XCTAssertTrue(html.contains("<base href=\"file:///tmp/book/\">"))
        XCTAssertTrue(html.contains("<p id=\"block-1\">Alpha<span class=\"annotation-marker\" data-annotation-id=\"7\" data-block-id=\"1\"></span></p><img src=\"example.png\" class=\"generated-image\" data-block-id=\"1\" alt=\"AI Image\">"))
        XCTAssertTrue(html.contains("window.__readerBridgeLoaded = true;"))
    }

    @MainActor
    private func makeBookContentView(
        scrollToPercent: Binding<Double?> = .constant(Optional<Double>.none),
        scrollToOffset: Binding<Double?> = .constant(Optional<Double>.none)
    ) -> BookContentView {
        BookContentView(
            chapter: Chapter(id: 1, bookId: 1, index: 0, title: "Chapter", contentHTML: "<p>Content</p>"),
            annotations: [],
            images: [],
            selectedTab: .insights,
            onWordClick: { _, _, _, _ in },
            onAnnotationClick: { _ in },
            onImageMarkerClick: { _ in },
            onFootnoteClick: { _ in },
            onChapterNavigationRequest: nil,
            onImageMarkerDblClick: { _ in },
            onScrollPositionChange: { _ in },
            onMarkersUpdated: { _ in },
            onBottomTug: {},
            scrollToAnnotationId: .constant(nil),
            scrollToPercent: scrollToPercent,
            scrollToOffset: scrollToOffset,
            scrollToBlockId: .constant(nil),
            scrollToQuote: .constant(nil),
            pendingMarkerInjections: .constant([]),
            pendingImageMarkerInjections: .constant([]),
            scrollByAmount: .constant(nil)
        )
    }
}

@MainActor
private final class ManualBindingMutationScheduler {
    private var pendingMutations: [() -> Void] = []

    var pendingMutationCount: Int {
        pendingMutations.count
    }

    func schedule(_ mutation: @escaping () -> Void) {
        pendingMutations.append(mutation)
    }

    func runPendingMutations() {
        let mutations = pendingMutations
        pendingMutations.removeAll()
        mutations.forEach { $0() }
    }
}
