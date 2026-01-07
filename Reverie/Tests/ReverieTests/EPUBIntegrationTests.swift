import XCTest
@testable import Reverie

final class EPUBIntegrationTests: XCTestCase {

    func testRealEPUBParsing() async throws {
        // Robust fixture path resolution for both Xcode and CLI
        let fileManager = FileManager.default
        let currentFileURL = URL(fileURLWithPath: #file)

        // Strategy 1: Check relative to #file
        let projectFixturesURL = currentFileURL
            .deletingLastPathComponent() // ReverieTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("qntm.epub")

        var epubURL = projectFixturesURL

        // Strategy 2: Check via Bundle.module (SPM resources)
        if !fileManager.fileExists(atPath: epubURL.path) {
            if let bundleURL = Bundle.module.url(forResource: "qntm", withExtension: "epub", subdirectory: "Fixtures") {
                epubURL = bundleURL
            }
        }

        guard fileManager.fileExists(atPath: epubURL.path) else {
            XCTFail("Missing qntm.epub. Checked project path and bundle.")
            return
        }

        let parser = EPUBParser()
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("EPUBTest_\(UUID().uuidString)")

        // 2. Run the real parsing logic
        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir)

        // 3. Verify Metadata
        XCTAssertTrue(book.title.contains("Valuable Humans"), "Title should be correct. Got: \(book.title)")
        XCTAssertEqual(book.author, "qntm")

        // 4. Verify Chapters
        XCTAssertGreaterThan(book.chapters.count, 0, "Should have found chapters")

        // Check first substantive chapter
        let firstContent = book.chapters.first { !$0.title.isEmpty && $0.wordCount > 100 }
        XCTAssertNotNil(firstContent, "Should find at least one story/chapter with content")

        print("Successfully parsed \(book.title) with \(book.chapters.count) chapters.")

        // Cleanup
        try? fileManager.removeItem(at: tempDir)
    }

    // MARK: - Malformed EPUB Structure Tests

    func testMissingOPFFile() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_missingOPF_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createMinimalEPUB(at: epubURL, includeOPF: false)

