import AppKit
import SwiftUI

@MainActor
protocol PaneContentUpdateScheduling: AnyObject {
    func schedule(_ update: @escaping () -> Void)
}

@MainActor
protocol SplitRatioCommitScheduling: AnyObject {
    func schedule(_ update: @escaping () -> Void)
    func cancelPending()
}

struct ReaderSplitLayout: Equatable {
    static let readerMinimumWidth: CGFloat = 400
    static let aiMinimumWidth: CGFloat = 280
    static let defaultDividerThickness: CGFloat = 8
    static let layoutEpsilon: CGFloat = 0.5

    let totalWidth: CGFloat
    let splitRatio: CGFloat
    let dividerThickness: CGFloat
    let readerMinimumWidth: CGFloat
    let aiMinimumWidth: CGFloat
    let readerIdealWidth: CGFloat
    let aiIdealWidth: CGFloat
    let identity: Int

    static func make(
        totalWidth: CGFloat,
        splitRatio: CGFloat,
        dividerThickness: CGFloat = defaultDividerThickness,
        readerMinimumWidth: CGFloat = readerMinimumWidth,
        aiMinimumWidth: CGFloat = aiMinimumWidth
    ) -> ReaderSplitLayout? {
        guard totalWidth.isFinite, totalWidth > 0 else { return nil }
        return ReaderSplitLayout(
            totalWidth: totalWidth,
            splitRatio: splitRatio,
            dividerThickness: dividerThickness,
            readerMinimumWidth: readerMinimumWidth,
            aiMinimumWidth: aiMinimumWidth
        )
    }

    init(
        totalWidth: CGFloat,
        splitRatio: CGFloat,
        dividerThickness: CGFloat = Self.defaultDividerThickness,
        readerMinimumWidth: CGFloat = Self.readerMinimumWidth,
        aiMinimumWidth: CGFloat = Self.aiMinimumWidth
    ) {
        self.totalWidth = totalWidth
        self.splitRatio = ReaderSplitLayout.clampRatio(splitRatio)
        self.dividerThickness = dividerThickness
        self.readerMinimumWidth = readerMinimumWidth
        self.aiMinimumWidth = aiMinimumWidth
        self.readerIdealWidth = totalWidth * self.splitRatio
        self.aiIdealWidth = max(0, totalWidth - self.readerIdealWidth)
        self.identity = Int((self.splitRatio * 10_000).rounded())
    }

    var dividerPosition: CGFloat? {
        guard totalWidth.isFinite, totalWidth > dividerThickness else { return nil }

        let usableWidth = totalWidth - dividerThickness
        let desiredReaderWidth = totalWidth * splitRatio
        let minimumReaderWidth = min(readerMinimumWidth, usableWidth)
        let maximumReaderWidth = max(0, usableWidth - aiMinimumWidth)

        if maximumReaderWidth >= minimumReaderWidth {
            return min(max(desiredReaderWidth, minimumReaderWidth), maximumReaderWidth)
        }

        return min(max(desiredReaderWidth, 0), usableWidth)
    }

    static func clampRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0), 1)
    }

    static func needsDividerPositionUpdate(
        currentPosition: CGFloat,
        targetPosition: CGFloat,
        epsilon: CGFloat = layoutEpsilon
    ) -> Bool {
        guard currentPosition.isFinite, targetPosition.isFinite else { return true }
        return abs(currentPosition - targetPosition) > epsilon
    }
}

struct ReaderProportionalSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let splitRatio: CGFloat
    let minimumLeadingWidth: CGFloat
    let minimumTrailingWidth: CGFloat
    let onSplitRatioChange: ((CGFloat) -> Void)?
    let leading: Leading
    let trailing: Trailing

    init(
        splitRatio: CGFloat,
        minimumLeadingWidth: CGFloat,
        minimumTrailingWidth: CGFloat,
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.splitRatio = splitRatio
        self.minimumLeadingWidth = minimumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.onSplitRatioChange = onSplitRatioChange
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeNSView(context: Context) -> ReaderSplitContainerView<Leading, Trailing> {
        ReaderSplitContainerView(
            splitRatio: splitRatio,
            minimumLeadingWidth: minimumLeadingWidth,
            minimumTrailingWidth: minimumTrailingWidth,
            onSplitRatioChange: onSplitRatioChange,
            leading: leading,
            trailing: trailing
        )
    }

    func updateNSView(_ containerView: ReaderSplitContainerView<Leading, Trailing>, context: Context) {
        containerView.update(
            splitRatio: splitRatio,
            leading: leading,
            trailing: trailing
        )
    }
}

