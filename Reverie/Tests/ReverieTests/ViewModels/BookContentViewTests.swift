import XCTest
import SwiftUI
import WebKit
@testable import Reverie

private let noScrollOffset: Double? = nil
private let noScrollPercent: Double? = nil
private let noAnnotationId: Int64? = nil
private let noQuote: String? = nil
private let noBlockNavigation: (Int, Int64?, String?)? = nil

private final class MarkerQueueManager<T: Equatable> {
    var queue: [T] = []

    func add(_ item: T) {
        queue.append(item)
    }

    func process(injection: ([T]) -> Void) {
        let snapshots = queue
        injection(snapshots)
        queue.removeAll { item in snapshots.contains(where: { $0 == item }) }
    }
}

@MainActor
private final class RecordingWebView: WKWebView {
    private let completionErrors: [Error?]
    private let beforeCompletion: ((Int) -> Void)?
    private(set) var evaluatedScripts: [String] = []

    init(completionErrors: [Error?], beforeCompletion: ((Int) -> Void)? = nil) {
        self.completionErrors = completionErrors
        self.beforeCompletion = beforeCompletion
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
    ) {
        evaluatedScripts.append(javaScriptString)
        guard evaluatedScripts.count <= completionErrors.count else {
            return
        }

        beforeCompletion?(evaluatedScripts.count)
        completionHandler?(nil, completionErrors[evaluatedScripts.count - 1])
    }
}

final class BookContentViewTests: XCTestCase {
    func testMarkerQueueRaceConditionFix() {
        let manager = MarkerQueueManager<String>()
        manager.add("A")
        manager.add("B")
        manager.add("C")

        manager.process { snapshots in
            XCTAssertEqual(snapshots, ["A", "B", "C"])
            manager.add("D")
        }

        XCTAssertEqual(manager.queue, ["D"])
    }

    func testMarkerInjectionEquality() {
        XCTAssertEqual(
            MarkerInjection(annotationId: 1, sourceBlockId: 10),
            MarkerInjection(annotationId: 1, sourceBlockId: 10)
        )
        XCTAssertNotEqual(
            MarkerInjection(annotationId: 1, sourceBlockId: 10),
            MarkerInjection(annotationId: 2, sourceBlockId: 10)
        )
    }

    func testImageMarkerInjectionEquality() {
        XCTAssertEqual(
            ImageMarkerInjection(imageId: 1, sourceBlockId: 10),
            ImageMarkerInjection(imageId: 1, sourceBlockId: 10)
        )
        XCTAssertNotEqual(
            ImageMarkerInjection(imageId: 1, sourceBlockId: 10),
            ImageMarkerInjection(imageId: 2, sourceBlockId: 10)
        )
    }

