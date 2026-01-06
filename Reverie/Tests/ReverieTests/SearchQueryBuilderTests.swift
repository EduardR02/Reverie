import XCTest
@testable import Reverie

final class SearchQueryBuilderTests: XCTestCase {
    func testDeterministicQueryBuilding() {
        let title = "The orbital mechanics are backwards"
        let content = "The described trajectory would require accelerating toward Earth, not away."
        let book = "Seveneves"
        let author = "Neal Stephenson"
        
        let query = SearchQueryBuilder.deterministicQuery(
            insightTitle: title,
            insightContent: content,
            bookTitle: book,
            author: author
        )
        
        // Expected behavior: 
        // Title: [orbital, mechanics, backwards]
        // Content: [described, trajectory] (prefix 2)
        // Book: [seveneves]
        // Author: [neal]
        
        XCTAssertTrue(query.contains("orbital"))
        XCTAssertTrue(query.contains("mechanics"))
        XCTAssertTrue(query.contains("backwards"))
        XCTAssertTrue(query.contains("described"))
        XCTAssertTrue(query.contains("trajectory"))
        XCTAssertTrue(query.contains("seveneves"))
        XCTAssertTrue(query.contains("neal"))
        
        // Ensure no stop words
        let components = query.lowercased().components(separatedBy: " ")
        XCTAssertFalse(components.contains("the"))
        XCTAssertFalse(components.contains("are"))
    }
    
    func testSearchURLGeneration() {
        let query = "orbital mechanics seveneves neal"
        let url = SearchQueryBuilder.searchURL(for: query)
        
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
        // URLComponents encodes spaces as %20
        XCTAssertTrue(url?.query?.contains("q=orbital%20mechanics%20seveneves%20neal") ?? false)
    }
    
    func testEmptyInputsFallback() {
        let query = SearchQueryBuilder.deterministicQuery(
            insightTitle: "Insight",
            insightContent: "Detail",
            bookTitle: "",
            author: ""
        )
        XCTAssertEqual(query, "insight detail")
    }
}
