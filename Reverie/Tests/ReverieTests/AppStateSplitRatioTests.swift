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

}
