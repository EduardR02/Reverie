import XCTest
@testable import Reader

final class BookModelTests: XCTestCase {
    
    func testNeedsClassificationLogic() {
        var book = Book(title: "Test", author: "Author", epubPath: "/tmp/test.epub")
        
        // 1. Fresh book (pending) -> Should need classification
        book.classificationStatus = .pending
        XCTAssertTrue(book.needsClassification)
        
        // 2. Failed book -> Should need classification (retry logic)
        book.classificationStatus = .failed
        XCTAssertTrue(book.needsClassification)
        
        // 3. Interrupted book (inProgress) -> Should need classification (crash recovery)
        // This is the specific case we fixed to prevent "stuck" books
        book.classificationStatus = .inProgress
        XCTAssertTrue(book.needsClassification)
        
        // 4. Completed book -> Should NOT need classification
        book.classificationStatus = .completed
        XCTAssertFalse(book.needsClassification)
    }
}
