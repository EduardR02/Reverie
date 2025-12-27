import Foundation
import Compression

/// EPUB Parser - Extracts and parses EPUB files
/// EPUB is a ZIP containing XHTML, CSS, images, and metadata
final class EPUBParser {

    struct ParsedBook {
        let title: String
        let author: String
        let coverData: Data?
        let chapters: [ParsedChapter]
    }

    struct ParsedChapter {
        let title: String
        let htmlContent: String
        let index: Int
        let footnotes: [ParsedFootnote]
    }

    struct ParsedFootnote {
        let marker: String      // The reference marker (e.g., "1", "*")
        let content: String     // The footnote text content
        let refId: String       // The ID used for linking (e.g., "note1")
        let sourceOffset: Int   // Position in chapter HTML
    }

    enum ParseError: Error {
        case invalidEPUB
        case containerNotFound
        case opfNotFound
        case invalidStructure
    }

    // MARK: - Public API

    func parse(epubURL: URL) async throws -> ParsedBook {
        let extractDir = try extractEPUB(epubURL)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        // Parse container.xml to find OPF location
        let opfPath = try findOPFPath(in: extractDir)
        let opfURL = extractDir.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        // Parse OPF (Open Packaging Format)
        let opfData = try Data(contentsOf: opfURL)
        let opfContent = String(data: opfData, encoding: .utf8) ?? ""

        // Extract metadata
        let title = extractMetadata(opfContent, tag: "dc:title") ?? "Untitled"
        let author = extractMetadata(opfContent, tag: "dc:creator") ?? "Unknown"

        // Extract cover
        let coverData = extractCover(opfContent: opfContent, opfDir: opfDir)

        // Extract chapters (spine order)
        let chapters = try extractChapters(opfContent: opfContent, opfDir: opfDir)

        return ParsedBook(
            title: title,
            author: author,
            coverData: coverData,
            chapters: chapters
        )
    }

    // MARK: - Extract EPUB (ZIP)

    private func extractEPUB(_ epubURL: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Use Archive (built-in) or shell unzip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", epubURL.path, "-d", tempDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ParseError.invalidEPUB
        }