        do {
            _ = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))
            XCTFail("Should throw error for missing OPF")
        } catch EPUBParser.ParseError.containerNotFound, EPUBParser.ParseError.opfNotFound, EPUBParser.ParseError.invalidStructure {
            // Expected - any parsing error is valid for malformed EPUB structure
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 260 {
            // Expected - file not found error when OPF is missing
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInvalidOPFXML() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_invalidOPF_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithInvalidOPF(at: epubURL)

        do {
            _ = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))
            XCTFail("Should throw error for invalid OPF")
        } catch EPUBParser.ParseError.invalidStructure {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingContainerXML() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_missingContainer_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithMissingContainer(at: epubURL)

        do {
            _ = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))
            XCTFail("Should throw error for missing container.xml")
        } catch EPUBParser.ParseError.containerNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInvalidContainerXML() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_invalidContainer_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithInvalidContainer(at: epubURL)

        do {
            _ = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))
            XCTFail("Should throw error for invalid container.xml")
        } catch EPUBParser.ParseError.containerNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Encoding Edge Case Tests

    func testSpecialCharactersInMetadata() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_specialChars_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBSpecialCharacters(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertTrue(book.title.contains("Café"), "Title should contain UTF-8 character")
        XCTAssertTrue(book.author.contains("Hüsker"), "Author should contain special characters")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNonASCIITitles() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_unicodeTitle_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBUnicodeTitle(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertFalse(book.title.isEmpty, "Title should not be empty")
        XCTAssertTrue(book.title.contains("日本語"), "Title should contain Japanese characters")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testHTMLEntitiesInAuthor() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_htmlEntities_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithHTMLEntities(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertTrue(book.author.contains("O'Reilly"), "Author name should handle entities")
        XCTAssertTrue(book.author.contains("and") || book.author.contains("&"), "Author should handle decoded entities")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Cover Image Edge Case Tests

    func testMissingCover() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_noCover_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithoutCover(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertNil(book.cover, "Book should have nil cover when not present")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBrokenCoverImageReference() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_brokenCover_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithBrokenCoverReference(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertNil(book.cover, "Book should have nil cover when reference is broken")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCoverInUnexpectedLocation() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_unexpectedCover_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithCoverInSubdirectory(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertNotNil(book.cover, "Book should find cover even in subdirectory")
        XCTAssertEqual(book.cover?.mediaType, "image/png", "Cover should be detected as PNG")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - TOC Parsing Fallback Tests

    func testNAVMissingFallsBackToNCX() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_noNavNCX_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithNCXOnly(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertGreaterThan(book.chapters.count, 0, "Should extract chapters even without NAV")
        XCTAssertFalse(book.chapters.first?.title.isEmpty ?? true, "Should get title from NCX fallback")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNCXMissingFallsBackToSpine() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_noNCXSpine_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithNeitherNavNorNCX(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertGreaterThan(book.chapters.count, 0, "Should extract chapters from spine only")
        XCTAssertEqual(book.chapters.first?.title, "Chapter 1", "Should use spine-based title")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEmptyTOC() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_emptyTOC_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithEmptyTOC(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertFalse(book.chapters.isEmpty, "Should still extract chapters")
        XCTAssertEqual(book.chapters.first?.title, "Chapter 1", "Should use default chapter titles")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testTOCWithMalformedEntries() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_malformedTOC_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithMalformedTOCEntries(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertGreaterThan(book.chapters.count, 0, "Should extract chapters despite malformed TOC")
        XCTAssertNotNil(book.chapters.first, "Should handle malformed entries gracefully")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Chapter Extraction Edge Case Tests

    func testEmptyChapterContent() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_emptyChapter_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithEmptyChapter(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        let emptyChapters = book.chapters.filter { $0.htmlContent.isEmpty }
        XCTAssertEqual(emptyChapters.count, 1, "Should handle empty chapter content")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testHTMLWithoutBody() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_noBody_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithHTMLNoBody(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        let chapter = book.chapters.first
        XCTAssertNotNil(chapter, "Should still create chapter entry")
        XCTAssertEqual(chapter?.wordCount, 0, "Chapter without body should have zero word count")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingSpineItems() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_missingSpine_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try createEPUBWithMissingSpineItems(at: epubURL)

        let book = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))

        XCTAssertGreaterThanOrEqual(book.chapters.count, 1, "Should skip missing spine items and continue")
        XCTAssertLessThanOrEqual(book.chapters.count, 2, "Should not include broken spine items")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Invalid EPUB ZIP Tests

    func testNotAZIPFile() async throws {
        let parser = EPUBParser()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBTest_notZIP_\(UUID().uuidString)")
        let epubURL = tempDir.appendingPathComponent("test.epub")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "This is not a valid EPUB".write(to: epubURL, atomically: true, encoding: .utf8)

        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            XCTFail("Test file was not created")
            return
        }

        do {
            _ = try await parser.parse(epubURL: epubURL, destinationURL: tempDir.appendingPathComponent("extracted"))
            XCTFail("Should throw error for invalid ZIP")
        } catch EPUBParser.ParseError.invalidEPUB {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - EPUB Creation Helpers

    private func createMinimalEPUB(at url: URL, includeOPF: Bool) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create container.xml
        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        // Create OPF if requested
        if includeOPF {
            let oebpsDir = tempDir.appendingPathComponent("OEBPS")
            try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

            let opfXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>Test Book</dc:title>
                    <dc:creator>Test Author</dc:creator>
                    <dc:identifier id="uid">test-ebook-001</dc:identifier>
                </metadata>
                <manifest>
                    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
                </manifest>
                <spine toc="ncx">
                    <itemref idref="ch1"/>
                </spine>
            </package>
            """
            try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

            // Create chapter
            let chapterXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>Chapter 1</title></head>
                <body><p>Hello World</p></body>
            </html>
            """
            try chapterXML.write(to: oebpsDir.appendingPathComponent("chapter1.xhtml"), atomically: true, encoding: .utf8)
        }

        // Create ZIP
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml"]
        if includeOPF {
            process.arguments?.append(contentsOf: ["OEBPS/content.opf", "OEBPS/chapter1.xhtml"])
        }

        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithInvalidOPF(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let invalidOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
            <metadata>
                <this is invalid xml>
            </metadata>
        </package>
        """
        try invalidOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ZIP", code: Int(process.terminationStatus), userInfo: nil)
        }

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithMissingContainer(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Test</dc:title>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>Test</body></html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithInvalidContainer(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let invalidContainer = "This is not valid XML {broken"
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try invalidContainer.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Test</dc:title>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>Test</body></html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBSpecialCharacters(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Café for the Soul™ &amp; Beyond</dc:title>
                <dc:creator opf:role="aut">Hüsker Dü</dc:creator>
                <dc:identifier id="uid">test-ebook-special</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1 — Café Test</title></head>
            <body>
                <p>Café for the Soul™ & Beyond</p>
                <p>Hüsker Dü wrote this.</p>
            </body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBUnicodeTitle(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>日本語のタイトル English title</dc:title>
                <dc:creator>Unknown</dc:creator>
                <dc:identifier id="uid">test-ebook-unicode</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>日本語のタイトル</title></head>
            <body><p>Unicode content here 日本語</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithHTMLEntities(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Test Book</dc:title>
                <dc:creator>Author and Co - O&apos;Reilly</dc:creator>
                <dc:identifier id="uid">test-ebook-entities</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Test content</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithoutCover(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>No Cover Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-nocover</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Content without cover image</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithBrokenCoverReference(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Broken Cover Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-brokencover</dc:identifier>
                <meta name="cover" content="cover-image"/>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="images/missing-cover.png" media-type="image/png"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Content</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let imagesDir = oebpsDir.appendingPathComponent("images")
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        // Note: NOT creating the cover image file - reference is broken

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithCoverInSubdirectory(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Subdirectory Cover Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-subcover</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="assets/img/cover.png" media-type="image/png"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Content</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let coverDir = oebpsDir.appendingPathComponent("assets").appendingPathComponent("img")
        try fileManager.createDirectory(at: coverDir, withIntermediateDirectories: true)

        // Create minimal PNG (1x1 pixel, red)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, // bit depth, color type, etc
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, // IDAT chunk
            0x08, 0xD7, 0x63, 0x68, 0x60, 0x60, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01,
            0x27, 0x34, 0x27, 0x0A, // IDAT data
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND chunk
            0xAE, 0x42, 0x60, 0x82 // IEND CRC
        ])
        try pngData.write(to: coverDir.appendingPathComponent("cover.png"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml", "OEBPS/assets/img/cover.png"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithNCXOnly(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>NCX Only Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-ncx</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            </manifest>
            <spine toc="ncx">
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let ncxXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx/">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <docTitle><text>NCX Only Book</text></docTitle>
            <navMap>
                <navPoint id="navPoint1" playOrder="1">
                    <content src="ch1.xhtml"/>
                    <text>First Chapter from NCX</text>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxXML.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Content from NCX-book</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithNeitherNavNorNCX(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Spine Only Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-spine</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
                <itemref idref="ch2"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapter1XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>First chapter - no TOC</p></body>
        </html>
        """
        try chapter1XML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let chapter2XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 2</title></head>
            <body><p>Second chapter - no TOC</p></body>
        </html>
        """
        try chapter2XML.write(to: oebpsDir.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithEmptyTOC(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Empty TOC Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-empty-toc</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let navXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Navigation</title></head>
            <body>
                <nav epub:type="toc">
                </nav>
            </body>
        </html>
        """
        try navXML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Content</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithMalformedTOCEntries(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Malformed TOC Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-malformed-toc</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let navXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Navigation</title></head>
            <body>
                <nav epub:type="toc">
                    <a href="nonexistent.xhtml">Broken Link</a>
                    <a href="">Empty href</a>
                    <a></a>
                    <a href="ch1.xhtml">Valid Chapter</a>
                </nav>
            </body>
        </html>
        """
        try navXML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>Valid content</p></body>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithEmptyChapter(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Empty Chapter Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-empty-chapter</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
                <itemref idref="ch2"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapter1XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body></body>
        </html>
        """
        try chapter1XML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let chapter2XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 2</title></head>
            <body><p>Has content</p></body>
        </html>
        """
        try chapter2XML.write(to: oebpsDir.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithHTMLNoBody(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>No Body Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-no-body</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapterXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
        </html>
        """
        try chapterXML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }

    private func createEPUBWithMissingSpineItems(at url: URL) throws {
        let fileManager = FileManager.default
        let tempDir = url.deletingPathExtension().appendingPathExtension("temp")
        if fileManager.fileExists(atPath: tempDir.path) {
            try fileManager.removeItem(at: tempDir)
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        let metaDir = tempDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try containerXML.write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Missing Spine Items Book</dc:title>
                <dc:creator>Test Author</dc:creator>
                <dc:identifier id="uid">test-ebook-missing-spine</dc:identifier>
            </metadata>
            <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="missing.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="ch1"/>
                <itemref idref="ch2"/>
                <itemref idref="ch3"/>
            </spine>
        </package>
        """
        try opfXML.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let chapter1XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 1</title></head>
            <body><p>First chapter</p></body>
        </html>
        """
        try chapter1XML.write(to: oebpsDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let chapter3XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>Chapter 3</title></head>
            <body><p>Third chapter</p></body>
        </html>
        """
        try chapter3XML.write(to: oebpsDir.appendingPathComponent("ch3.xhtml"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-q", url.path, "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/ch1.xhtml", "OEBPS/ch3.xhtml"]
        try process.run()
        process.waitUntilExit()

        try? fileManager.removeItem(at: tempDir)
    }
}
