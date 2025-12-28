import Foundation

/// EPUB Parser - Extracts and parses EPUB files
/// EPUB is a ZIP containing XHTML, CSS, images, and metadata
final class EPUBParser {

    struct ParsedBook {
        let title: String
        let author: String
        let cover: Cover?
        let chapters: [ParsedChapter]
    }

    struct Cover {
        let data: Data
        let mediaType: String?
    }

    struct ParsedChapter {
        let title: String
        let htmlContent: String
        let index: Int
        let footnotes: [ParsedFootnote]
        let resourcePath: String
        let wordCount: Int
    }

    struct ParsedFootnote {
        let marker: String      // The reference marker (e.g., "1", "*")
        let content: String     // The footnote text content
        let refId: String       // The ID used for linking (e.g., "note1")
        let sourceBlockId: Int  // Block number [N] containing this footnote reference
    }

    enum ParseError: Error {
        case invalidEPUB
        case containerNotFound
        case opfNotFound
        case invalidStructure
    }

    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let properties: String?
    }

    private struct SpineItem {
        let idref: String
        let linear: Bool
    }

    private struct PackageData {
        let title: String?
        let author: String?
        let coverId: String?
        let navHref: String?
        let ncxHref: String?
        let guideCoverHref: String?
        let manifest: [String: ManifestItem]
        let spine: [SpineItem]
    }

    // MARK: - Public API

    func parse(epubURL: URL, destinationURL: URL) async throws -> ParsedBook {
        try extractEPUB(epubURL, to: destinationURL)

        let opfPath = try findOPFPath(in: destinationURL)
        let opfURL = destinationURL.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        let package = try parseOPF(at: opfURL)
        let tocTitles = parseTOCTitles(package: package, opfDir: opfDir)
        let cover = extractCover(package: package, opfDir: opfDir)
        let chapters = try extractChapters(
            package: package,
            opfDir: opfDir,
            rootURL: destinationURL,
            tocTitles: tocTitles
        )

        return ParsedBook(
            title: package.title ?? "Untitled",
            author: package.author ?? "Unknown",
            cover: cover,
            chapters: chapters
        )
    }

    // MARK: - Extract EPUB (ZIP)

    private func extractEPUB(_ epubURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", epubURL.path, "-d", destinationURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ParseError.invalidEPUB
        }
    }

    // MARK: - Find OPF Path

    private func findOPFPath(in extractDir: URL) throws -> String {
        let containerURL = extractDir
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")

        guard let containerData = try? Data(contentsOf: containerURL),
              let document = try? XMLDocument(data: containerData, options: [.nodePreserveAll]) else {
            throw ParseError.containerNotFound
        }

        let rootfiles = nodes(named: "rootfile", in: document)
        guard let rootfile = rootfiles.first,
              let path = rootfile.attribute(forName: "full-path")?.stringValue,
              !path.isEmpty else {
            throw ParseError.opfNotFound
        }

        return path
    }

    // MARK: - OPF Parsing

    private func parseOPF(at opfURL: URL) throws -> PackageData {
        let data = try Data(contentsOf: opfURL)
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) else {
            throw ParseError.invalidStructure
        }

        let metadataNode = nodes(named: "metadata", in: document).first
        let title = firstText(named: "title", in: metadataNode ?? document)
        let author = firstText(named: "creator", in: metadataNode ?? document)
        let coverId = extractCoverId(from: metadataNode ?? document)

        let manifestNode = nodes(named: "manifest", in: document).first
        let manifestItems = parseManifest(in: manifestNode ?? document)

        let spineNode = nodes(named: "spine", in: document).first
        let spineItems = parseSpine(in: spineNode ?? document)
        let tocId = spineNode?.attribute(forName: "toc")?.stringValue
        let ncxHref = tocId.flatMap { manifestItems[$0]?.href }

        let navHref = manifestItems.values.first(where: { ($0.properties ?? "").lowercased().contains("nav") })?.href
        let guideCoverHref = extractGuideCoverHref(from: document)

        return PackageData(
            title: title,
            author: author,
            coverId: coverId,
            navHref: navHref,
            ncxHref: ncxHref,
            guideCoverHref: guideCoverHref,
            manifest: manifestItems,
            spine: spineItems
        )
    }

    private func parseManifest(in node: XMLNode) -> [String: ManifestItem] {
        var manifest: [String: ManifestItem] = [:]
        let items = nodes(named: "item", in: node)
        for item in items {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let hrefRaw = item.attribute(forName: "href")?.stringValue else {
                continue
            }
            let href = hrefRaw.removingPercentEncoding ?? hrefRaw
            let mediaType = item.attribute(forName: "media-type")?.stringValue
            let properties = item.attribute(forName: "properties")?.stringValue
            manifest[id] = ManifestItem(id: id, href: href, mediaType: mediaType, properties: properties)
        }
        return manifest
    }

    private func parseSpine(in node: XMLNode) -> [SpineItem] {
        let refs = nodes(named: "itemref", in: node)
        return refs.compactMap { ref in
            guard let idref = ref.attribute(forName: "idref")?.stringValue else { return nil }
            let linearValue = ref.attribute(forName: "linear")?.stringValue?.lowercased()
            let linear = linearValue != "no"
            return SpineItem(idref: idref, linear: linear)
        }
    }

    private func extractCoverId(from node: XMLNode) -> String? {
        let metas = nodes(named: "meta", in: node)
        for meta in metas {
            let name = meta.attribute(forName: "name")?.stringValue?.lowercased()
            if name == "cover" {
                let content = meta.attribute(forName: "content")?.stringValue
                if let content, !content.isEmpty { return content }
            }
        }
        return nil
    }

    private func extractGuideCoverHref(from document: XMLDocument) -> String? {
        let guides = nodes(named: "guide", in: document)
        guard let guide = guides.first else { return nil }
        let references = nodes(named: "reference", in: guide)
        for reference in references {
            let type = reference.attribute(forName: "type")?.stringValue?.lowercased()
            if type == "cover" {
                let href = reference.attribute(forName: "href")?.stringValue
                if let href, !href.isEmpty { return href }
            }
        }
        return nil
    }

    // MARK: - Table of Contents

    private func parseTOCTitles(package: PackageData, opfDir: URL) -> [String: String] {
        if let navHref = package.navHref {
            let navURL = opfDir.appendingPathComponent(navHref)
            if let titles = parseNavTitles(from: navURL, opfDir: opfDir), !titles.isEmpty {
                return titles
            }
        }

        if let ncxHref = package.ncxHref {
            let ncxURL = opfDir.appendingPathComponent(ncxHref)
            if let titles = parseNCXTitles(from: ncxURL, opfDir: opfDir), !titles.isEmpty {
                return titles
            }
        }

        return [:]
    }

    private func parseNavTitles(from navURL: URL, opfDir: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: navURL),
              let document = parseXMLDocument(data: data) else {
            return nil
        }

        let navNodes = nodes(named: "nav", in: document)
        let tocNav = navNodes.first(where: { nav in
            if let type = nav.attribute(forName: "epub:type")?.stringValue?.lowercased() {
                return type.contains("toc")
            }
            if let role = nav.attribute(forName: "role")?.stringValue?.lowercased() {
                return role.contains("toc")
            }
            if let id = nav.attribute(forName: "id")?.stringValue?.lowercased() {
                return id.contains("toc")
            }
            return false
        }) ?? navNodes.first

        guard let navElement = tocNav else { return nil }

        let links = nodes(named: "a", in: navElement)
        let navDir = navURL.deletingLastPathComponent()
        var titles: [String: String] = [:]

        for link in links {
            guard let href = link.attribute(forName: "href")?.stringValue,
                  let title = link.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                continue
            }

            let resolved = resolveRelativeURL(href, relativeTo: navDir)
            if let relative = relativePath(from: opfDir, to: resolved) {
                let key = stripFragment(from: relative)
                if titles[key] == nil {
                    titles[key] = title
                }
            }
        }

        return titles
    }

    private func parseNCXTitles(from ncxURL: URL, opfDir: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: ncxURL),
              let document = parseXMLDocument(data: data) else {
            return nil
        }

        let navPoints = nodes(named: "navPoint", in: document)
        let ncxDir = ncxURL.deletingLastPathComponent()
        var titles: [String: String] = [:]

        for navPoint in navPoints {
            let textNode = nodes(named: "text", in: navPoint).first
            let contentNode = nodes(named: "content", in: navPoint).first
            guard let title = textNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let src = contentNode?.attribute(forName: "src")?.stringValue else {
                continue
            }

            let resolved = resolveRelativeURL(src, relativeTo: ncxDir)
            if let relative = relativePath(from: opfDir, to: resolved) {
                let key = stripFragment(from: relative)
                if titles[key] == nil {
                    titles[key] = title
                }
            }
        }

        return titles
    }

    // MARK: - Cover Extraction

    private func extractCover(package: PackageData, opfDir: URL) -> Cover? {
        var candidates: [(href: String, mediaType: String?)] = []

        if let coverId = package.coverId, let item = package.manifest[coverId] {
            candidates.append((href: item.href, mediaType: item.mediaType))
        }

        if let item = package.manifest.values.first(where: { ($0.properties ?? "").lowercased().contains("cover-image") }) {
            candidates.append((href: item.href, mediaType: item.mediaType))
        }

        if let guideHref = package.guideCoverHref {
            candidates.append((href: guideHref, mediaType: nil))
        }

        if let item = package.manifest.values.first(where: { $0.id.lowercased() == "cover" || $0.id.lowercased() == "cover-image" }) {
            candidates.append((href: item.href, mediaType: item.mediaType))
        }

        if let item = package.manifest.values.first(where: { ($0.mediaType ?? "").lowercased().hasPrefix("image/") && $0.href.lowercased().contains("cover") }) {
            candidates.append((href: item.href, mediaType: item.mediaType))
        }

        for candidate in candidates {
            if let cover = resolveCover(href: candidate.href, mediaType: candidate.mediaType, baseDir: opfDir) {
                return cover
            }
        }

        return nil
    }

    private func resolveCover(href: String, mediaType: String?, baseDir: URL, depth: Int = 0) -> Cover? {
        guard depth < 3 else { return nil }

        let resourceURL = resolveRelativeURL(href, relativeTo: baseDir)
        guard let data = try? Data(contentsOf: resourceURL) else { return nil }

        if isImageMediaType(mediaType) || isImageData(data) || isSvgData(data) {
            let resolvedType = mediaType ?? inferImageMediaType(from: resourceURL, data: data)
            return Cover(data: data, mediaType: resolvedType)
        }

        guard let document = parseXMLDocument(data: data) else { return nil }
        if let imageHref = firstImageHref(in: document) {
            let nextBase = resourceURL.deletingLastPathComponent()
            return resolveCover(href: imageHref, mediaType: nil, baseDir: nextBase, depth: depth + 1)
        }

        return nil
    }

    private func firstImageHref(in document: XMLDocument) -> String? {
        let imgNodes = nodes(named: "img", in: document)
        if let img = imgNodes.first, let src = img.attribute(forName: "src")?.stringValue {
            return src
        }

        let imageNodes = nodes(named: "image", in: document)
        for image in imageNodes {
            if let href = image.attribute(forName: "xlink:href")?.stringValue ?? image.attribute(forName: "href")?.stringValue {
                return href
            }
        }

        return nil
    }

    // MARK: - Extract Chapters

    private func extractChapters(
        package: PackageData,
        opfDir: URL,
        rootURL: URL,
        tocTitles: [String: String]
    ) throws -> [ParsedChapter] {
        var chapters: [ParsedChapter] = []

        for (index, spineItem) in package.spine.enumerated() {
            guard spineItem.linear, let item = package.manifest[spineItem.idref] else { continue }
            guard isHTMLMediaType(item.mediaType) else { continue }

            let chapterURL = opfDir.appendingPathComponent(item.href)
            guard let data = try? Data(contentsOf: chapterURL),
                  let document = parseXMLDocument(data: data) else {
                continue
            }

            let bodyHTML = extractBodyInnerXML(from: document) ?? ""
            let normalizedHTML = normalizeEmbeddedSVG(in: bodyHTML)
            let footnotes = extractFootnotes(from: normalizedHTML)

            let chapterTitle = titleForChapter(
                href: item.href,
                tocTitles: tocTitles,
                document: document,
                index: index
            )

            let resourcePath = relativePath(from: rootURL, to: chapterURL) ?? item.href
            let wordCount = wordCountFrom(document: document)

            chapters.append(ParsedChapter(
                title: chapterTitle,
                htmlContent: normalizedHTML,
                index: index,
                footnotes: footnotes,
                resourcePath: resourcePath,
                wordCount: wordCount
            ))
        }

        return chapters
    }

    private func titleForChapter(
        href: String,
        tocTitles: [String: String],
        document: XMLDocument,
        index: Int
    ) -> String {
        let key = stripFragment(from: href)
        if let tocTitle = tocTitles[key], !tocTitle.isEmpty {
            return tocTitle
        }
        if let htmlTitle = extractChapterTitle(document) {
            return htmlTitle
        }
        return "Chapter \(index + 1)"
    }

    private func wordCountFrom(document: XMLDocument) -> Int {
        guard let body = nodes(named: "body", in: document).first,
              let text = body.stringValue else {
            return 0
        }
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: - XML Helpers

    private func nodes(named name: String, in node: XMLNode) -> [XMLElement] {
        let xpath = ".//*[local-name()='\(name)']"
        return (try? node.nodes(forXPath: xpath) as? [XMLElement]) ?? []
    }

    private func firstText(named name: String, in node: XMLNode) -> String? {
        guard let element = nodes(named: name, in: node).first,
              let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func parseXMLDocument(data: Data) -> XMLDocument? {
        if let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) {
            return document
        }
        return try? XMLDocument(data: data, options: [.documentTidyHTML, .nodePreserveAll])
    }

    private func extractBodyInnerXML(from document: XMLDocument) -> String? {
        guard let body = nodes(named: "body", in: document).first else { return nil }
        let children = body.children ?? []
        return children.map { $0.xmlString(options: .nodePreserveAll) }.joined()
    }

    private func extractChapterTitle(_ document: XMLDocument) -> String? {
        if let h1 = nodes(named: "h1", in: document).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h1.isEmpty {
            return h1
        }
        if let h2 = nodes(named: "h2", in: document).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h2.isEmpty {
            return h2
        }
        if let title = nodes(named: "title", in: document).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return nil
    }

    private func normalizeEmbeddedSVG(in html: String) -> String {
        guard html.range(of: "xlink:href", options: .caseInsensitive) != nil else {
            return html
        }

        var result = html

        if let svgRegex = try? NSRegularExpression(
            pattern: "<svg(?![^>]*\\sxmlns:xlink=)",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = svgRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\""
            )
        }

        if let imageRegex = try? NSRegularExpression(
            pattern: "<([a-zA-Z0-9:_-]+)(?![^>]*\\shref=)([^>]*?)\\sxlink:href=(\"|')([^\"']+)(\"|')([^>]*)>",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = imageRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "<$1$2 xlink:href=\"$4\" href=\"$4\"$6>"
            )
        }

        return result
    }

    private func resolveRelativeURL(_ href: String, relativeTo baseDir: URL) -> URL {
        let decoded = href.removingPercentEncoding ?? href
        let cleaned = stripFragment(from: decoded)
        return baseDir.appendingPathComponent(cleaned).standardizedFileURL
    }

    private func stripFragment(from href: String) -> String {
        let noFragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
        let withoutFragment = noFragment.map(String.init) ?? href
        let noQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first
        return noQuery.map(String.init) ?? withoutFragment
    }

    private func relativePath(from base: URL, to target: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(basePath) else { return nil }
        var relative = String(targetPath.dropFirst(basePath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    private func isHTMLMediaType(_ mediaType: String?) -> Bool {
        guard let mediaType = mediaType?.lowercased() else { return true }
        return mediaType == "application/xhtml+xml" || mediaType == "text/html" || mediaType == "application/x-dtbook+xml"
    }

    private func isImageMediaType(_ mediaType: String?) -> Bool {
        guard let mediaType = mediaType?.lowercased() else { return false }
        return mediaType.hasPrefix("image/")
    }

    private func inferImageMediaType(from url: URL, data: Data) -> String? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            switch ext {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "bmp": return "image/bmp"
            case "svg": return "image/svg+xml"
            default: break
            }
        }
        if isSvgData(data) { return "image/svg+xml" }
        if isImageData(data) { return "image/*" }
        return nil
    }

    private func isImageData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return true
        }
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return true
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return true
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return true
        }
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D {
            return true
        }
        return false
    }

    private func isSvgData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
        return text.range(of: "<svg", options: .caseInsensitive) != nil
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

        // Parse HTML into blocks to map offsets to block IDs
        let blockParser = ContentBlockParser()
        let (blocks, _) = blockParser.parse(html: html)

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

                        // Find which block contains this offset
                        let offset = html.distance(from: html.startIndex, to: matchRange.lowerBound)
                        let blockId = blocks.first { offset >= $0.htmlStartOffset && offset < $0.htmlEndOffset }?.id ?? 1

                        if let content = footnoteContents[refId], !marker.isEmpty {
                            footnotes.append(ParsedFootnote(
                                marker: marker,
                                content: content,
                                refId: refId,
                                sourceBlockId: blockId
                            ))
                        }
                    }
                }
            }
        }

        // Sort by block ID
        return footnotes.sorted { $0.sourceBlockId < $1.sourceBlockId }
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
}
