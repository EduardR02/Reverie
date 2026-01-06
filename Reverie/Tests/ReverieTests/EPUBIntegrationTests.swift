import XCTest
@testable import Reverie

final class EPUBIntegrationTests: XCTestCase {
    
    func testRealEPUBParsing() async throws {
        // Robust fixture path resolution for both Xcode and CLI
        let fileManager = FileManager.default
        let currentFileURL = URL(fileURLWithPath: #file)
        
        // Strategy 1: Check relative to #file
        let projectFixturesURL = currentFileURL
            .deletingLastPathComponent() // ReverieTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("qntm.epub")
            
        var epubURL = projectFixturesURL
        
        // Strategy 2: Check via Bundle.module (SPM resources)
        if !fileManager.fileExists(atPath: epubURL.path) {
            if let bundleURL = Bundle.module.url(forResource: "qntm", withExtension: "epub", subdirectory: "Fixtures") {
                epubURL = bundleURL
            }
        }
        
        guard fileManager.fileExists(atPath: epubURL.path) else {
            XCTFail("Missing qntm.epub. Checked project path and bundle.")
            return
        }
        
        let parser = EPUBParser()
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("EPUBTest_\(UUID().uuidString)")
        
        // 2. Run the real parsing logic
        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir)
        
        // 3. Verify Metadata
        XCTAssertTrue(book.title.contains("Valuable Humans"), "Title should be correct. Got: \(book.title)")
        XCTAssertEqual(book.author, "qntm")
        
        // 4. Verify Chapters
        XCTAssertGreaterThan(book.chapters.count, 0, "Should have found chapters")
        
        // Check first substantive chapter
        let firstContent = book.chapters.first { !$0.title.isEmpty && $0.wordCount > 100 }
        XCTAssertNotNil(firstContent, "Should find at least one story/chapter with content")
        
        print("Successfully parsed \(book.title) with \(book.chapters.count) chapters.")
        
        // Cleanup
        try? fileManager.removeItem(at: tempDir)
    }
}
