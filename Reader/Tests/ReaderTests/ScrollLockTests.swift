import XCTest
import WebKit
@testable import Reader

@MainActor
final class ScrollLockTests: XCTestCase {
    var webView: WKWebView!
    var messageHandler: MockMessageHandler!
    
    override func setUp() async throws {
        let config = WKWebViewConfiguration()
        messageHandler = MockMessageHandler()
        config.userContentController.add(messageHandler, name: "readerBridge")
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
        
        let jsSource = try loadReaderBridgeSource()
        
        let mocks = """
        window.scrollY = 0;
        window.innerHeight = 1000;
        window.scrollTo = function(opts) { 
            window.scrollY = opts.top; 
            const ev = new Event('scroll');
            window.dispatchEvent(ev);
        };
        document.documentElement = { 
            get scrollHeight() { return 5000; }
        };
        
        Element.prototype.getBoundingClientRect = function() {
            const top = parseFloat(this.style.top) || 0;
            const height = parseFloat(this.style.height) || 10;
            return {
                top: top - window.scrollY,
                bottom: top + height - window.scrollY,
                height: height,
                width: 10, left: 0, right: 10
            };
        };
        """
        
        try await webView.evaluateJavaScript(mocks + jsSource)
        messageHandler.messages.removeAll()
    }
    
    func testStickyLockActivation() async throws {
        try await webView.evaluateJavaScript("""
            document.body.innerHTML = '<div class="annotation-marker" data-annotation-id="10" style="position:absolute; top:500px;"></div>';
        """)
        messageHandler.messages.removeAll()
        try await webView.evaluateJavaScript("programmatic.start('annotation-10', 500)")
        
        let isSticky = try await webView.evaluateJavaScript("programmatic.isSticky()") as? Bool
        XCTAssertTrue(isSticky ?? false)
        
        let msg = try await getLatestScrollMessage()
        XCTAssertEqual(parseId(msg["annotationId"]), 10)
        XCTAssertTrue(msg["isProgrammatic"] as? Bool ?? false)
    }
    
    func testStrictLockExclusivity() async throws {
        let setup = """
        document.body.innerHTML = `
            <div class="annotation-marker" data-annotation-id="5" style="position:absolute; top:100px;"></div>
            <div class="annotation-marker" data-annotation-id="10" style="position:absolute; top:500px;"></div>
            <div class="image-marker" data-image-id="20" style="position:absolute; top:110px;"></div>
        `;
        """
        try await webView.evaluateJavaScript(setup)
        messageHandler.messages.removeAll()
        
        try await webView.evaluateJavaScript("programmatic.start('annotation-10', 500)")
        
        let msg = try await getLatestScrollMessage()
        XCTAssertEqual(parseId(msg["annotationId"]), 10)
        
        // Locked type should be present, others should be null/NSNull
        let imageId = msg["imageId"]
        XCTAssertTrue(imageId == nil || imageId is NSNull)
    }
    
    func testManualDriftReleasesLock() async throws {
        try await webView.evaluateJavaScript("""
            document.body.innerHTML = '<div class="annotation-marker" data-annotation-id="10" style="position:absolute; top:500px;"></div>';
            programmatic.start('annotation-10', 500);
        """)
        messageHandler.messages.removeAll()
        
        try await webView.evaluateJavaScript("""
            window.scrollY = 550; 
            programmatic.noteScroll(550);
        """)
        
        let isSticky = try await webView.evaluateJavaScript("programmatic.isSticky()") as? Bool
        XCTAssertFalse(isSticky ?? true)
        
        let msg = try await getLatestScrollMessage()
        XCTAssertFalse(msg["isProgrammatic"] as? Bool ?? true)
    }

    // --- Helpers ---
    
    private func parseId(_ value: Any?) -> Int64? {
        if let str = value as? String { return Int64(str) }
        if let int = value as? Int64 { return int }
        if let int = value as? Int { return Int64(int) }
        return nil
    }
    
    private func loadReaderBridgeSource() throws -> String {
        if let url = Bundle.main.url(forResource: "ReaderBridge", withExtension: "js") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("Reader/Resources/ReaderBridge.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    private func getLatestScrollMessage() async throws -> [String: Any] {
        let start = Date()
        while Date().timeIntervalSince(start) < 1.0 {
            if let msg = messageHandler.popLatestMessage() {
                return msg
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timeout waiting for bridge message")
        return [:]
    }
}

@MainActor
class MockMessageHandler: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["type"] as? String == "scrollPosition" {
            messages.append(body)
        }
    }
    func popLatestMessage() -> [String: Any]? {
        guard !messages.isEmpty else { return nil }
        let msg = messages.removeLast()
        messages.removeAll()
        return msg
    }
}