import XCTest
@testable import Reverie

final class BookContentPipelineTests: XCTestCase {
    func testDecorationStateKeepsImageMarkersForFailedImagesAndOnlyInlinesSuccessfulOnes() {
        let failed = GeneratedImage(
            id: 7,
            chapterId: 1,
            excerpt: "Failed",
            prompt: "Prompt",
            imagePath: "",
            sourceBlockId: 3,
            status: .failed,
            failureReason: "nope"
        )
        let success = GeneratedImage(
            id: 8,
            chapterId: 1,
            excerpt: "Success",
            prompt: "Prompt",
            imagePath: "/tmp/example.png",
            sourceBlockId: 4,
            status: .success
        )

        let decorations = BookContentDecorationState(
            annotations: [],
            images: [failed, success],
            inlineAIImagesEnabled: true,
            pendingMarkers: [],
            pendingImageMarkers: []
        )

        XCTAssertEqual(decorations.imageMarkers.map(\.imageId), [7, 8])
        XCTAssertEqual(decorations.imageMarkers.map(\.sourceBlockId), [3, 4])
        XCTAssertEqual(decorations.inlineImages.count, 1)
        XCTAssertEqual(decorations.inlineImages[0].imageId, 8)
        XCTAssertEqual(decorations.inlineImages[0].sourceBlockId, 4)
        XCTAssertEqual(
            decorations.inlineImages[0].imageURL,
            URL(fileURLWithPath: "/tmp/example.png").absoluteString
        )
    }

    func testDecorationStateIncludesPendingMarkersUntilVisibleStateCatchesUp() {
        let decorations = BookContentDecorationState(
            annotations: [],
            images: [],
            inlineAIImagesEnabled: false,
            pendingMarkers: [MarkerInjection(annotationId: 11, sourceBlockId: 5)],
            pendingImageMarkers: [ImageMarkerInjection(imageId: 22, sourceBlockId: 6)]
        )

        XCTAssertEqual(decorations.annotationMarkers, [.init(annotationId: 11, sourceBlockId: 5)])
        XCTAssertEqual(decorations.imageMarkers, [.init(imageId: 22, sourceBlockId: 6)])
    }

    func testDecorationStateDeduplicatesPersistedAndPendingMarkers() {
        let decorations = BookContentDecorationState(
            annotations: [
                Annotation(id: 11, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 5)
            ],
            images: [
                GeneratedImage(id: 22, chapterId: 1, excerpt: "E", prompt: "P", imagePath: "/tmp/x.png", sourceBlockId: 6, status: .success)
            ],
            inlineAIImagesEnabled: true,
            pendingMarkers: [MarkerInjection(annotationId: 11, sourceBlockId: 5)],
            pendingImageMarkers: [ImageMarkerInjection(imageId: 22, sourceBlockId: 6)]
        )

        XCTAssertEqual(decorations.annotationMarkers, [.init(annotationId: 11, sourceBlockId: 5)])
        XCTAssertEqual(decorations.imageMarkers, [.init(imageId: 22, sourceBlockId: 6)])
        XCTAssertEqual(decorations.inlineImages.count, 1)
    }

    func testDocumentRenderSignatureChangesOnlyWhenDocumentChanges() {
        let document = makeDocumentState()
        let matchingDocument = makeDocumentState()
        let changedDocument = makeDocumentState(chapterId: 2, html: "<p>Beta</p>")

        XCTAssertEqual(document.renderSignature, matchingDocument.renderSignature)
        XCTAssertNotEqual(document.renderSignature, changedDocument.renderSignature)
    }

    func testDocumentBridgeTokenIsStableForEquivalentDocumentsAndChangesWithDocument() {
        let document = makeDocumentState()
        let matchingDocument = makeDocumentState()
        let changedDocument = makeDocumentState(chapterId: 2, html: "<p>Beta</p>")

        XCTAssertEqual(document.bridgeToken, matchingDocument.bridgeToken)
        XCTAssertNotEqual(document.bridgeToken, changedDocument.bridgeToken)
    }

