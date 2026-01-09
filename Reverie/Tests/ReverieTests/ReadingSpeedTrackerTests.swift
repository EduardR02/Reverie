import XCTest
@testable import Reverie

final class ReadingSpeedTrackerTests: XCTestCase {
    func testWordsReadUsesStartPercent() {
        let tracker = ReadingSpeedTracker()
        let start = Date(timeIntervalSince1970: 0)

        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0.2, now: start)
        tracker.updateSession(scrollPercent: 0.5, now: start)

        let result = tracker.endSession(now: start)
        XCTAssertEqual(result?.words, 300)
    }

    func testIdleThresholdStopsCountingTime() {
        let tracker = ReadingSpeedTracker()
        let start = Date(timeIntervalSince1970: 0)

        tracker.startSession(chapterId: 1, wordCount: 100, startPercent: 0, now: start)
        tracker.updateSession(scrollPercent: 0.1, now: start)

        _ = tracker.tick(now: start.addingTimeInterval(30))

        let idleTime = ReadingSpeedTracker.idleThresholdSeconds + 30
        _ = tracker.tick(now: start.addingTimeInterval(idleTime))

        let result = tracker.endSession(now: start.addingTimeInterval(idleTime + 30))
        XCTAssertEqual(result?.seconds ?? 0, 30, accuracy: 0.1)
    }

    func testLockPreventsUpdates() {
        let tracker = ReadingSpeedTracker()
        tracker.reset()
        if tracker.isLocked { tracker.toggleLock() }
        
        let start = Date(timeIntervalSince1970: 0)

        // Set initial speed
        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0, now: start)
        tracker.updateSession(scrollPercent: 0.1, now: start.addingTimeInterval(60)) // 100 words in 1 min = 100 WPM
        _ = tracker.endSession(now: start.addingTimeInterval(60))
        
        let initialAvg = tracker.averageWPM
        XCTAssertGreaterThan(initialAvg, 0)
        
        // Lock it
        tracker.toggleLock()
        XCTAssertTrue(tracker.isLocked)
        
        // Try to update with very fast session
        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0.1, now: start.addingTimeInterval(120))
        tracker.updateSession(scrollPercent: 0.9, now: start.addingTimeInterval(180)) // 800 words in 1 min = 800 WPM
        _ = tracker.endSession(now: start.addingTimeInterval(180))
        
        XCTAssertEqual(tracker.averageWPM, initialAvg, "Average WPM should not change when locked")
        
        // Try adjustment
        tracker.applyAdjustment(.readingSlowly)
        XCTAssertEqual(tracker.averageWPM, initialAvg, "Average WPM should not change with adjustment when locked")
    }
}
