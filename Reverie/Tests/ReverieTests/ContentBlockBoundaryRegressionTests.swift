import XCTest
@testable import Reverie

final class ContentBlockBoundaryRegressionTests: XCTestCase {
    func testEscapedLiteralTagsRemainInReadingText() {
        let html = "<p>Use &lt;vector&gt;, &#60;string&#62;, and &amp;.</p>"
        let parsed = ContentBlockParser().parse(html: html)
        XCTAssertEqual(parsed.blocks.map(\.text), ["Use <vector>, <string>, and &."])
    }

    func testQuotedGreaterThanDoesNotCorruptAnchorOrText() {
        let parser = ContentBlockParser()
        let html = "<p title=\"a > b\">Actual passage.</p>"
        XCTAssertEqual(parser.parse(html: html).blocks.first?.text, "Actual passage.")
        XCTAssertEqual(
            parser.augment(html: html, injections: []),
            "<p title=\"a > b\" id=\"block-1\">Actual passage.</p>"
        )
    }

    func testPlainTextFallbackGetsDistinctOffsetsAndNavigableMarkers() throws {
        let parser = ContentBlockParser()
        let html = "First passage 😀\n\nSecond passage"
        let blocks = parser.parse(html: html).blocks
        XCTAssertEqual(blocks.count, 2)
        let second = try XCTUnwrap(blocks.last)
        XCTAssertEqual(second.htmlStartOffset, "First passage 😀\n\n".count)
        XCTAssertEqual(parser.blockId(at: second.htmlStartOffset, in: html), 2)
        let augmented = parser.augment(html: html, injections: [
            .init(kind: .annotation(id: 41), sourceBlockId: 1),
            .init(kind: .annotation(id: 42), sourceBlockId: 2)
        ])
        XCTAssertEqual(
            augmented,
            "<div id=\"block-1\">First passage 😀<span class=\"annotation-marker\" data-annotation-id=\"41\" data-block-id=\"1\"></span></div>\n\n<div id=\"block-2\">Second passage<span class=\"annotation-marker\" data-annotation-id=\"42\" data-block-id=\"2\"></span></div>"
        )
    }

    func testFallbackMarkupIsWrappedWithoutSplittingAnElement() {
        let parser = ContentBlockParser()
        let html = "<div>First passage\n\nSecond passage</div>"
        XCTAssertEqual(parser.parse(html: html).blocks.count, 1)
        XCTAssertEqual(
            parser.augment(html: html, injections: []),
            "<div id=\"block-1\"><div>First passage\n\nSecond passage</div></div>"
        )
    }
}
