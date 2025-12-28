import Foundation

struct ContentBlock {
    let id: Int
    let text: String
    let htmlStartOffset: Int
    let htmlEndOffset: Int
}

final class ContentBlockParser {

    /// Parse HTML into numbered blocks, returning clean text for LLM
    func parse(html: String) -> (blocks: [ContentBlock], cleanText: String) {
        var blocks: [ContentBlock] = []
        var cleanLines: [String] = []
        var blockId = 1

        // Find all block-level elements and their positions
        let blockPattern = #"<(p|h[1-6]|blockquote|li|div|section|article)(\s[^>]*)?>[\s\S]*?</\1>"#

        guard let regex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]) else {
            // Fallback: treat entire content as one block
            let stripped = stripHTML(html)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(ContentBlock(id: 1, text: stripped, htmlStartOffset: 0, htmlEndOffset: html.count))
                cleanLines.append("[1] \(stripped)")
            }
            return (blocks, cleanLines.joined(separator: "\n\n"))
        }

        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }

            let blockHTML = String(html[range])
            let strippedText = stripHTML(blockHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty blocks
            guard !strippedText.isEmpty else { continue }

            // Skip very short blocks that are likely noise (page numbers, etc.)
            guard strippedText.count > 3 else { continue }

            let startOffset = html.distance(from: html.startIndex, to: range.lowerBound)
            let endOffset = html.distance(from: html.startIndex, to: range.upperBound)

            blocks.append(ContentBlock(
                id: blockId,
                text: strippedText,
                htmlStartOffset: startOffset,
                htmlEndOffset: endOffset
            ))

            cleanLines.append("[\(blockId)] \(strippedText)")
            blockId += 1
        }

        // If regex found nothing, fall back to paragraph splitting
        if blocks.isEmpty {
            return parseByParagraphs(html: html)
        }

        return (blocks, cleanLines.joined(separator: "\n\n"))
    }

    /// Fallback parser that splits by double newlines
    private func parseByParagraphs(html: String) -> (blocks: [ContentBlock], cleanText: String) {
        let stripped = stripHTML(html)
        let paragraphs = stripped.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 3 }

        var blocks: [ContentBlock] = []
        var cleanLines: [String] = []

        for (index, para) in paragraphs.enumerated() {
            let blockId = index + 1
            // For fallback, we estimate offsets (less precise but functional)
            blocks.append(ContentBlock(
                id: blockId,
                text: para,
                htmlStartOffset: 0,
                htmlEndOffset: html.count
            ))
            cleanLines.append("[\(blockId)] \(para)")
        }

        return (blocks, cleanLines.joined(separator: "\n\n"))
    }

    /// Get injection offset for a specific block ID
    func injectionOffset(for blockId: Int, in html: String) -> Int {
        let (blocks, _) = parse(html: html)
        guard let block = blocks.first(where: { $0.id == blockId }) else {
            return 0
        }
        return block.htmlEndOffset
    }

    /// Get the block containing a specific offset
    func blockId(at offset: Int, in html: String) -> Int? {
        let (blocks, _) = parse(html: html)
        return blocks.first { offset >= $0.htmlStartOffset && offset < $0.htmlEndOffset }?.id
    }

    // MARK: - HTML Stripping

    private func stripHTML(_ html: String) -> String {
        var result = html

        // Decode common HTML entities first
        result = decodeHTMLEntities(result)

        // Remove script and style content entirely
        result = result.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<style[\s\S]*?</style>"#,
            with: "",
            options: .regularExpression
        )

        // Replace <br> tags with newlines
        result = result.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove all other HTML tags
        result = result.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )

        // Collapse multiple whitespace
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            "&rdquo;": "\u{201D}",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™",
            "&times;": "×",
            "&divide;": "÷",
            "&frac12;": "½",
            "&frac14;": "¼",
            "&frac34;": "¾",
        ]

        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Handle numeric entities: &#123; or &#x7B;
        result = replaceNumericEntities(in: result)

        return result
    }

    private func replaceNumericEntities(in string: String) -> String {
        var result = string

        // Decimal: &#123;
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#, options: []) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result),
                      let numRange = Range(match.range(at: 1), in: result) else { continue }
                let numStr = String(result[numRange])
                if let codePoint = Int(numStr),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(matchRange, with: String(Character(scalar)))
                }
            }
        }

        // Hex: &#x7B;
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);"#, options: []) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result),
                      let hexRange = Range(match.range(at: 1), in: result) else { continue }
                let hexStr = String(result[hexRange])
                if let codePoint = Int(hexStr, radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(matchRange, with: String(Character(scalar)))
                }
            }
        }

        return result
    }
}
