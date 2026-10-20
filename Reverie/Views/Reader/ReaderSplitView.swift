import AppKit
import SwiftUI

struct ReaderWindowHeader: NSViewRepresentable {
    enum Mode {
        case reader
        case standard
    }

    var mode: Mode = .reader

    func makeNSView(context: Context) -> ReaderWindowHeaderView {
        let view = ReaderWindowHeaderView()
        view.mode = mode
        return view
    }

    func updateNSView(_ nsView: ReaderWindowHeaderView, context: Context) {
        nsView.mode = mode
    }

    static func dismantleNSView(_ nsView: ReaderWindowHeaderView, coordinator: ()) {
        nsView.restoreWindowButtons()
    }
}

final class ReaderWindowHeaderView: NSView {
    private struct WindowButtonState {
        weak var button: NSButton?
        weak var superview: NSView?
        let frame: NSRect
        let isHidden: Bool
        let alphaValue: CGFloat
    }

    private static let windowButtonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var hoverTrackingArea: NSTrackingArea?
    private var originalWindowButtons: [WindowButtonState] = []

    var mode: ReaderWindowHeader.Mode = .reader {
        didSet {
            if mode == .standard { restoreWindowButtons() }
            updateWindowButtons()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { restoreWindowButtons() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowButtons()
    }

    override func layout() {
        super.layout()
        updateWindowButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }
        updateWindowButtons()
    }

    override func mouseEntered(with event: NSEvent) {
        updateWindowButtons()
    }

    override func mouseExited(with event: NSEvent) {
        updateWindowButtons()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    func restoreWindowButtons() {
        for state in originalWindowButtons {
            guard let button = state.button else { continue }
            if button.superview === state.superview { button.frame = state.frame }
            button.isHidden = state.isHidden
            button.alphaValue = state.alphaValue
        }
        originalWindowButtons.removeAll(keepingCapacity: true)
    }

    private func updateWindowButtons() {
        guard mode == .reader, let window, !bounds.isEmpty else { return }
        let visible = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let headerCenter = NSPoint(x: bounds.midX, y: bounds.midY)
        for type in Self.windowButtonTypes {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            if !originalWindowButtons.contains(where: { $0.button === button }) {
                originalWindowButtons.append(WindowButtonState(
                    button: button, superview: superview, frame: button.frame,
                    isHidden: button.isHidden, alphaValue: button.alphaValue
                ))
            }
            // The native title-bar container may be flipped independently of our hosting view.
            let center = convert(headerCenter, to: superview)
            let originY = center.y - button.frame.height / 2
            if button.frame.origin.y != originY {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: originY))
            }
            if button.isHidden != !visible { button.isHidden = !visible }
            if button.alphaValue != 1 { button.alphaValue = 1 }
        }
    }
}


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
    let isTrailingVisible: Bool
    let onSplitRatioChange: ((CGFloat) -> Void)?
    let isReaderFocusAllowed: Bool
    let onReaderKeyDown: ((NSEvent) -> Bool)?
    let leading: Leading
    let trailing: Trailing

    init(
        splitRatio: CGFloat,
        minimumLeadingWidth: CGFloat,
        minimumTrailingWidth: CGFloat,
        isTrailingVisible: Bool = true,
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        isReaderFocusAllowed: Bool = true,
        onReaderKeyDown: ((NSEvent) -> Bool)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.splitRatio = splitRatio
        self.minimumLeadingWidth = minimumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.isTrailingVisible = isTrailingVisible
        self.onSplitRatioChange = onSplitRatioChange
        self.isReaderFocusAllowed = isReaderFocusAllowed
        self.onReaderKeyDown = onReaderKeyDown
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeNSView(context: Context) -> ReaderSplitContainerView<Leading, Trailing> {
        ReaderSplitContainerView(
            splitRatio: splitRatio,
            minimumLeadingWidth: minimumLeadingWidth,
            minimumTrailingWidth: minimumTrailingWidth,
            isTrailingVisible: isTrailingVisible,
            onSplitRatioChange: onSplitRatioChange,
            isReaderFocusAllowed: isReaderFocusAllowed,
            onReaderKeyDown: onReaderKeyDown,
            leading: leading,
            trailing: trailing
        )
    }

    func updateNSView(_ containerView: ReaderSplitContainerView<Leading, Trailing>, context: Context) {
        containerView.setDividerColor(context.environment.theme.highlightHigh)
        containerView.isReaderFocusAllowed = isReaderFocusAllowed
        containerView.onReaderKeyDown = onReaderKeyDown
        containerView.setTrailingVisible(isTrailingVisible)
        containerView.update(
            splitRatio: splitRatio,
            leading: leading,
            trailing: trailing
        )
    }
}