final class ReaderSplitContainerView<Leading: View, Trailing: View>: NSView, NSSplitViewDelegate {
    private let minimumLeadingWidth: CGFloat
    private let minimumTrailingWidth: CGFloat
    private let paneContentUpdateScheduler: any PaneContentUpdateScheduling
    private let splitRatioCommitScheduler: any SplitRatioCommitScheduling
    private let onSplitRatioChange: ((CGFloat) -> Void)?
    private let splitView = ReaderAppKitSplitView(frame: .zero)
    private let leadingPaneState: ReaderSplitPaneState<Leading>
    private let trailingPaneState: ReaderSplitPaneState<Trailing>
    private let leadingHostingView: NSHostingView<ReaderSplitPaneRoot<Leading>>
    private let trailingHostingView: NSHostingView<ReaderSplitPaneRoot<Trailing>>

    private var desiredSplitRatio: CGFloat
    private var liveSplitRatio: CGFloat
    private var needsSplitRatioApplication = true
    private var lastLaidOutWidth: CGFloat = 0
    private var isApplyingSplitPosition = false
    private var hasCompletedInitialLayout = false
    private var pendingLeadingContent: Leading?
    private var pendingTrailingContent: Trailing?
    private var hasScheduledPaneContentUpdate = false

    private(set) var paneContentUpdateCount = 0
    private(set) var dividerPositionApplicationCount = 0

    override var acceptsFirstResponder: Bool {
        false
    }

    init(
        splitRatio: CGFloat,
        minimumLeadingWidth: CGFloat,
        minimumTrailingWidth: CGFloat,
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        leading: Leading,
        trailing: Trailing,
        paneContentUpdateScheduler: any PaneContentUpdateScheduling = MainRunLoopPaneContentUpdateScheduler(),
        splitRatioCommitScheduler: any SplitRatioCommitScheduling = MainRunLoopSplitRatioCommitScheduler()
    ) {
        self.minimumLeadingWidth = minimumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.paneContentUpdateScheduler = paneContentUpdateScheduler
        self.splitRatioCommitScheduler = splitRatioCommitScheduler
        self.onSplitRatioChange = onSplitRatioChange

        let clampedRatio = ReaderSplitLayout.clampRatio(splitRatio)
        self.desiredSplitRatio = clampedRatio
        self.liveSplitRatio = clampedRatio

        let leadingPaneState = ReaderSplitPaneState(content: leading)
        let trailingPaneState = ReaderSplitPaneState(content: trailing)
        self.leadingPaneState = leadingPaneState
        self.trailingPaneState = trailingPaneState
        self.leadingHostingView = NSHostingView(rootView: ReaderSplitPaneRoot(paneState: leadingPaneState))
        self.trailingHostingView = NSHostingView(rootView: ReaderSplitPaneRoot(paneState: trailingPaneState))

        super.init(frame: .zero)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]

        leadingHostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingHostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(splitView)
        splitView.addArrangedSubview(leadingHostingView)
        splitView.addArrangedSubview(trailingHostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        splitView.frame = bounds
        applySplitRatioIfNeeded()
    }

    func update(splitRatio: CGFloat, leading: Leading, trailing: Trailing) {
        queueContentUpdateIfNeeded(leading: leading, trailing: trailing)

        let clampedRatio = ReaderSplitLayout.clampRatio(splitRatio)
        guard abs(clampedRatio - desiredSplitRatio) > .ulpOfOne else { return }

        splitRatioCommitScheduler.cancelPending()
        desiredSplitRatio = clampedRatio
        liveSplitRatio = clampedRatio
        needsSplitRatioApplication = true
        needsLayout = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingSplitPosition else { return }

        let totalWidth = splitView.bounds.width
        guard totalWidth.isFinite, totalWidth > splitView.dividerThickness else { return }

        let widthChanged = abs(totalWidth - lastLaidOutWidth) > ReaderSplitLayout.layoutEpsilon
        guard !widthChanged else { return }

        liveSplitRatio = currentSplitRatio()
        scheduleSplitRatioCommitIfNeeded()
    }

    var currentLeadingWidth: CGFloat {
        splitView.arrangedSubviews.first?.frame.width ?? 0
    }

    var currentLiveSplitRatio: CGFloat {
        liveSplitRatio
    }

    var isWaitingForValidLayout: Bool {
        needsSplitRatioApplication
    }

    var splitViewDividerThickness: CGFloat {
        splitView.dividerThickness
    }

    var leadingHostingViewIdentifier: ObjectIdentifier {
        ObjectIdentifier(leadingHostingView)
    }

    var trailingHostingViewIdentifier: ObjectIdentifier {
        ObjectIdentifier(trailingHostingView)
    }

    func setContainerSize(_ size: CGSize) {
        frame = CGRect(origin: .zero, size: size)
        layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()
    }

    func simulateDividerDrag(to position: CGFloat) {
        splitView.setPosition(position, ofDividerAt: 0)
        splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(minimumLeadingWidth, max(0, splitView.bounds.width - splitView.dividerThickness))
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let usableWidth = max(0, splitView.bounds.width - splitView.dividerThickness)
        return max(0, usableWidth - minimumTrailingWidth)
    }

