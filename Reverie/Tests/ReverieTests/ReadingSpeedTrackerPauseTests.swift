import XCTest
@testable import Reverie

final class ReadingSpeedTrackerPauseTests: XCTestCase {

    func testPauseDurationRecordedCorrectly() {
        let tracker = ReadingSpeedTracker()

        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0)
        tracker.updateSession(scrollPercent: 0.1)

        tracker.startPause(reason: .manual)
        Thread.sleep(forTimeInterval: 0.1)
        tracker.endPause()

        guard let session = tracker.currentSession else {
            XCTFail("Session should still be active")
            return
        }

        XCTAssertEqual(session.pauses.count, 1)
        XCTAssertEqual(session.pauses[0].reason, .manual)
        XCTAssertGreaterThan(session.pauses[0].duration, 0.05)
    }

    func testMultiplePausesAccumulate() {
        let tracker = ReadingSpeedTracker()

        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0)
        tracker.updateSession(scrollPercent: 0.1)

        tracker.startPause(reason: .manual)
        Thread.sleep(forTimeInterval: 0.05)
        tracker.endPause()

        tracker.startPause(reason: .manual)
        Thread.sleep(forTimeInterval: 0.05)
        tracker.endPause()

        guard let session = tracker.currentSession else {
            XCTFail("Session should still be active")
            return
        }

        XCTAssertEqual(session.pauses.count, 2)
        XCTAssertGreaterThan(session.pauses[0].duration, 0.03)
        XCTAssertGreaterThan(session.pauses[1].duration, 0.03)
    }

    func testPauseIgnoresDuplicateStartPauseCalls() {
        let tracker = ReadingSpeedTracker()
        let start = Date(timeIntervalSince1970: 0)

        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0, now: start)
        tracker.startPause(reason: .chatting)
        tracker.startPause(reason: .viewingImage)

        _ = start.addingTimeInterval(30)
        tracker.endPause()

        guard let session = tracker.currentSession else {
            XCTFail("Session should still be active")
            return
        }

        XCTAssertEqual(session.pauses.count, 1)
    }
}
