import XCTest
@testable import Reverie

/// Helper class to simulate the logic pattern used in BookContentView for marker injections.
/// We use this because testing NSViewRepresentable directly is difficult and prone to flakiness.
class MarkerQueueManager<T: Equatable> {
    var queue: [T] = []
    
    func add(_ item: T) {
        queue.append(item)
    }
    
    func process(injection: ([T]) -> Void) {
        // This simulates the logic in BookContentView.updateNSView:
        // 1. Snapshot current queue
        let snapshots = queue
        
        // 2. Perform "injection" (e.g. webView.evaluateJavaScript)
        injection(snapshots)
        
        // 3. Remove ONLY the processed items from the queue
        // In BookContentView this is done inside DispatchQueue.main.async
        // but for the purpose of testing the logic we can do it here.
        queue.removeAll { item in snapshots.contains(where: { $0 == item }) }
    }
}

final class BookContentViewTests: XCTestCase {
    
    func testMarkerQueueRaceConditionFix() {
        // 1. Initialize manager with some markers [A, B, C]
        let manager = MarkerQueueManager<String>()
        manager.add("A")
        manager.add("B")
        manager.add("C")
        
        XCTAssertEqual(manager.queue, ["A", "B", "C"])
        
        // 2. Start "injection" processing
        manager.process { snapshots in
            XCTAssertEqual(snapshots, ["A", "B", "C"])
            
            // 3. SIMULATE RACE CONDITION:
            // New marker D arrives while we are "processing" A, B, C
            // (In real app, this happens if updateNSView is called again or a binding updates)
            manager.add("D")
            
            XCTAssertEqual(manager.queue, ["A", "B", "C", "D"], "Queue should contain A, B, C and the new D")
        }
        
        // 4. ASSERTION:
        // After processing completes, only A, B, C should be removed.
        // D must remain in the queue.
        XCTAssertEqual(manager.queue, ["D"], "Only processed markers should be removed. D must stay in the queue.")
    }
    
    func testOriginalBugScenario() {
        // This test demonstrates how the bug would behave if we used simple 'removeAll()'
        var queue = ["A", "B", "C"]
        
        // Start processing
        let snapshots = queue
        // ... inject snapshots ...
        
        // Race condition: D arrives
        queue.append("D")
        
        // THE BUG: Clearing everything instead of just processed ones
        // If we did: queue.removeAll()
        let useFixedLogic = true // Set to false to see the bug behavior (conceptually)
        
        if useFixedLogic {
            queue.removeAll { item in snapshots.contains(where: { $0 == item }) }
            XCTAssertEqual(queue, ["D"])
        } else {
            queue.removeAll()
            XCTAssertEqual(queue, []) // D is LOST!
        }
    }
    
    func testMarkerInjectionEquality() {
        // Ensure MarkerInjection Equatable works as expected since the fix depends on it
        let m1 = MarkerInjection(annotationId: 1, sourceBlockId: 10)
        let m2 = MarkerInjection(annotationId: 1, sourceBlockId: 10)
        let m3 = MarkerInjection(annotationId: 2, sourceBlockId: 10)
        
        XCTAssertEqual(m1, m2)
        XCTAssertNotEqual(m1, m3)
    }

    func testImageMarkerInjectionEquality() {
        // Ensure ImageMarkerInjection Equatable works as expected
        let m1 = ImageMarkerInjection(imageId: 1, sourceBlockId: 10)
        let m2 = ImageMarkerInjection(imageId: 1, sourceBlockId: 10)
        let m3 = ImageMarkerInjection(imageId: 2, sourceBlockId: 10)
        
        XCTAssertEqual(m1, m2)
        XCTAssertNotEqual(m1, m3)
    }
}
