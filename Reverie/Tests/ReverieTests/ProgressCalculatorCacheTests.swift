import XCTest
@testable import Reverie

final class ProgressCalculatorCacheTests: XCTestCase {
    
    func testCacheRespectsLimit() {
        let cache = ProgressCalculatorCache(limit: 3)
        let calc = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        
        cache.insert(calc, for: 1, protecting: nil)
        cache.insert(calc, for: 2, protecting: nil)
        cache.insert(calc, for: 3, protecting: nil)
        cache.insert(calc, for: 4, protecting: nil)
        
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.cachedChapterIds.contains(1))
        XCTAssertTrue(cache.cachedChapterIds.contains(2))
        XCTAssertTrue(cache.cachedChapterIds.contains(3))
        XCTAssertTrue(cache.cachedChapterIds.contains(4))
    }
    
    func testOldestEntriesEvictedFirstFIFO() {
        let cache = ProgressCalculatorCache(limit: 3)
        let calc = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        
        cache.insert(calc, for: 1, protecting: nil)
        cache.insert(calc, for: 2, protecting: nil)
        cache.insert(calc, for: 3, protecting: nil)
        
        XCTAssertEqual(cache.cachedChapterIds, [1, 2, 3])
        
        cache.insert(calc, for: 4, protecting: nil)
        XCTAssertEqual(cache.cachedChapterIds, [2, 3, 4])
        
        cache.insert(calc, for: 5, protecting: nil)
        XCTAssertEqual(cache.cachedChapterIds, [3, 4, 5])
    }
    
    func testCurrentChapterIsNeverEvicted() {
        let cache = ProgressCalculatorCache(limit: 3)
        let calc = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        
        // Fill cache, 1 is oldest
        cache.insert(calc, for: 1, protecting: 1)
        cache.insert(calc, for: 2, protecting: 1)
        cache.insert(calc, for: 3, protecting: 1)
        
        XCTAssertEqual(cache.cachedChapterIds, [1, 2, 3])
        
        // Insert 4, 1 is oldest but protected, so 2 should be evicted
        cache.insert(calc, for: 4, protecting: 1)
        XCTAssertEqual(cache.count, 3)
        XCTAssertTrue(cache.cachedChapterIds.contains(1), "Chapter 1 should be protected")
        XCTAssertFalse(cache.cachedChapterIds.contains(2), "Chapter 2 should be evicted instead of 1")
        XCTAssertEqual(cache.cachedChapterIds, [1, 3, 4])
        
        // Insert 5, 1 is still protected, 3 should be evicted
        cache.insert(calc, for: 5, protecting: 1)
        XCTAssertEqual(cache.cachedChapterIds, [1, 4, 5])
        XCTAssertFalse(cache.cachedChapterIds.contains(3))
    }
    
    func testReAccessingChapterCreatesNewEntryOrUpdatesOrder() {
        // In the current implementation of ProgressCalculatorCache.insert:
        // if calculators[chapterId] == nil { order.append(chapterId) }
        // This means re-inserting an existing ID doesn't move it to the end of FIFO.
        // Let's check if that's what we want. The requirement says FIFO.
        // Usually FIFO means based on first insertion.
        
        let cache = ProgressCalculatorCache(limit: 3)
        let calc = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        
        cache.insert(calc, for: 1, protecting: nil)
        cache.insert(calc, for: 2, protecting: nil)
        cache.insert(calc, for: 3, protecting: nil)
        
        // 1 is oldest. Re-insert 1.
        cache.insert(calc, for: 1, protecting: nil)
        
        // Insert 4. 1 is still the first in 'order' if we don't move it.
        cache.insert(calc, for: 4, protecting: nil)
        
        XCTAssertFalse(cache.cachedChapterIds.contains(1), "1 should still be evicted first if FIFO is based on first insertion")
    }

    func testReAccessingEvictedChapterCreatesNewCalculator() {
        // This is more of a test of how the cache is used, but we can verify it here.
        let cache = ProgressCalculatorCache(limit: 2)
        let calc1 = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        let calc2 = ChapterProgressCalculator(wordCounts: [20], totalWords: 20)
        let calc3 = ChapterProgressCalculator(wordCounts: [30], totalWords: 30)
        
        cache.insert(calc1, for: 1, protecting: nil)
        cache.insert(calc2, for: 2, protecting: nil)
        
        // Evict 1
        cache.insert(calc3, for: 3, protecting: nil)
        XCTAssertNil(cache.get(for: 1))
        
        // Re-insert 1
        let calc1New = ChapterProgressCalculator(wordCounts: [10], totalWords: 10)
        cache.insert(calc1New, for: 1, protecting: nil)
        XCTAssertNotNil(cache.get(for: 1))
        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.cachedChapterIds.contains(2))
    }
}