        return tempDir
    }

    // MARK: - Find OPF Path

    private func findOPFPath(in extractDir: URL) throws -> String {
        let containerURL = extractDir
            .appendingPathComponent("META-INF")
            .appendingPathComponent("container.xml")

        guard let containerData = try? Data(contentsOf: containerURL),
              let containerContent = String(data: containerData, encoding: .utf8) else {
            throw ParseError.containerNotFound
        }

        // Parse rootfile full-path
        guard let range = containerContent.range(of: "full-path=\""),
              let endRange = containerContent[range.upperBound...].range(of: "\"") else {
            throw ParseError.opfNotFound
        }

        return String(containerContent[range.upperBound..<endRange.lowerBound])
    }

    // MARK: - Extract Metadata

    private func extractMetadata(_ opfContent: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]+)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: opfContent, range: NSRange(opfContent.startIndex..., in: opfContent)),
              let range = Range(match.range(at: 1), in: opfContent) else {
            return nil
        }
        return String(opfContent[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extract Cover

    private func extractCover(opfContent: String, opfDir: URL) -> Data? {
        // Try to find cover image reference
        let coverPatterns = [
            "href=\"([^\"]+)\"[^>]*properties=\"cover-image\"",
            "id=\"cover\"[^>]*href=\"([^\"]+)\"",
            "href=\"([^\"]+cover[^\"]+\\.(jpg|jpeg|png))\"",
            "<item[^>]*id=\"cover-image\"[^>]*href=\"([^\"]+)\""
        ]

        for pattern in coverPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: opfContent, range: NSRange(opfContent.startIndex..., in: opfContent)),
               let range = Range(match.range(at: 1), in: opfContent) {
                let coverPath = String(opfContent[range])
                let coverURL = opfDir.appendingPathComponent(coverPath)
                if let data = try? Data(contentsOf: coverURL) {
                    return data
                }
            }
        }

        return nil
    }

    // MARK: - Extract Chapters

    private func extractChapters(opfContent: String, opfDir: URL) throws -> [ParsedChapter] {
        // Build manifest (id -> href mapping)
        // Handle both: <item id="x" href="y"/> and <item href="y" id="x"/>
        var manifest: [String: String] = [:]

        // Pattern for items with id before href
        let pattern1 = "<item[^>]*id=\"([^\"]+)\"[^>]*href=\"([^\"]+)\"[^>]*/?>"
        // Pattern for items with href before id
        let pattern2 = "<item[^>]*href=\"([^\"]+)\"[^>]*id=\"([^\"]+)\"[^>]*/?>"

        for pattern in [pattern1, pattern2] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: opfContent, range: NSRange(opfContent.startIndex..., in: opfContent))
                for match in matches {
                    if match.numberOfRanges >= 3,
                       let range1 = Range(match.range(at: 1), in: opfContent),
                       let range2 = Range(match.range(at: 2), in: opfContent) {
                        if pattern == pattern1 {
                            let id = String(opfContent[range1])
                            let href = String(opfContent[range2]).removingPercentEncoding ?? String(opfContent[range2])
                            manifest[id] = href
                        } else {
                            let href = String(opfContent[range1]).removingPercentEncoding ?? String(opfContent[range1])
                            let id = String(opfContent[range2])
                            manifest[id] = href
                        }
                    }
                }
            }
        }

        // Parse spine (reading order) - handle both self-closing and non-self-closing
        var spineItems: [String] = []
        let spinePattern = "<itemref[^>]*idref=\"([^\"]+)\"[^>]*/?>"
        if let regex = try? NSRegularExpression(pattern: spinePattern, options: []) {
            let matches = regex.matches(in: opfContent, range: NSRange(opfContent.startIndex..., in: opfContent))
            for match in matches {
                if let range = Range(match.range(at: 1), in: opfContent) {
                    spineItems.append(String(opfContent[range]))
                }
            }
        }

        // Extract chapters in spine order
        var chapters: [ParsedChapter] = []
        for (index, idref) in spineItems.enumerated() {
            guard let href = manifest[idref] else { continue }
            let chapterURL = opfDir.appendingPathComponent(href)

            guard let htmlData = try? Data(contentsOf: chapterURL),
                  let htmlContent = String(data: htmlData, encoding: .utf8) else {
                continue
            }

            let title = extractChapterTitle(htmlContent) ?? "Chapter \(index + 1)"
            let cleanedHTML = cleanHTML(htmlContent)
            let footnotes = extractFootnotes(from: cleanedHTML)

            chapters.append(ParsedChapter(
                title: title,
                htmlContent: cleanedHTML,
                index: index,
                footnotes: footnotes
            ))
        }

        return chapters
    }

    // MARK: - Extract Footnotes

    private func extractFootnotes(from html: String) -> [ParsedFootnote] {
        var footnotes: [ParsedFootnote] = []

        // Find footnote references: <a epub:type="noteref" href="#id">marker</a>
        // Also handles: <a class="footnote" href="#id">marker</a>, <sup><a href="#fn1">1</a></sup>
        let refPatterns = [
            "<a[^>]*epub:type=[\"']noteref[\"'][^>]*href=[\"']#([^\"']+)[\"'][^>]*>([^<]+)</a>",
            "<a[^>]*href=[\"']#([^\"']+)[\"'][^>]*epub:type=[\"']noteref[\"'][^>]*>([^<]+)</a>",
            "<a[^>]*class=[\"'][^\"']*footnote[^\"']*[\"'][^>]*href=[\"']#([^\"']+)[\"'][^>]*>([^<]+)</a>",
            "<sup[^>]*><a[^>]*href=[\"']#(fn\\d+|note\\d+|endnote\\d+)[\"'][^>]*>(\\d+)</a></sup>"
        ]

        // Find footnote content: <aside epub:type="footnote" id="id">content</aside>
        // Also handles: <div class="footnote" id="id">content</div>, <p id="fn1">content</p>
        let contentPatterns = [
            "<aside[^>]*epub:type=[\"']footnote[\"'][^>]*id=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</aside>",
            "<aside[^>]*id=[\"']([^\"']+)[\"'][^>]*epub:type=[\"']footnote[\"'][^>]*>([\\s\\S]*?)</aside>",
            "<div[^>]*class=[\"'][^\"']*footnote[^\"']*[\"'][^>]*id=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</div>",
            "<p[^>]*id=[\"'](fn\\d+|note\\d+|endnote\\d+)[\"'][^>]*>([\\s\\S]*?)</p>"
        ]

        // Build a map of footnote id -> content
        var footnoteContents: [String: String] = [:]

        for pattern in contentPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    if match.numberOfRanges >= 3,
                       let idRange = Range(match.range(at: 1), in: html),
                       let contentRange = Range(match.range(at: 2), in: html) {
                        let id = String(html[idRange])
                        var content = String(html[contentRange])
                        // Strip HTML tags from content
                        content = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        content = decodeHTMLEntities(content)
                        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty {
                            footnoteContents[id] = content
                        }
                    }
                }
            }
        }

        // Find references and match with content
        for pattern in refPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    if match.numberOfRanges >= 3,
                       let idRange = Range(match.range(at: 1), in: html),
                       let markerRange = Range(match.range(at: 2), in: html),
                       let matchRange = Range(match.range, in: html) {
                        let refId = String(html[idRange])
                        var marker = String(html[markerRange])
                        marker = marker.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        marker = decodeHTMLEntities(marker).trimmingCharacters(in: .whitespacesAndNewlines)

                        let sourceOffset = html.distance(from: html.startIndex, to: matchRange.lowerBound)

                        if let content = footnoteContents[refId], !marker.isEmpty {
                            footnotes.append(ParsedFootnote(
                                marker: marker,
                                content: content,
                                refId: refId,
                                sourceOffset: sourceOffset
                            ))
                        }
                    }
                }
            }
        }

        // Sort by source offset
        return footnotes.sorted { $0.sourceOffset < $1.sourceOffset }
    }

    // MARK: - Extract Chapter Title

    private func extractChapterTitle(_ html: String) -> String? {
        // Try h1, h2, title tags - allow nested tags in content
        let patterns = [
            "<h1[^>]*>(.*?)</h1>",
            "<h2[^>]*>(.*?)</h2>",
            "<title[^>]*>(.*?)</title>"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                var title = String(html[range])
                // Strip any nested HTML tags
                title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                // Decode common HTML entities
                title = decodeHTMLEntities(title)
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty && title.count < 200 { // Sanity check
                    return title
                }
            }
        }

        return nil
    }

    // MARK: - Decode HTML Entities

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
            "&lsquo;": "'",
            "&rsquo;": "'",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}"
        ]

        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        // Handle numeric entities like &#123;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result),
                   let numRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[numRange]),
                   let scalar = Unicode.Scalar(code) {
                    result.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
        }

        return result
    }

    // MARK: - Clean HTML

    private func cleanHTML(_ html: String) -> String {
        // Remove doctype, html/head/body wrappers, keep only body content
        var content = html

        // Extract body content
        if let bodyStart = content.range(of: "<body[^>]*>", options: .regularExpression),
           let bodyEnd = content.range(of: "</body>", options: .caseInsensitive) {
            content = String(content[bodyStart.upperBound..<bodyEnd.lowerBound])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
