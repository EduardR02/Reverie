import XCTest
@testable import Reverie

final class ContentBlockParserTests: XCTestCase {
    var parser: ContentBlockParser!

    override func setUp() {
        super.setUp()
        parser = ContentBlockParser()
    }

    func testBasicParsing() {
        let html = "<p>First paragraph.</p><p>Second paragraph.</p>"
        let (blocks, cleanText) = parser.parse(html: html)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].id, 1)
        XCTAssertEqual(blocks[0].text, "First paragraph.")
        XCTAssertEqual(blocks[1].id, 2)
        XCTAssertEqual(blocks[1].text, "Second paragraph.")
        XCTAssertTrue(cleanText.contains("[1] First paragraph."))
        XCTAssertTrue(cleanText.contains("[2] Second paragraph."))
    }

    func testComplexHTML() {
        let html = """
        <div>
            <h1>Chapter Title</h1>
            <p>This is a <i>test</i> with <b>multiple</b> tags.</p>
            <blockquote>A quote here.</blockquote>
            <ul>
                <li>Item 1</li>
                <li>Item 2</li>
            </ul>
        </div>
        """
        let (blocks, _) = parser.parse(html: html)

        // h1, p, blockquote, li, li = 5 blocks
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0].text, "Chapter Title")
        XCTAssertEqual(blocks[1].text, "This is a test with multiple tags.")
        XCTAssertEqual(blocks[2].text, "A quote here.")
        XCTAssertEqual(blocks[3].text, "Item 1")
        XCTAssertEqual(blocks[4].text, "Item 2")
    }

    func testNoiseFiltering() {
        let html = """
        <p>Valid content here.</p>
        <p>  </p>
        <p>1</p>
        <p>Another valid block.</p>
        """
        let (blocks, _) = parser.parse(html: html)

        // Should skip the empty and too-short blocks (< 3 chars)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "Valid content here.")
        XCTAssertEqual(blocks[1].text, "Another valid block.")
    }

    func testHTMLEntityDecoding() {
        let html = "<p>It&rsquo;s a test &amp; more &ldquo;quotes&rdquo;.</p>"
        let (blocks, _) = parser.parse(html: html)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "It's a test & more “quotes”.")
    }

    func testInjectionOffset() {
        let html = "<h1>Title</h1><p>Para</p>"
        // "<h1>Title</h1>" is 14 chars (with newline from stripHTML if any, or just literal count)
        // Wait, <h1>Title</h1> is 14 chars: <(3) + Title(5) + </h1>(5) = 13.
        // Actually: <h1> is 4, Title is 5, </h1> is 5. Total 14.
        let offset = parser.injectionOffset(for: 1, in: html)
        XCTAssertEqual(offset, 14)
        
        let offset2 = parser.injectionOffset(for: 2, in: html)
        XCTAssertEqual(offset2, 25)
    }
    
    func testFallbackParsing() {
        // Test when no standard block tags are found
        let html = "Just some text\n\nwith double newlines\n\nto simulate paragraphs."
        let (blocks, _) = parser.parse(html: html)
        
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].text, "Just some text")
        XCTAssertEqual(blocks[1].text, "with double newlines")
        XCTAssertEqual(blocks[2].text, "to simulate paragraphs.")
    }
}
