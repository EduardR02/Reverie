import Foundation

struct BlockLocation: Equatable, Comparable {
    let blockId: Int
    let offset: Double

    static func < (lhs: BlockLocation, rhs: BlockLocation) -> Bool {
        if lhs.blockId != rhs.blockId { return lhs.blockId < rhs.blockId }
        return lhs.offset < rhs.offset
    }
}

struct ChapterProgressCalculator {
    private let wordCounts: [Int]
    private let prefixWords: [Int]
    public let totalWords: Int

    init(wordCounts: [Int], totalWords: Int) {
        self.wordCounts = wordCounts
        self.totalWords = max(0, totalWords)
        var prefix: [Int] = [0]
        prefix.reserveCapacity(wordCounts.count + 1)
        var running = 0
        for count in wordCounts {
            running += max(0, count)
            prefix.append(running)
        }
        self.prefixWords = prefix
    }

    func percent(for location: BlockLocation) -> Double {
        guard totalWords > 0, !wordCounts.isEmpty else { return 0 }

        let clampedBlockId = min(max(location.blockId, 1), wordCounts.count)
        let blockIndex = clampedBlockId - 1
        let blockWords = wordCounts[blockIndex]
        let wordsBefore = prefixWords[blockIndex]
        let clampedOffset = min(max(location.offset, 0), 1)

        let currentWords = Double(wordsBefore) + (Double(blockWords) * clampedOffset)
        let percent = currentWords / Double(totalWords)
        return min(max(percent, 0), 1)
    }

    func totalWords(upTo location: BlockLocation) -> Double {
        guard !wordCounts.isEmpty else { return 0 }
        let clampedBlockId = min(max(location.blockId, 1), wordCounts.count)
        let blockIndex = clampedBlockId - 1
        let blockWords = wordCounts[blockIndex]
        let wordsBefore = prefixWords[blockIndex]
        let clampedOffset = min(max(location.offset, 0), 1)
        return Double(wordsBefore) + (Double(blockWords) * clampedOffset)
    }
}
