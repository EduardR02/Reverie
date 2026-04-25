import XCTest
@testable import Reverie

@MainActor
final class RSVPEngineTests: XCTestCase {
    func testSyncToBlockIdMovesToFirstWordOfBlock() {
        let engine = RSVPEngine()

        engine.loadChapter(
            blocks: [
                makeBlock(id: 1, text: "Alpha beta"),
                makeBlock(id: 2, text: "Gamma delta epsilon")
            ],
            annotations: [],
            images: [],
            footnotes: []
        )

        engine.currentWordIndex = 0
        engine.pendingPauseContent = .footnote(Footnote(id: 9, chapterId: 1, marker: "1", content: "Note", refId: "note-1", sourceBlockId: 1))
        engine.sync(toBlockId: 2)

        XCTAssertEqual(engine.currentWordIndex, 2)
        XCTAssertEqual(engine.currentWord?.text, "Gamma")
        XCTAssertNil(engine.pendingPauseContent)
    }

    func test_sync_to_block_with_pause_content_sets_pendingPauseContent_and_pauses() {
        let engine = RSVPEngine()
        let annotation = Annotation(id: 1, chapterId: 1, type: .science, title: "T", content: "C", sourceBlockId: 2)

        engine.loadChapter(
            blocks: [
                makeBlock(id: 1, text: "Alpha beta"),
                makeBlock(id: 2, text: "Gamma delta epsilon")
            ],
            annotations: [annotation],
            images: [],
            footnotes: []
        )

        // Start playing so that pause() has observable effect
        engine.setWPM(1) // very slow, won't advance before we sync
        engine.play()
        XCTAssertTrue(engine.isPlaying)

        engine.sync(toBlockId: 2)

        XCTAssertEqual(engine.currentWord?.text, "Gamma")
        XCTAssertEqual(engine.pendingPauseContent, .insight(annotation))
        XCTAssertFalse(engine.isPlaying)
    }

    func test_skip_lands_on_pause_content_sets_pendingPauseContent_and_pauses() {
        let engine = RSVPEngine()
        let footnote = Footnote(id: 1, chapterId: 1, marker: "*", content: "Note", refId: "n1", sourceBlockId: 1)

        engine.loadChapter(
            blocks: [
                makeBlock(id: 1, text: "Alpha beta Gamma delta epsilon zeta eta theta iota kappa lambda mu")
            ],
            annotations: [],
            images: [],
            footnotes: [footnote]
        )

        engine.currentWordIndex = 5
        engine.play()
        XCTAssertTrue(engine.isPlaying)

        // Simulate pressing play first, then skip -10 from index 5
        engine.currentWordIndex = 5
        XCTAssertTrue(engine.isPlaying)

        // Skip back to word 0 which has footnote pause
        engine.skip(words: -5)

        XCTAssertEqual(engine.currentWordIndex, 0)
        XCTAssertEqual(engine.pendingPauseContent, .footnote(footnote))
        XCTAssertFalse(engine.isPlaying)
    }

    func test_skip_to_non_pause_destination_clears_stale_content() {
        let engine = RSVPEngine()

        engine.loadChapter(
            blocks: [
                makeBlock(id: 1, text: "Alpha beta Gamma delta")
            ],
            annotations: [],
            images: [],
            footnotes: []
        )

        engine.currentWordIndex = 0
        engine.pendingPauseContent = .footnote(Footnote(id: 9, chapterId: 1, marker: "1", content: "Stale", refId: "n1", sourceBlockId: 1))
        engine.play()

        engine.skip(words: 2)

        XCTAssertEqual(engine.currentWordIndex, 2)
        XCTAssertNil(engine.pendingPauseContent)
        // Skip does not auto-pause on non-pause destinations — but we've already called play,
        // and the skip itself doesn't change isPlaying. Let's verify:
        XCTAssertTrue(engine.isPlaying)
    }

    func testLoadChapterKeepsFirstPauseItemPerBlockAndAnnotationPrecedence() async {
        let engine = RSVPEngine()
        let firstAnnotation = Annotation(id: 11, chapterId: 1, type: .science, title: "A", content: "Insight", sourceBlockId: 2)
        let laterAnnotation = Annotation(id: 12, chapterId: 1, type: .history, title: "B", content: "Later", sourceBlockId: 2)
        let image = GeneratedImage(id: 21, chapterId: 1, excerpt: "Excerpt", prompt: "Prompt", imagePath: "/tmp/image.png", sourceBlockId: 2, status: .success)
        let footnote = Footnote(id: 31, chapterId: 1, marker: "1", content: "Footnote", refId: "note-1", sourceBlockId: 2)

        engine.loadChapter(
            blocks: [
                makeBlock(id: 1, text: "Alpha"),
                makeBlock(id: 2, text: "Beta")
            ],
            annotations: [firstAnnotation, laterAnnotation],
            images: [image],
            footnotes: [footnote]
        )

        engine.setWPM(60_000)
        engine.play()
        await waitForPauseContent(on: engine)

        XCTAssertEqual(engine.currentWordIndex, 1)
        XCTAssertEqual(engine.pendingPauseContent, .insight(firstAnnotation))
    }

    private func makeBlock(id: Int, text: String) -> ContentBlock {
        ContentBlock(
            id: id,
            text: text,
            htmlStartOffset: 0,
            contentStartOffset: 0,
            contentEndOffset: 0,
            htmlEndOffset: 0
        )
    }

    private func waitForPauseContent(on engine: RSVPEngine, timeoutNanoseconds: UInt64 = 1_000_000_000) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if engine.pendingPauseContent != nil {
                return
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTFail("Timed out waiting for RSVP pause content")
    }
}
