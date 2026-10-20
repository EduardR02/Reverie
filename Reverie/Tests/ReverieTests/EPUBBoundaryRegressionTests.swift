import XCTest
@testable import Reverie

final class EPUBBoundaryRegressionTests: XCTestCase {
    func testSkippedSpineEntriesDoNotLeaveNavigationIndexGaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = try makeEPUB(in: directory)
        let parser = EPUBParser()
        let destination = directory.appendingPathComponent("publication")
        let result = try await parser.parseMetadata(epubURL: epub, destinationURL: destination)
        XCTAssertEqual(result.metadata.chapters.map(\.index), [0, 1])
        XCTAssertEqual(result.metadata.chapters.map(\.title), ["Chapter 1", "Chapter 2"])
        let book = try await parser.parse(epubURL: epub, destinationURL: destination)
        XCTAssertEqual(book.chapters.map(\.index), [0, 1])
    }

    func testOverlappingFootnoteRecognitionEmitsOneEntryPerActualReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = try makeEPUB(in: directory)
        let destination = directory.appendingPathComponent("publication")
        let parser = EPUBParser()
        let result = try await parser.parseMetadata(epubURL: epub, destinationURL: destination)
        let chapter = try parser.parseChapter(
            try XCTUnwrap(result.metadata.chapters.first),
            opfDir: destination.appendingPathComponent("OPS"), rootURL: destination
        )
        XCTAssertEqual(chapter.footnotes.count, 2)
        XCTAssertEqual(chapter.footnotes.map(\.refId), ["fn1", "fn1"])
        XCTAssertEqual(chapter.footnotes.map(\.sourceBlockId), [1, 2])
        XCTAssertEqual(chapter.footnotes.map(\.content), ["Footnote content.", "Footnote content."])
    }

    private func makeEPUB(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source")
        let files = [
            "META-INF/container.xml": """
                <container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>
                """,
            "OPS/book.opf": """
                <package><metadata><title>Fixture</title></metadata><manifest>
                <item id="bonus" href="bonus.xhtml" media-type="application/xhtml+xml"/>
                <item id="image" href="pic.png" media-type="image/png"/>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
                </manifest><spine>
                <itemref idref="bonus" linear="no"/><itemref idref="image"/>
                <itemref idref="missing"/><itemref idref="c1"/><itemref idref="c2"/>
                </spine></package>
                """,
            "OPS/c1.xhtml": """
                <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
                <p>First reference<sup><a epub:type="noteref" href="#fn1">1</a></sup></p>
                <p>Second reference<sup><a epub:type="noteref" href="#fn1">1</a></sup></p>
                <aside epub:type="footnote" id="fn1">Footnote content.</aside>
                </body></html>
                """,
            "OPS/c2.xhtml": "<html><body><p>Second chapter.</p></body></html>"
        ]
        for (path, content) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        let epub = directory.appendingPathComponent("fixture.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = source
        zip.arguments = ["-qr", epub.path, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return epub
    }
}
