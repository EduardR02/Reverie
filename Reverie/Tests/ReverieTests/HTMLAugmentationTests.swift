import XCTest
@testable import Reverie

final class HTMLAugmentationTests: XCTestCase {
    var parser: ContentBlockParser! 

    override func setUp() {
        super.setUp()
        parser = ContentBlockParser()
    }

    /// THOROUGH TEST: Verifies that existing HTML attributes (like class) are preserved
    func testAttributePreservation() {
        let html = "<p class=\"original-class\">Content</p>"
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 1), sourceBlockId: 1)
        ]
        
        let result = parser.augment(html: html, injections: injections)
        
        // Ensure we didn't destroy the class attribute
        // Correct: <p class="original-class" id="block-1">
        XCTAssertTrue(result.contains("<p class=\"original-class\" id=\"block-1\">"))
        XCTAssertTrue(result.contains("Content<span class=\"annotation-marker\""))
    }

    /// THOROUGH TEST: Verifies chronological ordering of multiple markers in one block
    func testMarkerOrdering() {
        let html = "<p>Block</p>"
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 10), sourceBlockId: 1),
            .init(kind: .annotation(id: 20), sourceBlockId: 1),
            .init(kind: .imageMarker(id: 30), sourceBlockId: 1)
        ]
        
        let result = parser.augment(html: html, injections: injections)
        
        // Markers should appear in the order they were provided in the array
        let expectedMarkers = "Block<span class=\"annotation-marker\" data-annotation-id=\"10\" data-block-id=\"1\"></span><span class=\"annotation-marker\" data-annotation-id=\"20\" data-block-id=\"1\"></span><span class=\"image-marker\" data-image-id=\"30\" data-block-id=\"1\"></span></p>"
        XCTAssertTrue(result.contains(expectedMarkers))
    }

    /// THOROUGH TEST: Unicode and Emoji offset safety
    /// Emojis often break simple character-counting logic.
    func testEmojiAndUnicodeSafety() {
        let html = "<p>Beginning 👨‍👩‍👧‍👦 with complex emoji.</p><p>Target paragraph with 🌍.</p>"
        
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 1), sourceBlockId: 2)
        ]
        
        let result = parser.augment(html: html, injections: injections)
        
        // Ensure the ID and Marker for block 2 are still correctly placed despite the heavy emojis in block 1
        XCTAssertTrue(result.contains("<p id=\"block-2\">Target paragraph with 🌍.<span class=\"annotation-marker\" data-annotation-id=\"1\" data-block-id=\"2\"></span></p>"))
    }

    /// THOROUGH TEST: Nested Tags Integrity
    func testNestedTagIntegrity() {
        let html = "<p>End with <b><i>style</i></b>.</p>"
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 1), sourceBlockId: 1)
        ]
        
        let result = parser.augment(html: html, injections: injections)
        
        // The marker MUST be after </i> but BEFORE </p>
        XCTAssertTrue(result.contains("style</i></b>.<span class=\"annotation-marker\" data-annotation-id=\"1\" data-block-id=\"1\"></span></p>"))
    }

    /// STRESS TEST: Multiple Blocks and Mixed Injections
    func testRealWorldAugmentation() {
        let html = "<h1>Title</h1><p>Paragraph one.</p><p>Target.</p>"
        
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 101), sourceBlockId: 3),
            .init(kind: .inlineImage(url: URL(string: "file:///tmp/laser.png")!), sourceBlockId: 3)
        ]
        
        let result = parser.augment(html: html, injections: injections)
        
        XCTAssertTrue(result.contains("<h1 id=\"block-1\">Title</h1>"))
        XCTAssertTrue(result.contains("<p id=\"block-2\">Paragraph one.</p>"))
        XCTAssertTrue(result.contains("<p id=\"block-3\">Target.<span class=\"annotation-marker\" data-annotation-id=\"101\" data-block-id=\"3\"></span></p>"))
        XCTAssertTrue(result.contains("</p><img src=\"laser.png\" class=\"generated-image\" data-block-id=\"3\" alt=\"AI Image\">"))
    }

    /// STRESS TEST: Short/Noise Blocks
    func testShortBlockFiltering() {
        let noiseHtml = "<p>1</p><p>Valid paragraph.</p>"
        let injections: [ContentBlockParser.Injection] = [
            .init(kind: .annotation(id: 1), sourceBlockId: 1)
        ]
        
        let result = parser.augment(html: noiseHtml, injections: injections)
        
        // Block 1 should be the "Valid paragraph" because "1" was skipped by the parser's noise filter.
        XCTAssertTrue(result.contains("<p id=\"block-1\">Valid paragraph."))
    }
}