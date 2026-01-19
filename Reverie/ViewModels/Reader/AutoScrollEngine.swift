import Foundation
import SwiftUI

@Observable @MainActor
final class AutoScrollEngine {
    // Observable state (View reads these directly)
    private(set) var isActive = false
    private(set) var isCountingDown = false
    private(set) var countdownTargetDate: Date?
    private(set) var countdownDuration: TimeInterval = 0
    private(set) var showIndicator = false
    
    // Dependencies
    private var speedTracker: ReadingSpeedTracker?
    private var settings: UserSettings?
    
    // Internal state
    private var markers: [MarkerInfo] = []
    private var currentOffset: Double = 0
    private var viewportHeight: Double = 0
    private var scrollHeight: Double = 0
    private(set) var lastTargetY: Double?
    
    func configure(
        speedTracker: ReadingSpeedTracker,
        settings: UserSettings
    ) {
        self.speedTracker = speedTracker
        self.settings = settings
    }
    
    func start() {
        isActive = true
    }
    
    func stop() {
        isActive = false
        cancelCountdown()
    }
    
    func cancelCountdown() {
        isCountingDown = false
        showIndicator = false
        countdownTargetDate = nil
        lastTargetY = nil
    }
    
    func updateScrollPosition(
        offset: Double,
        viewportHeight: Double,
        scrollHeight: Double,
        isProgrammatic: Bool = false
    ) {
        self.currentOffset = offset
        if viewportHeight > 0 { self.viewportHeight = viewportHeight }
        self.scrollHeight = scrollHeight

        // Cancel countdown on any programmatic scroll (annotation jump, etc.)
        if isProgrammatic {
            cancelCountdown()
            return
        }

        // Cancel if manual scroll detected during countdown (not near expected target)
        let isNearTarget = abs(offset - (lastTargetY ?? -9999)) < 10
        if !isNearTarget {
            cancelCountdown()
        }

        if let target = lastTargetY, offset >= target - 10 {
            cancelCountdown()
        }
    }
    
    func updateMarkers(_ markers: [MarkerInfo]) {
        self.markers = markers
    }
    
    func calculateScrollAmount(
        currentOffset: Double,
        currentLocation: BlockLocation?,
        calculator: ChapterProgressCalculator?
    ) -> Double? {
        guard isActive,
              settings != nil,
              let speedTracker = speedTracker,
              !speedTracker.isPaused,
              (speedTracker.confidence >= 0.5 || currentOffset < 50 || speedTracker.isLocked || speedTracker.manualAutoScrollWPM > 0),
              let calculator = calculator,
              viewportHeight > 0 else {
            return nil
        }
        
        let now = Date()
        
        if isCountingDown {
            if let targetDate = countdownTargetDate, now >= targetDate {
                let amount = (lastTargetY ?? currentOffset) - currentOffset
                cancelCountdown()
                return amount
            }
            
            if !showIndicator, let targetDate = countdownTargetDate,
               now >= targetDate.addingTimeInterval(-countdownDuration) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showIndicator = true
                }
            }
            return nil
        }
        
        if let last = lastTargetY, abs(currentOffset - last) < 10 {
            return nil
        }
        
        var targetY = currentOffset + viewportHeight * 0.8
        var targetMarker: MarkerInfo?
        
        if let firstMarker = markers.first(where: { 
            $0.y > currentOffset + viewportHeight * 0.4 + 10 && 
            $0.y <= targetY + viewportHeight * 0.4 
        }) {
            targetY = firstMarker.y - (viewportHeight * 0.4)
            targetMarker = firstMarker
        }
        
        let maxScroll = max(0, scrollHeight - viewportHeight)
        targetY = min(targetY, maxScroll)
        
        if targetY <= currentOffset + 10 { return nil }
        
        let startWords = calculator.totalWords(upTo: currentLocation ?? BlockLocation(blockId: 1, offset: 0))
        
        let endWords: Double
        if let marker = targetMarker {
            endWords = calculator.totalWords(upTo: BlockLocation(blockId: marker.blockId, offset: 0))
        } else {
            let scrollRange = scrollHeight - viewportHeight
            endWords = scrollRange > 0 ? Double(calculator.totalWords) * (targetY / scrollRange) : Double(calculator.totalWords)
        }
        
        let wordsInRange = max(1, Int(endWords - startWords))
        var delay = speedTracker.calculateScrollDelay(wordsInView: wordsInRange)
        
        if targetMarker?.type == "image" {
            delay += 8
        }
        
        delay = min(max(delay, 3), 120)
        
        isCountingDown = true
        lastTargetY = targetY
        countdownDuration = min(2.2, delay * 0.25)
        countdownTargetDate = now.addingTimeInterval(delay)
        
        return nil
    }
}
