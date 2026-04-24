import XCTest
import SwiftUI
@testable import Reverie

@MainActor
final class SelectableTextMarkdownTests: XCTestCase {

    // MARK: - makeMarkdownAttributedString

    func testPlainTextFallbackWhenMarkdownIsEmpty() {
        let result = SelectableText.makeMarkdownAttributedString(
            text: "",
            fontSize: 14,
            color: .black,
            lineSpacing: 0
        )
        XCTAssertEqual(result.string, "")
    }

    func testPlainTextFallbackOnInvalidMarkdown() {
        // Even "invalid" markdown is generally parsed gracefully by AttributedString(markdown:).
        // But we test that the function returns a valid NSAttributedString even for pathological input.
        let result = SelectableText.makeMarkdownAttributedString(
            text: "Hello **world",
            fontSize: 14,
            color: Color(red: 0.1, green: 0.2, blue: 0.3),
            lineSpacing: 2
        )
        XCTAssertFalse(result.string.isEmpty)
        // Foreground color should be applied
        let colorAttr = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(colorAttr)
    }

    func testBoldMarkdownRendered() {
        let text = "This is **bold** and *italic* text."
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 0
        )
        // After parsing markdown, the result string has the rendered text (no markdown markers)
        XCTAssertEqual(result.string, "This is bold and italic text.")

        // The "bold" portion should have a bold font trait
        let boldRange = (result.string as NSString).range(of: "bold")
        XCTAssertGreaterThan(boldRange.length, 0)

        let fontAtBold = result.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let fontAtPlain = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        if let boldFont = fontAtBold, let plainFont = fontAtPlain {
            let boldDescriptor = boldFont.fontDescriptor
            let boldSymbolicTraits = boldDescriptor.symbolicTraits

            // Bold text should have bold trait
            XCTAssertTrue(boldSymbolicTraits.contains(.bold))
            // The bold font should be different from the plain font
            XCTAssertNotEqual(boldFont, plainFont,
                              "Bold portion should use a different font than plain text")
        }
    }

    func testItalicMarkdownRendered() {
        let text = "This is *italic* text."
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 0
        )
        // After parsing markdown, the result string has the rendered text (no markdown markers)
        XCTAssertEqual(result.string, "This is italic text.")

        let italicRange = (result.string as NSString).range(of: "italic")
        XCTAssertGreaterThan(italicRange.length, 0)

        let fontAtItalic = result.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        if let italicFont = fontAtItalic {
            let traits = italicFont.fontDescriptor.symbolicTraits
            XCTAssertTrue(traits.contains(.italic),
                          "Italic markdown should produce italic font trait")
        }
    }

    func testCodeBlockRendered() {
        let text = "Use `code` inline."
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 0
        )
        // After parsing markdown, the result string has the rendered text (no markdown markers)
        XCTAssertEqual(result.string, "Use code inline.")

        let codeRange = (result.string as NSString).range(of: "code")
        XCTAssertGreaterThan(codeRange.length, 0)

        let fontAtCode = result.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        if let codeFont = fontAtCode {
            let traits = codeFont.fontDescriptor.symbolicTraits
            XCTAssertTrue(traits.contains(.monoSpace),
                          "Code markdown should produce monospace font trait")
        }
    }

    func testForegroundColorAppliedGlobally() {
        let text = "**Bold** and *italic*"
        let expectedColor = NSColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1.0)
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: Color(expectedColor),
            lineSpacing: 0
        )

        // Check color on plain part
        let plainColor = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(plainColor, expectedColor)

        // Check color on bold part
        let boldRange = (result.string as NSString).range(of: "Bold")
        let boldColor = result.attribute(.foregroundColor, at: boldRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(boldColor, expectedColor)
    }

    func testLineSpacingApplied() {
        let text = "Line one\nLine two"
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 8
        )

        let paragraphStyle = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(paragraphStyle)
        XCTAssertEqual(paragraphStyle?.lineSpacing, 8)
    }

    // MARK: - Integration with SelectableText init

    func testDefaultRendersMarkdownIsFalse() {
        let st = SelectableText("hello", fontSize: 14, color: .white)
        XCTAssertFalse(st.rendersMarkdown,
                       "rendersMarkdown should default to false for backwards compatibility")
    }

    func testExplicitRendersMarkdownTrue() {
        let st = SelectableText("hello", fontSize: 14, color: .white, rendersMarkdown: true)
        XCTAssertTrue(st.rendersMarkdown)
    }

    func testMarkdownWithHeaders() {
        let text = "# Heading\n\nParagraph text."
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 4
        )
        // Should not crash, should render something
        XCTAssertFalse(result.string.isEmpty)
        XCTAssertTrue(result.string.contains("Heading"))
    }

    func testMarkdownWithLinksProducesLinkAttribute() {
        let text = "Click [here](https://example.com) for more."
        let result = SelectableText.makeMarkdownAttributedString(
            text: text,
            fontSize: 14,
            color: .white,
            lineSpacing: 0
        )
        let linkRange = (result.string as NSString).range(of: "here")
        let linkAttr = result.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertNotNil(linkAttr, "Link markdown should produce a link attribute")
        XCTAssertEqual(linkAttr?.absoluteString, "https://example.com")
    }
}