    @MainActor
    func testCoordinatorPreservesLastScrollOffsetWhenReloadingContent() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertEqual(coordinator.pendingScroll, .offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, .preserved)
    }

    @MainActor
    func testCoordinatorDoesNotOverrideExplicitScrollRequestWhenReloadingContent() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
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
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.lastScrollOffset = 120
        coordinator.lastScrollPercent = 0.2

        let request = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: 480,
            requestedScrollPercent: noScrollPercent
        )
        XCTAssertEqual(request, .offset(480))

        coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent
        )
        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertEqual(coordinator.pendingScroll, .offset(480))
        XCTAssertEqual(coordinator.pendingScrollSource, .explicit)
    }

    @MainActor
    func testCoordinatorDoesNotPreserveScrollWhenAnchorNavigationIsQueued() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        let request = coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )

        XCTAssertEqual(request, .quote("note-1"))

        coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: noQuote,
            block: noBlockNavigation
        )
        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )

        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, .quote("note-1"))
    }

    @MainActor
    func testCoordinatorSkipsPreservedScrollWhenNewAnchorNavigationArrives() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.lastScrollOffset = 480
        coordinator.lastScrollPercent = 0.55

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: false
        )
        XCTAssertEqual(coordinator.pendingScroll, .offset(480))

        coordinator.preserveScrollPositionIfNeeded(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent,
            hasContentNavigationRequest: true
        )

        let request = coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )

        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(request, .quote("note-1"))
    }

    @MainActor
    func testCoordinatorClearsPendingExplicitScrollWhenContentNavigationArrives() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        _ = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: 480,
            requestedScrollPercent: noScrollPercent
        )
        let navigationRequest = coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )

        XCTAssertEqual(navigationRequest, .quote("note-1"))
        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, .quote("note-1"))
    }

    @MainActor
    func testCoordinatorDoesNotQueueExplicitScrollBehindPendingContentNavigation() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        let navigationRequest = coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )
        let scrollRequest = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: 0.4
        )

        XCTAssertEqual(navigationRequest, .quote("note-1"))
        XCTAssertNil(scrollRequest)
        XCTAssertNil(coordinator.pendingScroll)
        XCTAssertNil(coordinator.pendingScrollSource)
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

        coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )

        let discardedScroll = view.discardBlockedExplicitScrollIfNeeded(
            using: coordinator,
            scheduler: scheduler.schedule
        )

        XCTAssertEqual(discardedScroll, .offset(480))
        XCTAssertEqual(scrollToOffset, 480)
        XCTAssertNil(scrollToPercent)
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

        coordinator.consumeContentNavigationRequest(
            annotationId: noAnnotationId,
            quote: "note-1",
            block: noBlockNavigation
        )

        let discardedScroll = view.discardBlockedExplicitScrollIfNeeded(
            using: coordinator,
            scheduler: scheduler.schedule
        )

        XCTAssertEqual(discardedScroll, .offset(480))
        scrollToOffset = 640

        scheduler.runPendingMutations()

        XCTAssertEqual(scrollToOffset, 640)
    }

    @MainActor
    func testCoordinatorConsumesSameExplicitScrollOnlyOnceUntilBindingClears() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        let first = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: 0.4
        )
        let duplicate = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: 0.4
        )

        XCTAssertEqual(first, .percent(0.4))
        XCTAssertNil(duplicate)
        XCTAssertEqual(coordinator.pendingScroll, .percent(0.4))

        coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: noScrollPercent
        )

        let afterClear = coordinator.consumeExplicitScrollRequest(
            requestedScrollOffset: noScrollOffset,
            requestedScrollPercent: 0.4
        )
        XCTAssertEqual(afterClear, .percent(0.4))
    }

    @MainActor
    func testCoordinatorDoesNotCommitStyleWhenJavaScriptFails() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let style = makeStyleState()

        let success = coordinator.completeStyleSync(
            style,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: NSError(domain: "Test", code: 1)
        )

        XCTAssertFalse(success)
        XCTAssertNil(coordinator.appliedStyleForTesting)
    }

    @MainActor
    func testCoordinatorStopsFlushAfterStyleJavaScriptFailureWithoutImmediateRetry() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.isContentLoaded = true
        coordinator.setDesiredState(makeViewState(chapterId: 1, html: "<p>Content</p>"))
        let webView = RecordingWebView(completionErrors: [NSError(domain: "Test", code: 1)])

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertTrue(webView.evaluatedScripts[0].hasPrefix("applyReaderStyle("))
        XCTAssertNil(coordinator.appliedStyleForTesting)

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 2)
    }

    @MainActor
    func testCoordinatorStopsFlushWhenJavaScriptCompletionIsForStaleGeneration() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        coordinator.isContentLoaded = true
        coordinator.setDesiredState(makeViewState(chapterId: 1, html: "<p>Content</p>"))
        let webView = RecordingWebView(completionErrors: [nil]) { evaluationCount in
            guard evaluationCount == 1 else { return }

            let newState = self.makeViewState(chapterId: 2, html: "<p>Next</p>")
            coordinator.prepareForDocumentLoad(
                state: newState,
                requestedScrollOffset: nil,
                requestedScrollPercent: nil,
                hasContentNavigationRequest: false
            )
            coordinator.setDesiredState(newState)
            let loadID = coordinator.registerNavigationLoadForTesting(
                documentGeneration: coordinator.currentDocumentGenerationForTesting
            )
            XCTAssertTrue(coordinator.completeDocumentLoadIfCurrent(
                navigationLoadID: loadID,
                documentGeneration: coordinator.currentDocumentGenerationForTesting
            ))
        }

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertNil(coordinator.appliedStyleForTesting)

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 2)
    }

    @MainActor
    func testCoordinatorDoesNotCommitStyleAcrossDocumentReload() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let style = makeStyleState()
        let originalGeneration = coordinator.currentDocumentGenerationForTesting

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Next</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        let success = coordinator.completeStyleSync(
            style,
            documentGeneration: originalGeneration,
            error: nil
        )

        XCTAssertFalse(success)
        XCTAssertNil(coordinator.appliedStyleForTesting)
    }

    @MainActor
    func testCoordinatorDoesNotCommitDecorationsWhenJavaScriptFails() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let decorations = makeDecorationState()

        let success = coordinator.completeDecorationSync(
            decorations,
            markerSnapshot: [MarkerInjection(annotationId: 8, sourceBlockId: 4)],
            imageMarkerSnapshot: [ImageMarkerInjection(imageId: 10, sourceBlockId: 5)],
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: NSError(domain: "Test", code: 2)
        )

        XCTAssertFalse(success)
        XCTAssertEqual(coordinator.appliedDecorationsForTesting, .empty)
    }

    @MainActor
    func testCoordinatorDoesNotCommitDecorationsAcrossDocumentReload() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let decorations = makeDecorationState()
        let originalGeneration = coordinator.currentDocumentGenerationForTesting

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Next</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        let success = coordinator.completeDecorationSync(
            decorations,
            markerSnapshot: [],
            imageMarkerSnapshot: [],
            documentGeneration: originalGeneration,
            error: nil
        )

        XCTAssertFalse(success)
        XCTAssertEqual(coordinator.appliedDecorationsForTesting, .empty)
    }

    @MainActor
    func testCoordinatorKeepsPendingNavigationWhenJavaScriptFails() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClear = false

        coordinator.consumeContentNavigationRequest(annotationId: nil, quote: "note-1", block: nil)
        coordinator.pendingContentNavigationClearAction = { didClear = true }
        let requestID = try XCTUnwrap(coordinator.pendingContentNavigationRequestIDForTesting)

        let success = coordinator.completeContentNavigationSync(
            requestID: requestID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: NSError(domain: "Test", code: 3)
        )

        XCTAssertFalse(success)
        XCTAssertFalse(didClear)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, .quote("note-1"))
    }

    @MainActor
    func testCoordinatorKeepsPendingScrollWhenJavaScriptFails() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClear = false

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 240, requestedScrollPercent: nil)
        coordinator.pendingScrollClearAction = { didClear = true }
        let requestID = try XCTUnwrap(coordinator.pendingScrollRequestIDForTesting)

        let success = coordinator.completeScrollSync(
            requestID: requestID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: NSError(domain: "Test", code: 4)
        )

        XCTAssertFalse(success)
        XCTAssertFalse(didClear)
        XCTAssertEqual(coordinator.pendingScroll, .offset(240))
    }

    @MainActor
    func testCoordinatorStopsFlushAfterScrollJavaScriptFailureWithoutImmediateRetry() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let state = makeViewState(chapterId: 1, html: "<p>Content</p>")
        var didClear = false
        coordinator.isContentLoaded = true
        coordinator.setDesiredState(state)
        coordinator.completeStyleSync(
            state.style,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        )
        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 240, requestedScrollPercent: nil)
        coordinator.pendingScrollClearAction = { didClear = true }
        let webView = RecordingWebView(completionErrors: [NSError(domain: "Test", code: 2)])

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertTrue(webView.evaluatedScripts[0].hasPrefix("scrollToOffset("))
        XCTAssertEqual(coordinator.pendingScroll, .offset(240))
        XCTAssertFalse(didClear)

        coordinator.flush(on: webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 2)
    }

    @MainActor
    func testCoordinatorDoesNotClearNewerNavigationWhenOlderNavigationCompletes() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClearFirst = false
        var didClearSecond = false

        coordinator.consumeContentNavigationRequest(annotationId: nil, quote: "note-1", block: nil)
        coordinator.pendingContentNavigationClearAction = { didClearFirst = true }
        let firstID = try XCTUnwrap(coordinator.pendingContentNavigationRequestIDForTesting)

        coordinator.consumeContentNavigationRequest(annotationId: nil, quote: "note-2", block: nil)
        coordinator.pendingContentNavigationClearAction = { didClearSecond = true }
        let secondID = try XCTUnwrap(coordinator.pendingContentNavigationRequestIDForTesting)

        XCTAssertFalse(coordinator.completeContentNavigationSync(
            requestID: firstID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertFalse(didClearFirst)
        XCTAssertFalse(didClearSecond)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, .quote("note-2"))

        XCTAssertTrue(coordinator.completeContentNavigationSync(
            requestID: secondID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertTrue(didClearSecond)
        XCTAssertNil(coordinator.pendingContentNavigationRequest)
    }

    @MainActor
    func testCoordinatorDoesNotClearNewerScrollWhenOlderScrollCompletes() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClearFirst = false
        var didClearSecond = false

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 120, requestedScrollPercent: nil)
        coordinator.pendingScrollClearAction = { didClearFirst = true }
        let firstID = try XCTUnwrap(coordinator.pendingScrollRequestIDForTesting)

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 240, requestedScrollPercent: nil)
        coordinator.pendingScrollClearAction = { didClearSecond = true }
        let secondID = try XCTUnwrap(coordinator.pendingScrollRequestIDForTesting)

        XCTAssertFalse(coordinator.completeScrollSync(
            requestID: firstID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertFalse(didClearFirst)
        XCTAssertFalse(didClearSecond)
        XCTAssertEqual(coordinator.pendingScroll, .offset(240))

        XCTAssertTrue(coordinator.completeScrollSync(
            requestID: secondID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertTrue(didClearSecond)
        XCTAssertNil(coordinator.pendingScroll)
    }

    @MainActor
    func testCoordinatorDoesNotClearNavigationCarriedAcrossDocumentReloadWhenOldPageCompletes() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClear = false

        coordinator.consumeContentNavigationRequest(annotationId: nil, quote: "note-1", block: nil)
        coordinator.pendingContentNavigationClearAction = { didClear = true }
        let requestID = try XCTUnwrap(coordinator.pendingContentNavigationRequestIDForTesting)
        let originalGeneration = coordinator.currentDocumentGenerationForTesting

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Next</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        XCTAssertFalse(coordinator.completeContentNavigationSync(
            requestID: requestID,
            documentGeneration: originalGeneration,
            error: nil
        ))
        XCTAssertFalse(didClear)
        XCTAssertEqual(coordinator.pendingContentNavigationRequest, .quote("note-1"))

        XCTAssertTrue(coordinator.completeContentNavigationSync(
            requestID: requestID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertTrue(didClear)
        XCTAssertNil(coordinator.pendingContentNavigationRequest)
    }

    @MainActor
    func testCoordinatorDoesNotClearScrollCarriedAcrossDocumentReloadWhenOldPageCompletes() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        var didClear = false

        coordinator.consumeExplicitScrollRequest(requestedScrollOffset: 240, requestedScrollPercent: nil)
        coordinator.pendingScrollClearAction = { didClear = true }
        let requestID = try XCTUnwrap(coordinator.pendingScrollRequestIDForTesting)
        let originalGeneration = coordinator.currentDocumentGenerationForTesting

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Next</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        XCTAssertFalse(coordinator.completeScrollSync(
            requestID: requestID,
            documentGeneration: originalGeneration,
            error: nil
        ))
        XCTAssertFalse(didClear)
        XCTAssertEqual(coordinator.pendingScroll, .offset(240))

        XCTAssertTrue(coordinator.completeScrollSync(
            requestID: requestID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        ))
        XCTAssertTrue(didClear)
        XCTAssertNil(coordinator.pendingScroll)
    }

    @MainActor
    func testCoordinatorRejectsStaleDocumentLoadCompletionAfterNewerLoadStarts() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 1, html: "<p>Alpha</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let firstGeneration = coordinator.currentDocumentGenerationForTesting
        let firstLoadID = coordinator.registerNavigationLoadForTesting(documentGeneration: firstGeneration)

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Beta</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let secondGeneration = coordinator.currentDocumentGenerationForTesting
        let secondLoadID = coordinator.registerNavigationLoadForTesting(documentGeneration: secondGeneration)

        XCTAssertFalse(
            coordinator.completeDocumentLoadIfCurrent(
                navigationLoadID: firstLoadID,
                documentGeneration: firstGeneration
            )
        )
        XCTAssertFalse(coordinator.isContentLoaded)

        XCTAssertTrue(
            coordinator.completeDocumentLoadIfCurrent(
                navigationLoadID: secondLoadID,
                documentGeneration: secondGeneration
            )
        )
        XCTAssertTrue(coordinator.isContentLoaded)
    }

    @MainActor
    func testCoordinatorMarkerSyncDoesNotCommitInlineImageState() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let decorations = makeDecorationState()

        let success = coordinator.completeMarkerSync(
            decorations.markerPayload,
            markerSnapshot: [MarkerInjection(annotationId: 8, sourceBlockId: 4)],
            imageMarkerSnapshot: [ImageMarkerInjection(imageId: 10, sourceBlockId: 5)],
            documentGeneration: coordinator.currentDocumentGenerationForTesting,
            error: nil
        )

        XCTAssertTrue(success)
        XCTAssertEqual(coordinator.appliedDecorationsForTesting.annotationMarkers, decorations.annotationMarkers)
        XCTAssertEqual(coordinator.appliedDecorationsForTesting.imageMarkers, decorations.imageMarkers)
        XCTAssertFalse(coordinator.appliedDecorationsForTesting.inlineAIImagesEnabled)
        XCTAssertTrue(coordinator.appliedDecorationsForTesting.inlineImages.isEmpty)
    }

    @MainActor
    func testCoordinatorRejectsBridgeMessagesDuringReloadWindow() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 1, html: "<p>Alpha</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let initialToken = coordinator.currentDocumentTokenForTesting
        let initialLoadID = coordinator.registerNavigationLoadForTesting(
            documentGeneration: coordinator.currentDocumentGenerationForTesting
        )
        XCTAssertTrue(coordinator.completeDocumentLoadIfCurrent(
            navigationLoadID: initialLoadID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting
        ))
        XCTAssertTrue(coordinator.shouldAcceptBridgeMessage(documentToken: initialToken))

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Beta</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        XCTAssertNil(coordinator.acceptedBridgeDocumentTokenForTesting)
        XCTAssertFalse(coordinator.isContentLoaded)
        XCTAssertFalse(coordinator.shouldAcceptBridgeMessage(documentToken: initialToken))
    }

    @MainActor
    func testCoordinatorAcceptsOnlyCurrentDocumentTokenAfterReloadFinishes() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 1, html: "<p>Alpha</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let firstToken = coordinator.currentDocumentTokenForTesting

        coordinator.prepareForDocumentLoad(
            state: makeViewState(chapterId: 2, html: "<p>Beta</p>"),
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let secondToken = coordinator.currentDocumentTokenForTesting
        let secondLoadID = coordinator.registerNavigationLoadForTesting(
            documentGeneration: coordinator.currentDocumentGenerationForTesting
        )

        XCTAssertTrue(coordinator.completeDocumentLoadIfCurrent(
            navigationLoadID: secondLoadID,
            documentGeneration: coordinator.currentDocumentGenerationForTesting
        ))
        XCTAssertEqual(coordinator.acceptedBridgeDocumentTokenForTesting, secondToken)
        XCTAssertFalse(coordinator.shouldAcceptBridgeMessage(documentToken: firstToken))
        XCTAssertTrue(coordinator.shouldAcceptBridgeMessage(documentToken: secondToken))
    }

    @MainActor
    func testCoordinatorUsesStableDocumentTokenForEquivalentDocumentReloads() {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let firstState = makeViewState(chapterId: 1, html: "<p>Alpha</p>")
        let equivalentState = makeViewState(chapterId: 1, html: "<p>Alpha</p>")

        coordinator.prepareForDocumentLoad(
            state: firstState,
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )
        let firstToken = coordinator.currentDocumentTokenForTesting

        coordinator.prepareForDocumentLoad(
            state: equivalentState,
            requestedScrollOffset: nil,
            requestedScrollPercent: nil,
            hasContentNavigationRequest: false
        )

        XCTAssertEqual(firstToken, firstState.document.bridgeToken)
        XCTAssertEqual(coordinator.currentDocumentTokenForTesting, equivalentState.document.bridgeToken)
        XCTAssertEqual(firstToken, coordinator.currentDocumentTokenForTesting)
    }

    func testBuildHTMLIncludesAugmentedContentAndBridgeScript() {
        let html = BookContentHTMLBuilder.buildHTML(from: .init(
            contentHTML: "<p>Alpha</p>",
            injections: [
                .init(kind: .annotation(id: 7), sourceBlockId: 1),
                .init(kind: .inlineImage(url: URL(fileURLWithPath: "/tmp/example.png")), sourceBlockId: 1)
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
            documentToken: "token-1",
            readerBridgeJS: "window.__readerBridgeLoaded = true;"
        ))

        XCTAssertTrue(html.contains("<base href=\"file:///tmp/book/\">"))
        XCTAssertTrue(html.contains("<p id=\"block-1\">Alpha<span class=\"annotation-marker\" data-annotation-id=\"7\" data-block-id=\"1\"></span></p><img src=\"example.png\" class=\"generated-image\" data-block-id=\"1\" alt=\"AI Image\">"))
        XCTAssertTrue(html.contains("window.__readerDocumentToken = 'token-1';"))
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

    private func makeViewState(chapterId: Int64?, html: String) -> BookContentViewState {
        BookContentViewState(
            document: BookContentDocumentState(
                chapterId: chapterId,
                chapterIndex: 0,
                contentHTML: html,
                baseHref: "file:///tmp/book/"
            ),
            style: makeStyleState(),
            decorations: .empty
        )
    }

    private func makeStyleState() -> BookContentStyleState {
        BookContentStyleState(
            themeBase: "#191724",
            themeSurface: "#1f1d2e",
            themeText: "#e0def4",
            themeMuted: "#6e6a86",
            themeRose: "#eb6f92",
            themeIris: "#c4a7e7",
            fontFamily: "SF Pro Text",
            fontSize: 15,
            lineSpacing: 1.2
        )
    }

    private func makeDecorationState() -> BookContentDecorationState {
        BookContentDecorationState(
            annotations: [
                Annotation(id: 7, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 2)
            ],
            images: [
                GeneratedImage(id: 9, chapterId: 1, excerpt: "Excerpt", prompt: "Prompt", imagePath: "/tmp/test.png", sourceBlockId: 3, status: .success)
            ],
            inlineAIImagesEnabled: true,
            pendingMarkers: [MarkerInjection(annotationId: 8, sourceBlockId: 4)],
            pendingImageMarkers: [ImageMarkerInjection(imageId: 10, sourceBlockId: 5)]
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
