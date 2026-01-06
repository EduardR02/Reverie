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
}
