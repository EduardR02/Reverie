import Foundation
import CoreGraphics
import ImageIO

/// EPUB Parser - Extracts and parses EPUB files
/// EPUB is a ZIP containing XHTML, CSS, images, and metadata
final class EPUBParser {

    struct ParsedBook {
        let title: String
        let author: String
        let cover: Cover?
        let chapters: [ParsedChapter]
    }

    struct ParsedMetadata {
        let title: String
        let author: String
        let cover: Cover?
        let chapters: [ChapterSkeleton]
    }

    struct ChapterSkeleton {
        let index: Int
        let title: String
        let href: String
        let mediaType: String?
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
        let manifestOrder: [String]
        let spine: [SpineItem]
    }

    // MARK: - Public API

    func parseMetadata(epubURL: URL, destinationURL: URL) async throws -> (metadata: ParsedMetadata, opfPath: String) {
        try extractEPUB(epubURL, to: destinationURL)

        let opfPath = try findOPFPath(in: destinationURL)
        let opfURL = destinationURL.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        let package = try parseOPF(at: opfURL)
        let tocTitles = parseTOCTitles(package: package, opfDir: opfDir)
        let cover = extractCover(package: package, opfDir: opfDir)

        var chapters: [ChapterSkeleton] = []
        for (index, spineItem) in package.spine.enumerated() {
            guard spineItem.linear else { continue }
            guard let item = package.manifest[spineItem.idref] else {
                print("Warning: Spine item \(spineItem.idref) not found in manifest")
                continue
            }
            guard isHTMLMediaType(item.mediaType) else { continue }

            let key = stripFragment(from: item.href)
            let title = tocTitles[key] ?? "Chapter \(index + 1)"

            chapters.append(ChapterSkeleton(
                index: index,
                title: title,
                href: item.href,
                mediaType: item.mediaType
            ))
        }

        let metadata = ParsedMetadata(
            title: package.title ?? "Untitled",
            author: package.author ?? "Unknown",
            cover: cover,
            chapters: chapters
        )

        return (metadata, opfPath)
    }

    func parseChapter(
        _ skeleton: ChapterSkeleton,
        opfDir: URL,
        rootURL: URL
    ) throws -> ParsedChapter {
        let chapterURL = opfDir.appendingPathComponent(skeleton.href)
        guard let data = try? Data(contentsOf: chapterURL),
              let document = parseXMLDocument(data: data) else {
            throw ParseError.invalidStructure
        }

        let bodyHTML = extractBodyInnerXML(from: document) ?? ""
        let footnotes = extractFootnotes(from: bodyHTML)

        var title = skeleton.title
        // If we only have a default "Chapter N" title, try to get a better one from HTML
        if title == "Chapter \(skeleton.index + 1)", let htmlTitle = extractChapterTitle(document) {
            title = htmlTitle
        }

        let resourcePath = relativePath(from: rootURL, to: chapterURL) ?? skeleton.href
        let wordCount = wordCountFrom(document: document)

        return ParsedChapter(
            title: title,
            htmlContent: bodyHTML,
            index: skeleton.index,
            footnotes: footnotes,
            resourcePath: resourcePath,
            wordCount: wordCount
        )
    }

    func parse(epubURL: URL, destinationURL: URL) async throws -> ParsedBook {
        let (metadata, opfPath) = try await parseMetadata(epubURL: epubURL, destinationURL: destinationURL)
        let opfURL = destinationURL.appendingPathComponent(opfPath)
        let opfDir = opfURL.deletingLastPathComponent()

        var chapters: [ParsedChapter] = []
        for skeleton in metadata.chapters {
            if let parsed = try? parseChapter(skeleton, opfDir: opfDir, rootURL: destinationURL) {
                chapters.append(parsed)
            }
        }

        return ParsedBook(
            title: metadata.title,
            author: metadata.author,
            cover: metadata.cover,
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
        let (manifestItems, manifestOrder) = parseManifest(in: manifestNode ?? document)

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
            manifestOrder: manifestOrder,
            spine: spineItems
        )
    }

    private func parseManifest(in node: XMLNode) -> (items: [String: ManifestItem], order: [String]) {
        var manifest: [String: ManifestItem] = [:]
        var order: [String] = []
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
            order.append(id)
        }
        return (manifest, order)
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
        // 1. Metadata coverId (highest priority)
        if let coverId = package.coverId, let item = package.manifest[coverId],
           let cover = resolveCover(href: item.href, mediaType: item.mediaType, baseDir: opfDir) {
            return cover
        }

        // 2. Manifest properties "cover-image" (EPUB 3 standard)
        let coverPropertyItems = package.manifestOrder.compactMap { id -> ManifestItem? in
            let item = package.manifest[id]
            return (item?.properties ?? "").lowercased().contains("cover-image") ? item : nil
        }
        for item in coverPropertyItems {
            if let cover = resolveCover(href: item.href, mediaType: item.mediaType, baseDir: opfDir) {
                return cover
            }
        }

        // 3. Guide cover (EPUB 2 standard)
        if let guideHref = package.guideCoverHref,
           let cover = resolveCover(href: guideHref, mediaType: nil, baseDir: opfDir) {
            return cover
        }

