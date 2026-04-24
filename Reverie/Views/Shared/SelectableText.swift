import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let color: Color
    let lineSpacing: CGFloat
    let isItalic: Bool
    let rendersMarkdown: Bool

    @Environment(\.theme) private var theme

    init(
        _ text: String,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight = .regular,
        color: Color,
        lineSpacing: CGFloat = 0,
        isItalic: Bool = false,
        rendersMarkdown: Bool = false
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.lineSpacing = lineSpacing
        self.isItalic = isItalic
        self.rendersMarkdown = rendersMarkdown
    }

    /// Creates an NSAttributedString from markdown text, applying base styling
    /// (foreground color, paragraph spacing). Preserves structural markdown traits
    /// (bold, italic, monospace) while applying our theme color.
    static func makeMarkdownAttributedString(
        text: String,
        fontSize: CGFloat,
        color: Color,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }

        do {
            let md = try AttributedString(markdown: text)
            var mutableMD = md

            // Apply our foreground color globally (overrides any markdown-set colors)
            mutableMD.foregroundColor = NSColor(color)

            // Apply paragraph style with line spacing across the entire string
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.lineBreakMode = .byWordWrapping
            mutableMD.paragraphStyle = paragraphStyle

            // Apply base font size while preserving markdown traits (bold, italic, monospace).
            // Use NSFontManager.convert(_:toSize:) which reliably preserves symbolic traits.
            let nsStr = NSMutableAttributedString(attributedString: NSAttributedString(mutableMD))
            nsStr.enumerateAttribute(.font, in: NSRange(location: 0, length: nsStr.length)) { value, range, _ in
                if let font = value as? NSFont {
                    let newFont = NSFontManager.shared.convert(font, toSize: fontSize)
                    nsStr.addAttribute(.font, value: newFont, range: range)
                }
            }
            return nsStr
        } catch {
            // Fallback to plain text if markdown parsing fails
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byWordWrapping

            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(color),
                .paragraphStyle: paragraphStyle
            ]
            return NSAttributedString(string: text, attributes: attributes)
        }
    }

    func makeNSView(context: Context) -> IntrinsicTextView {
        let textView = IntrinsicTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.backgroundColor = .clear
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        return textView
    }

    func updateNSView(_ textView: IntrinsicTextView, context: Context) {
        let attributedString: NSAttributedString

        if rendersMarkdown {
            attributedString = Self.makeMarkdownAttributedString(
                text: text,
                fontSize: fontSize,
                color: color,
                lineSpacing: lineSpacing
            )
        } else {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byWordWrapping

            var font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
            if isItalic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(color),
                .paragraphStyle: paragraphStyle
            ]

            attributedString = NSAttributedString(string: text, attributes: attributes)
        }

        // Invalidate cache when text changes
        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
            textView.invalidateIntrinsicContentSize()
        }

        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.rose),
            .foregroundColor: NSColor(theme.base)
        ]
    }
}

final class IntrinsicTextView: NSTextView {
    private var cachedSize: NSSize?
    private var lastKnownWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        if let cachedSize = cachedSize {
            return cachedSize
        }

        guard let textContainer = textContainer,
              let layoutManager = layoutManager else {
            return super.intrinsicContentSize
        }

        // ensureLayout is required for accurate height - usedRect alone returns stale values.
        // This may trigger re-entrancy warnings in Xcode console but they're benign.
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        let height = ceil(rect.height + textContainerInset.height * 2)
        let size = NSSize(width: NSView.noIntrinsicMetric, height: height)
        cachedSize = size
        return size
    }

    override func layout() {
        super.layout()
        if bounds.width != lastKnownWidth {
            lastKnownWidth = bounds.width
            textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }

    override func invalidateIntrinsicContentSize() {
        cachedSize = nil
        super.invalidateIntrinsicContentSize()
    }
}