final class ReaderSplitContainerView<Leading: View, Trailing: View>: NSView, NSSplitViewDelegate, ReaderInputFocusRecovering {
    private let minimumLeadingWidth: CGFloat
    private let minimumTrailingWidth: CGFloat
    private let paneContentUpdateScheduler: any PaneContentUpdateScheduling
    private let splitRatioCommitScheduler: any SplitRatioCommitScheduling
    private let onSplitRatioChange: ((CGFloat) -> Void)?
    var isReaderFocusAllowed: Bool
    var onReaderKeyDown: ((NSEvent) -> Bool)?
    private(set) var isTrailingVisible: Bool
    private weak var observedWindow: NSWindow?
    private var readerKeyMonitor: Any?
    private var initialFocusPending = true
    private let splitView = ReaderAppKitSplitView(frame: .zero)
    private var dividerColor: Color?
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
        onReaderKeyDown != nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    init(
        splitRatio: CGFloat,
        minimumLeadingWidth: CGFloat,
        minimumTrailingWidth: CGFloat,
        isTrailingVisible: Bool = true,
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        isReaderFocusAllowed: Bool = true,
        onReaderKeyDown: ((NSEvent) -> Bool)? = nil,
        leading: Leading,
        trailing: Trailing,
        paneContentUpdateScheduler: any PaneContentUpdateScheduling = MainRunLoopPaneContentUpdateScheduler(),
        splitRatioCommitScheduler: any SplitRatioCommitScheduling = MainRunLoopSplitRatioCommitScheduler()
    ) {
        self.minimumLeadingWidth = minimumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.isTrailingVisible = isTrailingVisible
        self.paneContentUpdateScheduler = paneContentUpdateScheduler
        self.splitRatioCommitScheduler = splitRatioCommitScheduler
        self.onSplitRatioChange = onSplitRatioChange
        self.isReaderFocusAllowed = isReaderFocusAllowed
        self.onReaderKeyDown = onReaderKeyDown

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

        leadingHostingView.safeAreaRegions = []
        trailingHostingView.safeAreaRegions = []
        leadingHostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingHostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingHostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(splitView)
        splitView.addArrangedSubview(leadingHostingView)
        if isTrailingVisible { splitView.addArrangedSubview(trailingHostingView) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if observedWindow !== newWindow {
            removeReaderKeyMonitor()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
            observedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        initialFocusPending = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(readerWindowDidActivate),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(readerWindowDidActivate),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        installReaderKeyMonitorIfNeeded()
        recoverReaderFocusIfNeeded()
    }


    private func installReaderKeyMonitorIfNeeded() {
        guard readerKeyMonitor == nil, onReaderKeyDown != nil else { return }
        readerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.routeReaderKey(event)
            }
            return handled ? nil : event
        }
    }

    private func removeReaderKeyMonitor() {
        if let readerKeyMonitor {
            NSEvent.removeMonitor(readerKeyMonitor)
            self.readerKeyMonitor = nil
        }
    }

    isolated deinit {
        if let readerKeyMonitor {
            NSEvent.removeMonitor(readerKeyMonitor)
        }
    }

    @objc private func readerWindowDidActivate(_ notification: Notification) {
        recoverReaderFocusIfNeeded()
    }

