import XCTest
@testable import Reverie

final class ReaderBridgeScriptLoaderTests: XCTestCase {
    func testLoadSourceReturnsBundleResourceContents() throws {
        let bundle = try makeBundle(with: "window.__readerBridgeFixture = true;")

        let source = ReaderBridgeScriptLoader.loadSource(primaryBundle: bundle)

        XCTAssertEqual(source, "window.__readerBridgeFixture = true;")
    }

    func testLoadSourceReturnsNilWhenPrimaryBundleMissesWithoutFallback() throws {
        let missingBundle = try makeBundle(named: "MissingReaderBridgeFixture", script: nil)

        XCTAssertNil(ReaderBridgeScriptLoader.loadSource(primaryBundle: missingBundle))
    }

    func testLoadSourceSkipsFallbackBundleWhenPrimaryBundleSucceeds() throws {
        let bundle = try makeBundle(with: "window.__readerBridgeFixture = true;")
        var didResolveFallback = false

        let source = ReaderBridgeScriptLoader.loadSource(primaryBundle: bundle) {
            didResolveFallback = true
            return bundle
        }

        XCTAssertEqual(source, "window.__readerBridgeFixture = true;")
        XCTAssertFalse(didResolveFallback)
    }

    func testLoadSourceUsesFallbackBundleOnlyAfterPrimaryBundlesMiss() throws {
        let fallbackBundle = try makeBundle(with: "window.__readerBridgeFixture = true;")
        let missingBundle = try makeBundle(named: "MissingReaderBridgeFixture", script: nil)
        var didResolveFallback = false

        let source = ReaderBridgeScriptLoader.loadSource(primaryBundle: missingBundle) {
            didResolveFallback = true
            return fallbackBundle
        }

        XCTAssertEqual(source, "window.__readerBridgeFixture = true;")
        XCTAssertTrue(didResolveFallback)
    }

    func testScriptURLReturnsNilWhenBundleDoesNotContainBridgeScript() throws {
        let missingBundle = try makeBundle(named: "MissingReaderBridgeFixture", script: nil)

        XCTAssertNil(ReaderBridgeScriptLoader.scriptURL(in: missingBundle))
    }

    private func makeBundle(with script: String) throws -> Bundle {
        try makeBundle(named: "ReaderBridgeFixture", script: script)
    }

    private func makeBundle(named name: String, script: String?) throws -> Bundle {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("\(name).bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let scriptURL = resourcesURL.appendingPathComponent("ReaderBridge.js")

        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let infoPlist = [
            "CFBundleIdentifier": name,
            "CFBundleName": name,
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )

        try infoPlistData.write(to: infoPlistURL)
        if let script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }

        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}
