import Foundation

/// Manages a cache of ChapterProgressCalculators with FIFO eviction.
/// Ensures the cache doesn't exceed a specific size while protecting
/// the currently active chapter from being evicted.
class ProgressCalculatorCache {
    private var calculators: [Int64: ChapterProgressCalculator] = [:]
    private var order: [Int64] = []
    private let limit: Int

    init(limit: Int = 20) {
        self.limit = limit
    }

    /// Returns the calculator for a given chapter ID, if it exists in cache.
    func get(for chapterId: Int64) -> ChapterProgressCalculator? {
        return calculators[chapterId]
    }

    /// Inserts a calculator into the cache.
    /// - Parameters:
    ///   - calculator: The calculator to cache.
    ///   - chapterId: ID of the chapter.
    ///   - currentChapterId: The ID of the currently active chapter to protect from eviction.
    func insert(_ calculator: ChapterProgressCalculator, for chapterId: Int64, protecting currentChapterId: Int64?) {
        if calculators[chapterId] == nil {
            order.append(chapterId)
        }
        calculators[chapterId] = calculator

        while order.count > limit {
            // Find the oldest entry that isn't the current chapter
            if let indexToRemove = order.firstIndex(where: { $0 != currentChapterId }) {
                let idToRemove = order.remove(at: indexToRemove)
                calculators.removeValue(forKey: idToRemove)
            } else {
                // If every entry in the order is the current chapter (shouldn't happen with unique IDs)
                // or if we somehow can't find anything else to remove, stop to avoid infinite loop.
                break
            }
        }
    }

    /// Number of items currently in the cache.
    var count: Int {
        return order.count
    }

    /// Returns all cached chapter IDs in FIFO order.
    var cachedChapterIds: [Int64] {
        return order
    }
}
