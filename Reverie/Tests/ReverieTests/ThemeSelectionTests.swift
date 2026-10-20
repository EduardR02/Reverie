import XCTest
@testable import Reverie

final class ThemeSelectionTests: XCTestCase {
    private var originalUserSettings: Data?
    private var originalCustomThemes: Data?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        originalUserSettings = defaults.data(forKey: "userSettings")
        originalCustomThemes = defaults.data(forKey: "customThemes")
        defaults.removeObject(forKey: "userSettings")
        defaults.removeObject(forKey: "customThemes")
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let originalUserSettings {
            defaults.set(originalUserSettings, forKey: "userSettings")
        } else {
            defaults.removeObject(forKey: "userSettings")
        }
        if let originalCustomThemes {
            defaults.set(originalCustomThemes, forKey: "customThemes")
        } else {
            defaults.removeObject(forKey: "customThemes")
        }
        super.tearDown()
    }


    func testSavedThemeSelectionRestoresBlackAndExistingVariants() {
        for name in ["Rose Pine", "Rose Pine Moon", "Rose Pine Dawn", "Rose Pine Black"] {
            var settings = UserSettings()
            settings.theme = name
            settings.save()

            let restored = UserSettings.load()
            let manager = ThemeManager()
            manager.setTheme(restored.theme)

            XCTAssertEqual(restored.theme, name)
            XCTAssertEqual(manager.current.name, name)
        }
    }

    func testFreshAndLegacyDefaultUseBlackButExplicitChoicesSurvive() throws {
        XCTAssertEqual(UserSettings.load().theme, "Rose Pine Black")
        let legacy = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"theme":"Rose Pine","fontSize":19}"#.utf8))
        XCTAssertEqual(legacy.theme, "Rose Pine Black")
        XCTAssertEqual(legacy.fontSize, 19)

        for name in ["Rose Pine Moon", "Rose Pine Dawn", "My neutral theme"] {
            let data = try JSONSerialization.data(withJSONObject: ["theme": name])
            XCTAssertEqual(try JSONDecoder().decode(UserSettings.self, from: data).theme, name)
        }

        var selectedOriginal = legacy
        selectedOriginal.theme = "Rose Pine"
        selectedOriginal.save()
        XCTAssertEqual(UserSettings.load().theme, "Rose Pine")
    }

    func testRemovingSelectedCustomThemeFallsBackToBlack() throws {
        let manager = ThemeManager()
        XCTAssertEqual(manager.current.name, "Rose Pine Black")
        let custom = try manager.addCustomTheme(from: themeJSON(name: "Temporary custom theme"))
        manager.setTheme(custom.name)
        manager.removeCustomTheme(name: custom.name)
        XCTAssertEqual(manager.current.name, "Rose Pine Black")
    }

    func testImportCannotReplaceBlackBuiltInOrChangeCurrentSelection() throws {
        let manager = ThemeManager()
        manager.setTheme("Rose Pine Moon")

        XCTAssertThrowsError(try manager.addCustomTheme(from: themeJSON(name: "Rose Pine Black"))) { error in
            guard case ThemeImportError.nameConflict(let name) = error else {
                return XCTFail("Expected built-in name conflict, got \(error)")
            }
            XCTAssertEqual(name, "Rose Pine Black")
        }

        XCTAssertEqual(manager.current.name, "Rose Pine Moon")
        XCTAssertFalse(manager.isCustomTheme(name: "Rose Pine Black"))
        XCTAssertEqual(manager.availableThemes.filter { $0.name == "Rose Pine Black" }.count, 1)
        XCTAssertNil(UserDefaults.standard.data(forKey: "customThemes"))
    }

    func testDistinctCustomThemeStillImportsAndPersistsAlongsideBlack() throws {
        let manager = ThemeManager()
        manager.setTheme("Rose Pine Black")
        let imported = try manager.addCustomTheme(from: themeJSON(name: "My neutral theme"))

        XCTAssertEqual(manager.current.name, "Rose Pine Black")
        XCTAssertTrue(manager.isCustomTheme(name: imported.name))

        let restored = ThemeManager()
        XCTAssertTrue(restored.isCustomTheme(name: imported.name))
        restored.setTheme(imported.name)
        XCTAssertEqual(restored.current.name, imported.name)
        restored.setTheme("Rose Pine Black")
        XCTAssertEqual(restored.current.name, "Rose Pine Black")
    }

    private func themeJSON(name: String) throws -> String {
        let colorKeys = [
            "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
            "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
            "brightPurple", "brightCyan", "brightWhite", "background", "foreground"
        ]
        var payload = Dictionary(uniqueKeysWithValues: colorKeys.map { ($0, "#808080") })
        payload["name"] = name
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
