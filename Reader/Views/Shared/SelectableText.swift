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

        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.rose),
            .foregroundColor: NSColor(theme.base)
        ]
        textView.invalidateIntrinsicContentSize()
    }
}

final class IntrinsicTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let textContainer = textContainer,
              let layoutManager = layoutManager else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        let height = rect.height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func layout() {
        super.layout()
        textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
    }
}
