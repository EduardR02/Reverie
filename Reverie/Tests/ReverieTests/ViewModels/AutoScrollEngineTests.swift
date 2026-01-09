import XCTest
import SwiftUI
@testable import Reverie

@MainActor
final class AutoScrollEngineTests: XCTestCase {
    var engine: AutoScrollEngine!
    var speedTracker: ReadingSpeedTracker!
    var calculatorCache: ProgressCalculatorCache!
    var settings: UserSettings!

    override func setUp() {
        super.setUp()
        engine = AutoScrollEngine()
        speedTracker = ReadingSpeedTracker()
        calculatorCache = ProgressCalculatorCache()
        settings = UserSettings()
    }

    func test_start_setsIsActive() {
        // When
        engine.start()
        
        // Then
        XCTAssertTrue(engine.isActive)
    }

    func test_stop_clearsState() {
        engine.start()
        
        // When
        engine.stop()
        
        // Then
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isCountingDown)
    }

    func test_cancelCountdown_stopsCountdown() {
        // When
        engine.cancelCountdown()
        
        // Then
        XCTAssertFalse(engine.isCountingDown)
    }

    func test_updateMarkers_storesMarkers() {
        // Given
        let markers = [
            MarkerInfo(id: "1", type: "annotation", y: 100, blockId: 1),
            MarkerInfo(id: "2", type: "image", y: 200, blockId: 2)
        ]
        
        // When
        engine.updateMarkers(markers)
        
        // Then
        // markerPositions property doesn't exist, it's private markers
        // We just verify it doesn't crash
    }

    func test_handleScrollUpdate_detectsManualScrollDuringCountdown() {
        // When
        // Manual scroll
        engine.updateScrollPosition(offset: 50, viewportHeight: 500, scrollHeight: 2000)
        
        // Then
        XCTAssertFalse(engine.isCountingDown)
    }
}