        // 4. First spine item analysis (often a cover page)
        if let firstSpineId = package.spine.first?.idref,
           let item = package.manifest[firstSpineId],
           isHTMLMediaType(item.mediaType) {
            let pageURL = opfDir.appendingPathComponent(item.href)
            if let bestHref = findBestImageInPage(at: pageURL) {
                let pageDir = pageURL.deletingLastPathComponent()
                if let cover = resolveCover(href: bestHref, mediaType: nil, baseDir: pageDir) {
                    return cover
                }
            }
        }

        // 5. Manifest search: look for "cover" in ID or filename
        let manifestCoverItems = package.manifestOrder.compactMap { id -> ManifestItem? in
            let item = package.manifest[id]!
            let lowerId = item.id.lowercased()
            let lowerHref = item.href.lowercased()
            let isImage = isImageMediaType(item.mediaType) || 
                         lowerHref.hasSuffix(".jpg") || lowerHref.hasSuffix(".jpeg") || 
                         lowerHref.hasSuffix(".png") || lowerHref.hasSuffix(".webp")
            
            if isImage && (lowerId.contains("cover") || lowerHref.contains("cover")) {
                return item
            }
            return nil
        }
        for item in manifestCoverItems {
            if let cover = resolveCover(href: item.href, mediaType: item.mediaType, baseDir: opfDir) {
                return cover
            }
        }

        // 6. Heuristic fallback: evaluate all images in manifest
        let allImageItems = package.manifestOrder.compactMap { id -> ManifestItem? in
            let item = package.manifest[id]!
            return isImageMediaType(item.mediaType) ? item : nil
        }
        
        let candidates = allImageItems.compactMap { item -> (Cover, Double)? in
            guard let cover = resolveCover(href: item.href, mediaType: item.mediaType, baseDir: opfDir) else { return nil }
            return (cover, scoreImage(data: cover.data, href: item.href))
        }
        
        return candidates.sorted { $0.1 > $1.1 }.first?.0
    }

    private func resolveCover(href: String, mediaType: String?, baseDir: URL, depth: Int = 0) -> Cover? {
        guard depth < 3 else { return nil }

        let resourceURL = resolveRelativeURL(href, relativeTo: baseDir)
        guard let data = try? Data(contentsOf: resourceURL) else { return nil }

        if isImageMediaType(mediaType) || isImageData(data) || isSvgData(data) {
            let resolvedType = mediaType ?? inferImageMediaType(from: resourceURL, data: data)
            return Cover(data: data, mediaType: resolvedType)
        }

        // If it's likely an HTML/XML file, try to find an image inside it
        if let bestImageHref = findBestImageInPage(at: resourceURL) {
            let nextBase = resourceURL.deletingLastPathComponent()
            return resolveCover(href: bestImageHref, mediaType: nil, baseDir: nextBase, depth: depth + 1)
        }

        return nil
    }

    private func findBestImageInPage(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let document = parseXMLDocument(data: data) else { return nil }
        
        let imgNodes = nodes(named: "img", in: document)
        let svgImageNodes = nodes(named: "image", in: document)
        
        var candidates: [(href: String, score: Double)] = []
        let pageDir = url.deletingLastPathComponent()
        
        func process(href: String, id: String?, className: String?) {
            let resourceURL = resolveRelativeURL(href, relativeTo: pageDir)
            guard let imageData = try? Data(contentsOf: resourceURL) else { return }
            
            var score = scoreImage(data: imageData, href: href)
            
            // Bonus for cover-related attributes
            let lowerId = id?.lowercased() ?? ""
            let lowerClass = className?.lowercased() ?? ""
            if lowerId.contains("cover") || lowerClass.contains("cover") {
                score *= 1.5
            }
            
            candidates.append((href, score))
        }
        
        for img in imgNodes {
            if let src = img.attribute(forName: "src")?.stringValue {
                process(href: src, id: img.attribute(forName: "id")?.stringValue, className: img.attribute(forName: "class")?.stringValue)
            }
        }
        
        for img in svgImageNodes {
            // SVG image tags use xlink:href (deprecated) or href (SVG 2).
            // We check for both, and also check localName for robustness against namespace prefix variations.
            let href = img.attribute(forName: "xlink:href")?.stringValue
                ?? img.attribute(forName: "href")?.stringValue
                ?? img.attributes?.first(where: { $0.localName == "href" })?.stringValue
            
            if let href = href {
                process(href: href, id: img.attribute(forName: "id")?.stringValue, className: img.attribute(forName: "class")?.stringValue)
            }
        }
        
        return candidates.sorted { $0.score > $1.score }.first?.href
    }

    private func scoreImage(data: Data, href: String) -> Double {
        let size = Double(data.count)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0 else {
            return size // Fallback to size
        }
        
        let aspectRatio = w / h
        // Covers are typically 2:3 (0.66) or 3:4 (0.75)
        let targetRatio = 0.67
        let ratioPenalty = abs(aspectRatio - targetRatio)
        
        var score = size
        
        // Heavily penalize extreme aspect ratios (banners or very thin images)
        if aspectRatio > 2.0 || aspectRatio < 0.3 {
            score *= 0.1
        } else {
            // Favor ratios closer to 2:3
            score *= (1.0 - (ratioPenalty * 0.5))
        }
        
        // Bonus for "cover" in filename
        if href.lowercased().contains("cover") {
            score *= 1.2
        }
        
        return score
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

    private func wordCountFrom(document: XMLDocument) -> Int {
        guard let body = nodes(named: "body", in: document).first,
              let text = body.stringValue else {
            return 0
        }
        return text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
