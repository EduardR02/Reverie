import XCTest
@testable import Reverie

@MainActor
final class LLMSchemaTests: XCTestCase {
    func testChapterAnalysisSchemaConstrainsImageAspectRatio() throws {
        let schema = SchemaLibrary.chapterAnalysis(imagesEnabled: true).schema
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let imageSuggestions = try XCTUnwrap(properties["imageSuggestions"] as? [String: Any])
        let items = try XCTUnwrap(imageSuggestions["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let aspectRatio = try XCTUnwrap(itemProperties["aspectRatio"] as? [String: Any])

        XCTAssertEqual(aspectRatio["enum"] as? [String], ["16:9", "1:1", "9:16"])
        XCTAssertEqual(items["required"] as? [String], ["excerpt", "sourceBlockId", "aspectRatio"])
    }
}
