import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let color: Color
    let lineSpacing: CGFloat
    let isItalic: Bool

    @Environment(\.theme) private var theme

    init(
        _ text: String,
        fontSize: CGFloat,
        fontWeight: NSFont.Weight = .regular,
        color: Color,
        lineSpacing: CGFloat = 0,
        isItalic: Bool = false
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.lineSpacing = lineSpacing
        self.isItalic = isItalic
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

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        
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

        // We avoid calling ensureLayout here to prevent re-entrancy warnings.
        // The usedRect(for:) will trigger layout if needed, but we rely on
        // it being called in a safe context or being mostly ready.
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
