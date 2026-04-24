import Foundation
import GRDB

// MARK: - Progress Tracking

@MainActor
final class ProgressTracker {
    private struct PendingProgress {
        let bookId: Int64
        let chapter: Chapter
        let currentPercent: Double
        let furthestPercent: Double
        let scrollOffset: Double
    }

    private struct BookProgressCache {
        var totalWords: Int
        var wordsRead: Int
        var chapterWordCounts: [Int64: Int]
    }

    private var pendingProgress: PendingProgress?
    private var pendingProgressSaveTask: Task<Void, Never>?
    private var maxScrollCache: [Int64: Double] = [:]
    private var bookProgressCache: [Int64: BookProgressCache] = [:]

    private let database: DatabaseService
    var onWordsRead: ((Int) -> Void)?

    init(database: DatabaseService, onWordsRead: ((Int) -> Void)? = nil) {
        self.database = database
        self.onWordsRead = onWordsRead
    }

    // MARK: - Cache

    func updateBookProgressCache(book: Book, chapters: [Chapter]) {
        guard let bookId = book.id else { return }

        var totalWords = 0
        var wordsRead = 0
        var wordCounts: [Int64: Int] = [:]

        for chapter in chapters {
            guard let chapterId = chapter.id else { continue }
            let wordCount = max(0, chapter.wordCount)
            totalWords += wordCount

            let maxPercent = min(max(chapter.maxScrollReached, 0), 1)
            let readWords = Int((Double(wordCount) * maxPercent).rounded())
            wordsRead += readWords
            wordCounts[chapterId] = wordCount

            let cachedMax = maxScrollCache[chapterId] ?? 0
            if maxPercent > cachedMax {
                maxScrollCache[chapterId] = maxPercent
            }
        }

        if totalWords > 0 {
            wordsRead = min(wordsRead, totalWords)
        }

        bookProgressCache[bookId] = BookProgressCache(
            totalWords: totalWords,
            wordsRead: wordsRead,
            chapterWordCounts: wordCounts
        )
    }

    // MARK: - Recording Progress

    /// Records reading progress and schedules a throttled flush.
    /// - Parameter whenReadyToFlush: Called on the main actor when the throttled flush timer fires.
    ///   The caller should use this to invoke `flushPendingProgress(currentBook:)`.
    func recordReadingProgress(
        chapter: Chapter,
        currentPercent: Double,
        furthestPercent: Double,
        scrollOffset: Double,
        bookId: Int64,
        whenReadyToFlush: @escaping @MainActor () -> Void
    ) {
        guard chapter.id != nil else { return }

        pendingProgress = PendingProgress(
            bookId: bookId,
            chapter: chapter,
            currentPercent: currentPercent,
            furthestPercent: furthestPercent,
            scrollOffset: scrollOffset
        )

        pendingProgressSaveTask?.cancel()
        pendingProgressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                whenReadyToFlush()
            }
        }
    }

    // MARK: - Flushing

    /// Flushes pending progress to the database.
    /// - Parameter currentBook: The book currently being read, if any. Used to avoid a DB fetch.
    /// - Returns: The updated book if it was the `currentBook` and was saved; nil otherwise.
    func flushPendingProgress(currentBook: Book?) -> Book? {
        guard let pending = pendingProgress,
              let chapterId = pending.chapter.id else { return nil }

        let bookId = pending.bookId
        self.pendingProgress = nil
        self.pendingProgressSaveTask?.cancel()
        self.pendingProgressSaveTask = nil

        var book: Book?
        let isCurrentBook = currentBook?.id == bookId
        if isCurrentBook {
            book = currentBook
        } else {
            book = try? database.fetchBook(id: bookId)
        }

        guard var updatedBook = book else { return nil }

        let chapterCount = max(1, updatedBook.chapterCount)
        let chapterIndex = min(max(pending.chapter.index, 0), chapterCount - 1)

        let currentPercent = min(max(pending.currentPercent, 0), 1)
        let furthestPercent = min(max(pending.furthestPercent, 0), 1)
        let effectiveFurthest = max(furthestPercent, currentPercent)
        let previousMax = min(max(maxScrollCache[chapterId] ?? pending.chapter.maxScrollReached, 0), 1)

        if effectiveFurthest > previousMax {
            let cachedWordCount = bookProgressCache[bookId]?.chapterWordCounts[chapterId]
            let wordCount = cachedWordCount ?? pending.chapter.wordCount
            let previousWords = Int((Double(wordCount) * previousMax).rounded())
            let currentWords = Int((Double(wordCount) * effectiveFurthest).rounded())
            let wordDelta = currentWords - previousWords
            if wordDelta > 0 {
                onWordsRead?(wordDelta)
                if var cache = bookProgressCache[bookId], cache.totalWords > 0 {
                    cache.wordsRead = min(cache.totalWords, cache.wordsRead + wordDelta)
                    bookProgressCache[bookId] = cache
                }
            }

            var updatedChapter = pending.chapter
            updatedChapter.maxScrollReached = effectiveFurthest
            try? database.saveChapter(&updatedChapter)
            maxScrollCache[chapterId] = effectiveFurthest
        }

        let overallProgress: Double
        if let cache = bookProgressCache[bookId], cache.totalWords > 0 {
            overallProgress = min(max(Double(cache.wordsRead) / Double(cache.totalWords), 0), 1)
        } else {
            let chapterProgress = Double(chapterIndex) + effectiveFurthest
            overallProgress = min(max(chapterProgress / Double(chapterCount), 0), 1)
        }

        updatedBook.currentChapter = chapterIndex
        updatedBook.currentScrollPercent = currentPercent
        updatedBook.currentScrollOffset = pending.scrollOffset
        updatedBook.progressPercent = overallProgress
        updatedBook.lastReadAt = Date()

        do {
            try database.saveBook(&updatedBook)
            if isCurrentBook {
                return updatedBook
            }
        } catch {
            print("Failed to save book progress: \(error)")
        }

        return nil
    }
}