    private func applySplitRatioIfNeeded() {
        let totalWidth = splitView.bounds.width
        guard totalWidth.isFinite, totalWidth > splitView.dividerThickness else { return }

        completeInitialLayoutIfNeeded()

        let widthChanged = abs(totalWidth - lastLaidOutWidth) > ReaderSplitLayout.layoutEpsilon
        guard needsSplitRatioApplication || widthChanged else { return }

        let layout = ReaderSplitLayout(
            totalWidth: totalWidth,
            splitRatio: liveSplitRatio,
            dividerThickness: splitView.dividerThickness,
            readerMinimumWidth: minimumLeadingWidth,
            aiMinimumWidth: minimumTrailingWidth
        )

        guard let targetPosition = layout.dividerPosition else { return }

        if !ReaderSplitLayout.needsDividerPositionUpdate(
            currentPosition: currentLeadingWidth,
            targetPosition: targetPosition
        ) {
            lastLaidOutWidth = totalWidth
            needsSplitRatioApplication = false
            return
        }

        isApplyingSplitPosition = true
        splitView.setPosition(targetPosition, ofDividerAt: 0)
        isApplyingSplitPosition = false
        dividerPositionApplicationCount += 1

        lastLaidOutWidth = totalWidth
        needsSplitRatioApplication = false
    }

    private func queueContentUpdateIfNeeded(leading: Leading, trailing: Trailing) {
        pendingLeadingContent = leading
        pendingTrailingContent = trailing

        guard hasCompletedInitialLayout else { return }
        schedulePendingContentUpdateIfNeeded()
    }

    private func completeInitialLayoutIfNeeded() {
        guard !hasCompletedInitialLayout else { return }
        hasCompletedInitialLayout = true
        applyPendingContentIfNeeded()
    }

    private func applyPendingContentIfNeeded() {
        guard let pendingLeadingContent, let pendingTrailingContent else { return }

        self.pendingLeadingContent = nil
        self.pendingTrailingContent = nil
        applyPaneContent(leading: pendingLeadingContent, trailing: pendingTrailingContent)
    }

    private func schedulePendingContentUpdateIfNeeded() {
        guard !hasScheduledPaneContentUpdate else { return }

        hasScheduledPaneContentUpdate = true
        paneContentUpdateScheduler.schedule { [weak self] in
            guard let self else { return }
            self.hasScheduledPaneContentUpdate = false
            self.applyPendingContentIfNeeded()
        }
    }

    private func applyPaneContent(leading: Leading, trailing: Trailing) {
        paneContentUpdateCount += 1
        leadingPaneState.content = leading
        trailingPaneState.content = trailing
    }

    private func currentSplitRatio() -> CGFloat {
        guard splitView.bounds.width > 0 else { return liveSplitRatio }
        return ReaderSplitLayout.clampRatio(currentLeadingWidth / splitView.bounds.width)
    }

    private func scheduleSplitRatioCommitIfNeeded() {
        guard abs(liveSplitRatio - desiredSplitRatio) > .ulpOfOne else { return }

        splitRatioCommitScheduler.schedule { [weak self] in
            self?.commitLiveSplitRatioIfNeeded()
        }
    }

    private func commitLiveSplitRatioIfNeeded() {
        let committedRatio = ReaderSplitLayout.clampRatio(liveSplitRatio)
        guard abs(committedRatio - desiredSplitRatio) > .ulpOfOne else { return }

        desiredSplitRatio = committedRatio
        onSplitRatioChange?(committedRatio)
    }
}

@MainActor
private final class MainRunLoopPaneContentUpdateScheduler: NSObject, PaneContentUpdateScheduling {
    private var pendingUpdate: (() -> Void)?

    func schedule(_ update: @escaping () -> Void) {
        pendingUpdate = update
        perform(#selector(runPendingUpdate), with: nil, afterDelay: 0)
    }

    @objc private func runPendingUpdate() {
        let update = pendingUpdate
        pendingUpdate = nil
        update?()
    }
}

@MainActor
private final class MainRunLoopSplitRatioCommitScheduler: NSObject, SplitRatioCommitScheduling {
    private var pendingUpdate: (() -> Void)?

    func schedule(_ update: @escaping () -> Void) {
        pendingUpdate = update
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPendingUpdate), object: nil)
        perform(#selector(runPendingUpdate), with: nil, afterDelay: 0.15)
    }

    func cancelPending() {
        pendingUpdate = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPendingUpdate), object: nil)
    }

    @objc private func runPendingUpdate() {
        let update = pendingUpdate
        pendingUpdate = nil
        update?()
    }
}

@MainActor
private final class ReaderSplitPaneState<Content: View>: ObservableObject {
    var content: Content {
        didSet { objectWillChange.send() }
    }

    init(content: Content) {
        self.content = content
    }
}

private struct ReaderSplitPaneRoot<Content: View>: View {
    @ObservedObject var paneState: ReaderSplitPaneState<Content>

    var body: some View {
        paneState.content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class ReaderAppKitSplitView: NSSplitView {
    override var acceptsFirstResponder: Bool {
        false
    }
}
