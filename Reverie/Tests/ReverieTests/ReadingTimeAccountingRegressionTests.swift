import XCTest
@testable import Reverie

final class ReadingTimeAccountingRegressionTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testReturningFromIdleDoesNotCreditTheInactiveInterval() throws {
        let tracker = ReadingSpeedTracker()
        tracker.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(30)), 30)
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(600)), 270)
        tracker.updateSession(scrollPercent: 0.2, now: origin.addingTimeInterval(3_600))
        XCTAssertEqual(try XCTUnwrap(tracker.currentSession).timeSpentSeconds, 300)
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(3_610)), 10)
        XCTAssertEqual(try XCTUnwrap(tracker.currentSession).timeSpentSeconds, 310)
        _ = tracker.discardSession()
    }

    func testIdleAccountingDoesNotDependOnTimerFrequency() throws {
        let sparse = ReadingSpeedTracker()
        let dense = ReadingSpeedTracker()
        sparse.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        dense.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        _ = sparse.tick(now: origin.addingTimeInterval(30))
        _ = sparse.tick(now: origin.addingTimeInterval(330))
        for seconds in stride(from: 30, through: 330, by: 30) {
            _ = dense.tick(now: origin.addingTimeInterval(Double(seconds)))
        }
        XCTAssertEqual(try XCTUnwrap(sparse.currentSession).timeSpentSeconds, 300)
        XCTAssertEqual(try XCTUnwrap(dense.currentSession).timeSpentSeconds, 300)
        _ = sparse.discardSession()
        _ = dense.discardSession()
    }

    func testOverlappingPausesAreExcludedOnceFromTimeAndWPM() throws {
        let tracker = ReadingSpeedTracker()
        tracker.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        tracker.updateSession(scrollPercent: 0.3, now: origin.addingTimeInterval(30))
        tracker.startPause(reason: .chatting, now: origin.addingTimeInterval(30))
        tracker.startPause(reason: .viewingImage, now: origin.addingTimeInterval(40))
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(50)), 0)
        tracker.endPause(reason: .chatting, now: origin.addingTimeInterval(60))
        XCTAssertTrue(tracker.isPaused)
        tracker.endPause(reason: .viewingImage, now: origin.addingTimeInterval(90))
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(120)), 30)
        let session = try XCTUnwrap(tracker.currentSession)
        XCTAssertEqual(session.timeSpentSeconds, 60)
        XCTAssertEqual(session.pauses.count, 1)
        XCTAssertEqual(session.pauses.first?.duration, 60)
        XCTAssertEqual(session.wpm, 300)
        _ = tracker.discardSession()
    }

    func testEndingPausedSessionExcludesOpenPauseAndClearsItsState() throws {
        let tracker = ReadingSpeedTracker()
        tracker.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        tracker.startPause(reason: .manual, now: origin.addingTimeInterval(10))
        let result = try XCTUnwrap(tracker.endSession(now: origin.addingTimeInterval(100)))
        XCTAssertEqual(result.seconds, 10)
        XCTAssertFalse(tracker.isPaused)
        XCTAssertNil(tracker.currentSession)
        tracker.startSession(chapterId: 2, wordCount: 1_000, now: origin.addingTimeInterval(100))
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(110)), 10)
        _ = tracker.discardSession()
    }

    func testStartingAnotherSessionDoesNotInheritOldPause() {
        let tracker = ReadingSpeedTracker()
        tracker.startSession(chapterId: 1, wordCount: 1_000, now: origin)
        tracker.startPause(reason: .manual, now: origin)
        tracker.startSession(chapterId: 2, wordCount: 1_000, now: origin.addingTimeInterval(10))
        XCTAssertFalse(tracker.isPaused)
        XCTAssertEqual(tracker.tick(now: origin.addingTimeInterval(20)), 10)
        _ = tracker.discardSession()
    }
}
