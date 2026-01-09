import XCTest
import GRDB
@testable import Reverie

@MainActor
final class ReaderSessionTests: XCTestCase {
    var session: ReaderSession!
    var appState: AppState!
    var database: DatabaseService!

    override func setUp() async throws {
        try await super.setUp()
        let queue = try! DatabaseQueue()
        database = try! DatabaseService(dbQueue: queue)
        appState = AppState(database: database)
        session = ReaderSession()
    }

    func test_setup_initializesChildComponents() {
        session.setup(with: appState)
        XCTAssertNotNil(session.analyzer)
        XCTAssertTrue(session.autoScroll.isActive) 
    }

    func test_handleAnnotationClick_setsScrollTarget() {
        let annotation = Annotation(id: 123, chapterId: 1, type: .science, title: "Title", content: "Content", sourceBlockId: 1)
        session.handleAnnotationClick(annotation)
        XCTAssertEqual(session.currentAnnotationId, 123)
        XCTAssertEqual(session.externalTabSelection, .insights)
    }

    func test_cleanup_stopsAllTasks() {
        session.setup(with: appState)
        session.cleanup()
        XCTAssertFalse(session.autoScroll.isActive)
    }
}