    private var hasReaderPresentation: Bool {
        guard let window else { return false }
        return window.attachedSheet != nil || window.childWindows?.contains(where: \.isVisible) == true
    }

    /// Each pane is a separate hosting root: the outer SwiftUI focus scope cannot
    /// establish a responder inside it. Recover only a missing/obsolete responder;
    /// never replace a live reader selection, AI pane responder, or field editor.
    func recoverReaderFocusIfNeeded() {
        guard hasCompletedInitialLayout, onReaderKeyDown != nil,
              let window, window.isKeyWindow else { return }
        let isOpening = initialFocusPending
        initialFocusPending = false
        guard isReaderFocusAllowed, !hasReaderPresentation else { return }

        let responder = window.firstResponder
        if let view = responder as? NSView {
            if view === self || view.isDescendant(of: leadingHostingView) ||
                view.isDescendant(of: trailingHostingView) { return }
            if view.window === window, view is NSTextView || view is NSTextField { return }
            if !isOpening, view !== window.contentView, view.window === window { return }
        } else if let responder, responder !== window {
            return
        }
        let target = readerWebView(in: leadingHostingView) as NSView? ?? self
        window.makeFirstResponder(target)
    }

    func readerContentDidAttach(_ content: ReaderWebView) {
        guard onReaderKeyDown != nil, isReaderFocusAllowed, !hasReaderPresentation,
              let window, window.isKeyWindow, window.firstResponder === self else { return }
        window.makeFirstResponder(content)
    }

    private func readerWebView(in root: NSView) -> ReaderWebView? {
        if let content = root as? ReaderWebView { return content }
        for child in root.subviews {
            if let content = readerWebView(in: child) { return content }
        }
        return nil
    }


    @discardableResult
    func routeReaderKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              isReaderFocusAllowed, !hasReaderPresentation,
              let onReaderKeyDown, let window, window.isKeyWindow,
              let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: leadingHostingView),
              !(responder is NSTextView), !(responder is NSControl),
              Self.isReaderNavigationKey(event) else { return false }

        var view: NSView? = responder
        while let current = view, current !== self {
            if let content = current as? ReaderWebView, content.blocksReaderKeyboardHandling {
                return false
            }
            view = current.superview
        }
        // Preflight before WebKit receives the event; handled keys are removed
        // from native delivery rather than also forwarded through keyDown.
        return onReaderKeyDown(event)
    }

    private static func isReaderNavigationKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else { return false }
        if event.modifierFlags.contains(.shift) {
            return event.keyCode == 123 || event.keyCode == 124
        }
        switch event.keyCode {
        case 49, 116, 121, 123, 124, 125, 126: return true
        default: return false
        }
    }

    override func layout() {
        super.layout()
        splitView.frame = bounds
        applySplitRatioIfNeeded()
        if initialFocusPending { recoverReaderFocusIfNeeded() }
    }

    func setDividerColor(_ color: Color) {
        guard dividerColor != color else { return }
        dividerColor = color
        splitView.themeDividerColor = NSColor(color)
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

    func setTrailingVisible(_ visible: Bool) {
        guard visible != isTrailingVisible else { return }
        needsSplitRatioApplication = true
        isTrailingVisible = visible
        if visible {
            splitView.addArrangedSubview(trailingHostingView)
            splitView.adjustSubviews()
        } else {
            if !hasReaderPresentation, isReaderFocusAllowed {
                window?.makeFirstResponder(readerWebView(in: leadingHostingView) ?? self)
            }
            trailingHostingView.removeFromSuperview()
        }
        needsLayout = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isTrailingVisible, !needsSplitRatioApplication, !isApplyingSplitPosition else { return }

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

        if !isTrailingVisible {
            leadingHostingView.frame = splitView.bounds
            lastLaidOutWidth = totalWidth
            needsSplitRatioApplication = false
            return
        }

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
    var themeDividerColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var dividerColor: NSColor { themeDividerColor }

    override var acceptsFirstResponder: Bool {
        false
    }
}
