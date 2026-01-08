import XCTest
@testable import Reverie

@MainActor
final class ChapterProgressCalculatorTests: XCTestCase {
    func testPercentCalculationAcrossBlocks() {
        let calculator = ChapterProgressCalculator(wordCounts: [100, 100], totalWords: 200)

        let quarter = calculator.percent(for: BlockLocation(blockId: 1, offset: 0.5))
        XCTAssertEqual(quarter, 0.25, accuracy: 0.0001)

        let halfway = calculator.percent(for: BlockLocation(blockId: 2, offset: 0))
        XCTAssertEqual(halfway, 0.5, accuracy: 0.0001)

        let full = calculator.percent(for: BlockLocation(blockId: 2, offset: 1))
        XCTAssertEqual(full, 1.0, accuracy: 0.0001)
    }

    func testPercentClampsBlockRange() {
        let calculator = ChapterProgressCalculator(wordCounts: [50, 50], totalWords: 100)
        let clamped = calculator.percent(for: BlockLocation(blockId: 99, offset: 0.5))
        XCTAssertEqual(clamped, 0.75, accuracy: 0.0001)
    }

    func testZeroWordTotalReturnsZero() {
        let calculator = ChapterProgressCalculator(wordCounts: [], totalWords: 0)
        let percent = calculator.percent(for: BlockLocation(blockId: 1, offset: 0.5))
        XCTAssertEqual(percent, 0)
    }

    func testTotalWordsUpToLocation() {
        // Test at block boundaries and middle
        let calc = ChapterProgressCalculator(wordCounts: [100, 200, 150], totalWords: 450)
        
        // Start of first block
        XCTAssertEqual(calc.totalWords(upTo: BlockLocation(blockId: 1, offset: 0)), 0)
        
        // Middle of first block
        XCTAssertEqual(calc.totalWords(upTo: BlockLocation(blockId: 1, offset: 0.5)), 50)
        
        // End of first block / start of second
        XCTAssertEqual(calc.totalWords(upTo: BlockLocation(blockId: 2, offset: 0)), 100)
        
        // Middle of second block
        XCTAssertEqual(calc.totalWords(upTo: BlockLocation(blockId: 2, offset: 0.5)), 200)
        
        // End of all blocks
        XCTAssertEqual(calc.totalWords(upTo: BlockLocation(blockId: 3, offset: 1.0)), 450)
    }
}
