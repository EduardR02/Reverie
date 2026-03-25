import XCTest
import GRDB
@testable import Reverie

final class AppStateSplitRatioTests: XCTestCase {
    private let splitRatioKey = "splitRatio"
    private var originalSplitRatio: Any?
    private var originalUserSettings: Data?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        originalSplitRatio = defaults.object(forKey: splitRatioKey)
        originalUserSettings = defaults.data(forKey: "userSettings")
        defaults.removeObject(forKey: splitRatioKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let originalSplitRatio {
            defaults.set(originalSplitRatio, forKey: splitRatioKey)
        } else {
            defaults.removeObject(forKey: splitRatioKey)
        }

        if let originalUserSettings {
            defaults.set(originalUserSettings, forKey: "userSettings")
        } else {
            defaults.removeObject(forKey: "userSettings")
        }
        super.tearDown()
    }

    @MainActor
    func testSplitRatioPersistsImmediatelyWhenChanged() throws {
        let appState = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()))

        appState.splitRatio = 0.72

        let persisted = UserDefaults.standard.object(forKey: splitRatioKey) as? Double
        XCTAssertEqual(persisted ?? 0, 0.72, accuracy: 0.0001)

        let reloaded = AppState(database: try DatabaseService(dbQueue: DatabaseQueue()))
        XCTAssertEqual(reloaded.splitRatio, 0.72, accuracy: 0.0001)
    }

    func testReaderSplitLayoutIdentityChangesWithSplitRatio() {
        let original = ReaderSplitLayout(totalWidth: 1200, splitRatio: 0.65)
        let updated = ReaderSplitLayout(totalWidth: 1200, splitRatio: 0.72)

        XCTAssertEqual(original.readerIdealWidth, 780, accuracy: 0.001)
        XCTAssertEqual(original.aiIdealWidth, 420, accuracy: 0.001)
        XCTAssertEqual(updated.readerIdealWidth, 864, accuracy: 0.001)
        XCTAssertEqual(updated.aiIdealWidth, 336, accuracy: 0.001)
        XCTAssertNotEqual(original.identity, updated.identity)
    }

    func testReaderSplitLayoutWaitsForPositiveWidthBeforeCreatingSplitView() throws {
        XCTAssertNil(ReaderSplitLayout.make(totalWidth: 0, splitRatio: 0.65))

        let layout = try XCTUnwrap(ReaderSplitLayout.make(totalWidth: 1200, splitRatio: 0.65))
        XCTAssertEqual(layout.readerIdealWidth, 780, accuracy: 0.001)
        XCTAssertEqual(layout.aiIdealWidth, 420, accuracy: 0.001)
        XCTAssertEqual(layout.identity, ReaderSplitLayout(totalWidth: 1200, splitRatio: 0.65).identity)
    }
}