    func testDecorationUpdatePlanSkipsInlineImageSyncForMarkerOnlyChanges() {
        let previous = BookContentDecorationState(
            annotations: [Annotation(id: 1, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 2)],
            images: [GeneratedImage(id: 7, chapterId: 1, excerpt: "E", prompt: "P", imagePath: "/tmp/example.png", sourceBlockId: 3, status: .success)],
            inlineAIImagesEnabled: true,
            pendingMarkers: [],
            pendingImageMarkers: []
        )
        let desired = BookContentDecorationState(
            annotations: [
                Annotation(id: 1, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 2),
                Annotation(id: 2, chapterId: 1, type: .history, title: "C", content: "D", sourceBlockId: 4)
            ],
            images: [GeneratedImage(id: 7, chapterId: 1, excerpt: "E", prompt: "P", imagePath: "/tmp/example.png", sourceBlockId: 3, status: .success)],
            inlineAIImagesEnabled: true,
            pendingMarkers: [],
            pendingImageMarkers: []
        )

        let plan = BookContentDecorationUpdatePlan(previous: previous, desired: desired)

        XCTAssertTrue(plan.needsMarkerSync)
        XCTAssertFalse(plan.needsInlineImageSync)
    }

    func testDecorationUpdatePlanSkipsMarkerSyncForInlineImageOnlyChanges() {
        let previous = BookContentDecorationState(
            annotations: [Annotation(id: 1, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 2)],
            images: [GeneratedImage(id: 7, chapterId: 1, excerpt: "E", prompt: "P", imagePath: "/tmp/example.png", sourceBlockId: 3, status: .success)],
            inlineAIImagesEnabled: true,
            pendingMarkers: [],
            pendingImageMarkers: []
        )
        let desired = BookContentDecorationState(
            annotations: [Annotation(id: 1, chapterId: 1, type: .science, title: "A", content: "B", sourceBlockId: 2)],
            images: [GeneratedImage(id: 7, chapterId: 1, excerpt: "E", prompt: "P", imagePath: "/tmp/example-2.png", sourceBlockId: 3, status: .success)],
            inlineAIImagesEnabled: true,
            pendingMarkers: [],
            pendingImageMarkers: []
        )

        let plan = BookContentDecorationUpdatePlan(previous: previous, desired: desired)

        XCTAssertFalse(plan.needsMarkerSync)
        XCTAssertTrue(plan.needsInlineImageSync)
    }

    @MainActor
    func testRenderedHTMLReuseCacheIgnoresStyleChanges() throws {
        let coordinator = BookContentView.Coordinator(parent: makeBookContentView())
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = makeDocumentState()

        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }

        try "alpha".write(to: fileURL, atomically: true, encoding: .utf8)
        coordinator.recordRenderedHTMLPersistenceSuccess(at: fileURL, for: document)

        XCTAssertTrue(coordinator.shouldReuseRenderedHTML(at: fileURL, for: document))
        XCTAssertTrue(
            coordinator.shouldReuseRenderedHTML(at: fileURL, for: makeDocumentState()),
            "Style-only changes must not force a document rewrite."
        )
        XCTAssertFalse(coordinator.shouldReuseRenderedHTML(at: fileURL, for: makeDocumentState(chapterId: 2, html: "<p>Beta</p>")))
    }

    private func makeDocumentState(
        chapterId: Int64? = 1,
        html: String = "<p>Alpha</p>"
    ) -> BookContentDocumentState {
        BookContentDocumentState(
            chapterId: chapterId,
            chapterIndex: 0,
            contentHTML: html,
            baseHref: "file:///tmp/book/"
        )
    }

    @MainActor
    private func makeBookContentView() -> BookContentView {
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
            scrollToPercent: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            scrollToQuote: .constant(nil),
            pendingMarkerInjections: .constant([]),
            pendingImageMarkerInjections: .constant([]),
            scrollByAmount: .constant(nil)
        )
    }
}
