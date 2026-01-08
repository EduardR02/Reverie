import XCTest
@testable import Reverie

final class ReadingSpeedTrackerPauseTests: XCTestCase {

    func testPauseDurationRecordedCorrectly() {
        let tracker = ReadingSpeedTracker()

        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0)
        tracker.updateSession(scrollPercent: 0.1)

        tracker.startPause(reason: .manual)
        Thread.sleep(forTimeInterval: 0.1)
        tracker.endPause(reason: .manual)

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
        tracker.endPause(reason: .manual)

        tracker.startPause(reason: .manual)
        Thread.sleep(forTimeInterval: 0.05)
        tracker.endPause(reason: .manual)

        guard let session = tracker.currentSession else {
            XCTFail("Session should still be active")
            return
        }

        XCTAssertEqual(session.pauses.count, 2)
        XCTAssertGreaterThan(session.pauses[0].duration, 0.03)
        XCTAssertGreaterThan(session.pauses[1].duration, 0.03)
    }

    func testPauseStacksDifferentReasons() {
        let tracker = ReadingSpeedTracker()
        
        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0)
        
        tracker.startPause(reason: .chatting)
        tracker.startPause(reason: .viewingImage)
        
        tracker.endPause(reason: .chatting)
        XCTAssertTrue(tracker.isPaused, "Should still be paused because viewingImage is active")
        XCTAssertEqual(tracker.currentSession?.pauses.count, 0)
        
        tracker.endPause(reason: .viewingImage)
        XCTAssertFalse(tracker.isPaused, "Should be unpaused now")
        XCTAssertEqual(tracker.currentSession?.pauses.count, 1)
    }

    func testEndAllPausesClearsEverything() {
        let tracker = ReadingSpeedTracker()
        
        tracker.startSession(chapterId: 1, wordCount: 1000, startPercent: 0)
        
        tracker.startPause(reason: .chatting)
        tracker.startPause(reason: .viewingImage)
        
        tracker.endAllPauses()
        XCTAssertFalse(tracker.isPaused)
        XCTAssertEqual(tracker.currentSession?.pauses.count, 1)
        XCTAssertEqual(tracker.currentSession?.pauses[0].reason, .manual)
    }

    func testEndAllPausesClearsMultipleReasons() {
        let tracker = ReadingSpeedTracker()
        tracker.startSession(chapterId: 1, wordCount: 1000)
        
        // Stack multiple pause reasons
        tracker.startPause(reason: .chatting)
        tracker.startPause(reason: .viewingImage)
        tracker.startPause(reason: .viewingInsights)
        
        XCTAssertTrue(tracker.isPaused)
        
        // End all at once
        tracker.endAllPauses()
        
        XCTAssertFalse(tracker.isPaused)
        XCTAssertTrue(tracker.activePauseReasons.isEmpty)
    }
}
