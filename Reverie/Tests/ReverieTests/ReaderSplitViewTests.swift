import AppKit
import SwiftUI
import XCTest
import WebKit
@testable import Reverie

@MainActor
final class ReaderSplitViewTests: XCTestCase {
    func testCollapsedSidebarFillsReaderAndRestoresRatioAfterResize() {
        var persistedRatios: [CGFloat] = []
        let container = makeContainer(splitRatio: 0.65, onSplitRatioChange: { persistedRatios.append($0) })
        container.setContainerSize(CGSize(width: 1200, height: 700))

        container.setTrailingVisible(false)
        container.setContainerSize(CGSize(width: 1200, height: 700))
        XCTAssertEqual(container.currentLeadingWidth, 1200, accuracy: 0.5)
        container.setContainerSize(CGSize(width: 900, height: 600))
        XCTAssertEqual(container.currentLeadingWidth, 900, accuracy: 0.5)

        container.setTrailingVisible(true)
        container.setContainerSize(CGSize(width: 900, height: 600))
        XCTAssertEqual(container.currentLeadingWidth, 585, accuracy: 0.5)
        XCTAssertTrue(persistedRatios.isEmpty, "Collapse must not overwrite the user's split preference")
    }

    func testCollapseRetainsPendingRealDividerDragInsteadOfPersistingFullWidth() {
        let scheduler = ManualSplitRatioCommitScheduler()
        var persistedRatios: [CGFloat] = []
        let container = makeContainer(
            splitRatio: 0.65, onSplitRatioChange: { persistedRatios.append($0) },
            splitRatioCommitScheduler: scheduler
        )
        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 850)
        container.setTrailingVisible(false)
        container.setContainerSize(CGSize(width: 1200, height: 700))
        scheduler.runPendingUpdates()

        XCTAssertEqual(persistedRatios.count, 1)
        XCTAssertEqual(persistedRatios.first ?? 0, 850 / 1200, accuracy: 0.001)
        container.setTrailingVisible(true)
        container.setContainerSize(CGSize(width: 1200, height: 700))
        XCTAssertEqual(container.currentLeadingWidth, 850, accuracy: 0.5)
    }

    func testInitiallyCollapsedReaderCanOpenAtItsSavedSplit() {
        let container = ReaderSplitContainerView(
            splitRatio: 0.65,
            minimumLeadingWidth: ReaderSplitLayout.readerMinimumWidth,
            minimumTrailingWidth: ReaderSplitLayout.aiMinimumWidth,
            isTrailingVisible: false,
            leading: Text("Reader"), trailing: Text("AI")
        )
        container.setContainerSize(CGSize(width: 1200, height: 700))
        XCTAssertEqual(container.currentLeadingWidth, 1200, accuracy: 0.5)
        container.setTrailingVisible(true)
        container.setContainerSize(CGSize(width: 1200, height: 700))
        XCTAssertEqual(container.currentLeadingWidth, 780, accuracy: 0.5)
    }

    func testReaderHeaderCentersNativeButtonsAndRestoresThemOnDetach() throws {
        let window = makeHeaderWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let originalSuperview = try XCTUnwrap(button.superview)
        let originalFrame = button.frame
        let originalVisibility = button.isHidden
        let originalAlpha = button.alphaValue
        let header = ReaderWindowHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
        root.addSubview(header)
        header.layoutSubtreeIfNeeded()

        XCTAssertTrue(button.superview === originalSuperview)
        let nativeCenter = header.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), from: originalSuperview)
        XCTAssertEqual(nativeCenter.y, header.bounds.midY, accuracy: 0.001)
        XCTAssertTrue(button.isHidden)

        window.simulatedMouseLocation = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
        header.updateTrackingAreas()
        XCTAssertFalse(button.isHidden)
        window.simulatedMouseLocation = NSPoint(x: -100, y: -100)
        header.updateTrackingAreas()
        XCTAssertTrue(button.isHidden)

        header.removeFromSuperview()

        XCTAssertEqual(button.frame, originalFrame)
        XCTAssertEqual(button.isHidden, originalVisibility)
        XCTAssertEqual(button.alphaValue, originalAlpha)
    }

    func testStandardHeaderLeavesNativeButtonsVisibleAndUnshifted() throws {
        let window = makeHeaderWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let originalFrame = button.frame
        button.isHidden = false
        let header = ReaderWindowHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 64))
        header.mode = .standard
        root.addSubview(header)
        header.layoutSubtreeIfNeeded()
        header.updateTrackingAreas()

        XCTAssertEqual(button.frame, originalFrame)
        XCTAssertFalse(button.isHidden)

        header.mode = .reader
        header.mode = .standard

        XCTAssertEqual(button.frame, originalFrame)
        XCTAssertFalse(button.isHidden)
    }

    func testHeaderUsesNativeDragAndDoubleClickPreferencesInBothModes() throws {
        let defaults = UserDefaults.standard
        let originalPreference = defaults.object(forKey: "AppleActionOnDoubleClick")
        defer {
            if let originalPreference {
                defaults.set(originalPreference, forKey: "AppleActionOnDoubleClick")
            } else {
                defaults.removeObject(forKey: "AppleActionOnDoubleClick")
            }
        }
        for mode in [ReaderWindowHeader.Mode.reader, .standard] {
            let window = makeHeaderWindow()
            defer { window.close() }
            let header = ReaderWindowHeaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
            header.mode = mode
            try XCTUnwrap(window.contentView).addSubview(header)
            let doubleClick = try makeHeaderMouseEvent(window: window, clickCount: 2)
            for preference in ["Maximize", "Minimize", "None"] {
                defaults.set(preference, forKey: "AppleActionOnDoubleClick")
                header.mouseDown(with: doubleClick)
            }
            XCTAssertEqual(window.zoomCount, 1)
            XCTAssertEqual(window.minimizeCount, 1)
            XCTAssertEqual(window.dragCount, 0)

            header.mouseDown(with: try makeHeaderMouseEvent(window: window, clickCount: 1))
            XCTAssertEqual(window.dragCount, 1)
        }
    }

    private func makeHeaderWindow() -> NativeHeaderTestWindow {
        _ = NSApplication.shared
        let window = NativeHeaderTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NativeHeaderFlippedTestView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        return window
    }

    private func makeHeaderMouseEvent(window: NSWindow, clickCount: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clickCount, pressure: 1
        ))
    }

    func testControllerWaitsForPositiveWidthBeforeApplyingStoredRatio() throws {
        let container = makeContainer(splitRatio: 0.72)

        container.setContainerSize(CGSize(width: 0, height: 700))

        XCTAssertTrue(container.isWaitingForValidLayout)
        XCTAssertEqual(container.currentLeadingWidth, 0, accuracy: 0.001)

        container.setContainerSize(CGSize(width: 1200, height: 700))

        let expected = try XCTUnwrap(
            ReaderSplitLayout(
                totalWidth: 1200,
                splitRatio: 0.72,
                dividerThickness: container.splitViewDividerThickness,
                readerMinimumWidth: ReaderSplitLayout.readerMinimumWidth,
                aiMinimumWidth: ReaderSplitLayout.aiMinimumWidth
            ).dividerPosition
        )

        XCTAssertFalse(container.isWaitingForValidLayout)
        XCTAssertEqual(container.currentLeadingWidth, expected, accuracy: 0.5)
    }

    func testControllerClampsDividerToMinimumPaneWidths() throws {
        let container = makeContainer(splitRatio: 0.8)

        container.setContainerSize(CGSize(width: 700, height: 700))

        let expected = try XCTUnwrap(
            ReaderSplitLayout(
                totalWidth: 700,
                splitRatio: 0.8,
                dividerThickness: container.splitViewDividerThickness,
                readerMinimumWidth: ReaderSplitLayout.readerMinimumWidth,
                aiMinimumWidth: ReaderSplitLayout.aiMinimumWidth
            ).dividerPosition
        )

        XCTAssertEqual(container.currentLeadingWidth, expected, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(container.currentLeadingWidth, ReaderSplitLayout.readerMinimumWidth)
    }

    func testControllerKeepsDraggedRatioAcrossContainerResize() throws {
        let container = makeContainer(splitRatio: 0.65)

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 900)

        let draggedRatio = container.currentLiveSplitRatio

        container.setContainerSize(CGSize(width: 1400, height: 700))

        let expected = try XCTUnwrap(
            ReaderSplitLayout(
                totalWidth: 1400,
                splitRatio: draggedRatio,
                dividerThickness: container.splitViewDividerThickness,
                readerMinimumWidth: ReaderSplitLayout.readerMinimumWidth,
                aiMinimumWidth: ReaderSplitLayout.aiMinimumWidth
            ).dividerPosition
        )

        XCTAssertEqual(container.currentLeadingWidth, expected, accuracy: 0.5)
    }

    func testControllerCommitsDraggedRatioAfterDebounce() {
        let scheduler = ManualSplitRatioCommitScheduler()
        var committedRatios: [CGFloat] = []
        let container = makeContainer(
            splitRatio: 0.65,
            onSplitRatioChange: { committedRatios.append($0) },
            splitRatioCommitScheduler: scheduler
        )

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 900)

        XCTAssertEqual(committedRatios.count, 0)
        XCTAssertEqual(scheduler.pendingUpdateCount, 1)

        scheduler.runPendingUpdates()

        XCTAssertEqual(committedRatios.count, 1)
        XCTAssertEqual(committedRatios[0], container.currentLiveSplitRatio, accuracy: 0.0001)
    }

    func testControllerCoalescesDragPersistenceUpdates() {
        let scheduler = ManualSplitRatioCommitScheduler()
        var committedRatios: [CGFloat] = []
        let container = makeContainer(
            splitRatio: 0.65,
            onSplitRatioChange: { committedRatios.append($0) },
            splitRatioCommitScheduler: scheduler
        )

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 760)
        container.simulateDividerDrag(to: 820)
        container.simulateDividerDrag(to: 880)

        XCTAssertEqual(scheduler.pendingUpdateCount, 1)

        scheduler.runPendingUpdates()

        XCTAssertEqual(committedRatios.count, 1)
        XCTAssertEqual(committedRatios[0], container.currentLiveSplitRatio, accuracy: 0.0001)
    }

    func testControllerPreservesPendingDragCommitAcrossSameRatioViewUpdates() {
        let scheduler = ManualSplitRatioCommitScheduler()
        var committedRatios: [CGFloat] = []
        let container = makeContainer(
            splitRatio: 0.65,
            onSplitRatioChange: { committedRatios.append($0) },
            splitRatioCommitScheduler: scheduler
        )

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 900)
        container.update(splitRatio: 0.65, leading: Text("Reader rerender"), trailing: Text("AI rerender"))

        XCTAssertEqual(scheduler.pendingUpdateCount, 1)

        scheduler.runPendingUpdates()

        XCTAssertEqual(committedRatios.count, 1)
        XCTAssertEqual(committedRatios[0], container.currentLiveSplitRatio, accuracy: 0.0001)
    }

    func testControllerCancelsPendingDragCommitWhenExternalRatioOverridesIt() {
        let scheduler = ManualSplitRatioCommitScheduler()
        var committedRatios: [CGFloat] = []
        let container = makeContainer(
            splitRatio: 0.65,
            onSplitRatioChange: { committedRatios.append($0) },
            splitRatioCommitScheduler: scheduler
        )

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.simulateDividerDrag(to: 900)
        container.update(splitRatio: 0.72, leading: Text("Reader override"), trailing: Text("AI override"))

        XCTAssertEqual(scheduler.pendingUpdateCount, 0)

        scheduler.runPendingUpdates()

        XCTAssertTrue(committedRatios.isEmpty)
        XCTAssertEqual(container.currentLiveSplitRatio, 0.72, accuracy: 0.0001)
    }

    func testControllerReusesHostingControllersWhenRatioChanges() {
        let container = makeContainer(splitRatio: 0.65)
        let leadingIdentifier = container.leadingHostingViewIdentifier
        let trailingIdentifier = container.trailingHostingViewIdentifier

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.update(splitRatio: 0.72, leading: Text("Reader"), trailing: Text("AI"))

        XCTAssertEqual(container.leadingHostingViewIdentifier, leadingIdentifier)
        XCTAssertEqual(container.trailingHostingViewIdentifier, trailingIdentifier)
    }

    func testControllerCoalescesPrelayoutContentUpdates() {
        let container = makeContainer(splitRatio: 0.65)

        container.update(splitRatio: 0.65, leading: Text("Reader"), trailing: Text("AI"))
        container.update(splitRatio: 0.65, leading: Text("Reader v2"), trailing: Text("AI v2"))
        container.update(splitRatio: 0.65, leading: Text("Reader v3"), trailing: Text("AI v3"))

        XCTAssertEqual(container.paneContentUpdateCount, 0)

        container.setContainerSize(CGSize(width: 1200, height: 700))

        XCTAssertEqual(container.paneContentUpdateCount, 1)
    }

    func testControllerAppliesFirstPrelayoutContentUpdateOnInitialLayout() {
        let container = makeContainer(splitRatio: 0.65)

        container.update(splitRatio: 0.65, leading: Text("Loaded Reader"), trailing: Text("Loaded AI"))

        XCTAssertEqual(container.paneContentUpdateCount, 0)

        container.setContainerSize(CGSize(width: 1200, height: 700))

        XCTAssertEqual(container.paneContentUpdateCount, 1)
    }

    func testControllerDefersPostLayoutPaneStateUpdatesUntilNextMainTurn() {
        let scheduler = ManualPaneContentUpdateScheduler()
        let container = makeContainer(splitRatio: 0.65, scheduler: scheduler)

        container.setContainerSize(CGSize(width: 1200, height: 700))
        container.update(splitRatio: 0.65, leading: Text("Reader v2"), trailing: Text("AI v2"))
        container.update(splitRatio: 0.65, leading: Text("Reader v3"), trailing: Text("AI v3"))

        XCTAssertEqual(container.paneContentUpdateCount, 0)
        XCTAssertEqual(scheduler.pendingUpdateCount, 1)

        scheduler.runPendingUpdates()

        XCTAssertEqual(container.paneContentUpdateCount, 1)
        XCTAssertEqual(scheduler.pendingUpdateCount, 0)
    }

    func testControllerSkipsDividerReapplicationWhenPositionAlreadyMatchesTarget() {
        let container = makeContainer(splitRatio: 0.65)

        container.setContainerSize(CGSize(width: 1200, height: 700))

        XCTAssertEqual(container.dividerPositionApplicationCount, 1)

        container.update(splitRatio: 0.6501, leading: Text("Reader"), trailing: Text("AI"))
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(container.dividerPositionApplicationCount, 1)
    }

    func testSplitLayoutTreatsNearTargetDividerPositionsAsAlreadyApplied() {
        XCTAssertFalse(
            ReaderSplitLayout.needsDividerPositionUpdate(currentPosition: 780.25, targetPosition: 780)
        )
        XCTAssertTrue(
            ReaderSplitLayout.needsDividerPositionUpdate(currentPosition: 781, targetPosition: 780)
        )
    }

    func testReaderAttachmentReclaimsLibraryResponderAndHandlesFirstKeyOnce() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let library = ReaderFocusableTestView()
        root.addSubview(library)
        XCTAssertTrue(window.makeFirstResponder(library))
        var handledKeys = 0
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in
            handledKeys += 1
            return true
        })

        root.addSubview(container)

        XCTAssertTrue(window.firstResponder === container)
        let event = try makeKeyEvent(keyCode: 124, window: window)
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(handledKeys, 1)
    }

    func testReaderReactivationRepairsNeutralFocusWithoutStealingChatFocus() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in true })
        root.addSubview(container)
        XCTAssertTrue(window.makeFirstResponder(root))

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertTrue(window.firstResponder === container)
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        let aiPane = try XCTUnwrap(split.arrangedSubviews.last)
        let chat = ReaderFocusableTestView()
        aiPane.addSubview(chat)
        XCTAssertTrue(window.makeFirstResponder(chat))

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

        XCTAssertTrue(window.firstResponder === chat)
        XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 124)))
    }

    func testReaderReactivationPreservesLiveFieldEditorAndPresentationFocus() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in true })
        root.addSubview(container)
        let editor = NSTextView(frame: .zero)
        root.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 49)))
        container.isReaderFocusAllowed = false
        XCTAssertTrue(window.makeFirstResponder(root))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === root)
    }

    func testReaderContentAttachmentFocusesWebKitButDoesNotStealChat() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in true })
        root.addSubview(container)
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        let readerPane = try XCTUnwrap(split.arrangedSubviews.first)
        let webView = ReaderWebView(frame: .zero, configuration: WKWebViewConfiguration())

        readerPane.addSubview(webView)

        let webResponder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(webResponder === webView || webResponder.isDescendant(of: webView))
        webView.blocksReaderKeyboardHandling = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === webResponder)
        XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 124)))

        let aiPane = try XCTUnwrap(split.arrangedSubviews.last)
        let chat = ReaderFocusableTestView()
        aiPane.addSubview(chat)
        XCTAssertTrue(window.makeFirstResponder(chat))
        let replacement = ReaderWebView(frame: .zero, configuration: WKWebViewConfiguration())
        readerPane.addSubview(replacement)
        XCTAssertTrue(window.firstResponder === chat)
    }

    func testReaderKeyboardRoutingLeavesUnrelatedShortcutsUntouched() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        var handledKeys = 0
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in
            handledKeys += 1
            return true
        })
        try XCTUnwrap(window.contentView).addSubview(container)

        let shortcuts: [NSEvent.ModifierFlags] = [.command, .control, .option, [.shift, .command]]
        for modifiers in shortcuts {
            XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 124, modifiers: modifiers)))
        }
        XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 49, modifiers: .shift)))
        XCTAssertFalse(container.routeReaderKey(try makeKeyEvent(keyCode: 0)))
        XCTAssertEqual(handledKeys, 0)
        XCTAssertTrue(container.routeReaderKey(try makeKeyEvent(keyCode: 123, modifiers: .shift)))
        XCTAssertTrue(container.routeReaderKey(try makeKeyEvent(keyCode: 116)))
        XCTAssertTrue(container.routeReaderKey(try makeKeyEvent(keyCode: 121)))
        XCTAssertEqual(handledKeys, 3)
    }

    func testReaderPreflightHandlesWebKitPageDownOnceAndDetachesWithReader() throws {
        let window = makeInteractionWindow()
        defer { window.close() }
        var attemptedKeys = 0
        let container = makeContainer(splitRatio: 0.65, onReaderKeyDown: { _ in
            attemptedKeys += 1
            return true
        })
        try XCTUnwrap(window.contentView).addSubview(container)
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        let readerPane = try XCTUnwrap(split.arrangedSubviews.first)
        let webView = ReaderWebView(frame: .zero, configuration: WKWebViewConfiguration())
        readerPane.addSubview(webView)

        NSApplication.shared.sendEvent(try makeKeyEvent(keyCode: 121, window: window))
        XCTAssertEqual(attemptedKeys, 1)

        container.removeFromSuperview()
        let otherResponder = ReaderFocusableTestView()
        try XCTUnwrap(window.contentView).addSubview(otherResponder)
        XCTAssertTrue(window.makeFirstResponder(otherResponder))
        NSApplication.shared.sendEvent(try makeKeyEvent(keyCode: 121, window: window))
        XCTAssertEqual(attemptedKeys, 1)
    }

    private func makeInteractionWindow() -> ReaderInteractionTestWindow {
        _ = NSApplication.shared
        let window = ReaderInteractionTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = ReaderFocusableTestView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        return window
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        ))
    }

    private func makeContainer(
        splitRatio: CGFloat,
        scheduler: any PaneContentUpdateScheduling = ImmediatePaneContentUpdateScheduler(),
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        onReaderKeyDown: ((NSEvent) -> Bool)? = nil,
        splitRatioCommitScheduler: any SplitRatioCommitScheduling = ImmediateSplitRatioCommitScheduler()
    ) -> ReaderSplitContainerView<Text, Text> {
        let container = ReaderSplitContainerView(
            splitRatio: splitRatio,
            minimumLeadingWidth: ReaderSplitLayout.readerMinimumWidth,
            minimumTrailingWidth: ReaderSplitLayout.aiMinimumWidth,
            onSplitRatioChange: onSplitRatioChange,
            onReaderKeyDown: onReaderKeyDown,
            leading: Text("Reader"),
            trailing: Text("AI"),
            paneContentUpdateScheduler: scheduler,
            splitRatioCommitScheduler: splitRatioCommitScheduler
        )
        if onReaderKeyDown != nil {
            container.setContainerSize(CGSize(width: 1000, height: 700))
        }
        return container
    }
}

@MainActor
private final class NativeHeaderTestWindow: NSWindow {
    var simulatedMouseLocation = NSPoint(x: -100, y: -100)
    var zoomCount = 0
    var minimizeCount = 0
    var dragCount = 0

    override var mouseLocationOutsideOfEventStream: NSPoint { simulatedMouseLocation }
    override func performZoom(_ sender: Any?) { zoomCount += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizeCount += 1 }
    override func performDrag(with event: NSEvent) { dragCount += 1 }
}

@MainActor
private final class NativeHeaderFlippedTestView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ReaderInteractionTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class ReaderFocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class ImmediatePaneContentUpdateScheduler: PaneContentUpdateScheduling {
    func schedule(_ update: @escaping () -> Void) {
        update()
    }
}

@MainActor
private final class ManualPaneContentUpdateScheduler: PaneContentUpdateScheduling {
    private var pendingUpdates: [() -> Void] = []

    var pendingUpdateCount: Int {
        pendingUpdates.count
    }

    func schedule(_ update: @escaping () -> Void) {
        pendingUpdates.append(update)
    }

    func runPendingUpdates() {
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        updates.forEach { $0() }
    }
}

@MainActor
private final class ImmediateSplitRatioCommitScheduler: SplitRatioCommitScheduling {
    func schedule(_ update: @escaping () -> Void) {
        update()
    }

    func cancelPending() {}
}

@MainActor
private final class ManualSplitRatioCommitScheduler: SplitRatioCommitScheduling {
    private var pendingUpdate: (() -> Void)?

    var pendingUpdateCount: Int {
        pendingUpdate == nil ? 0 : 1
    }

    func schedule(_ update: @escaping () -> Void) {
        pendingUpdate = update
    }

    func cancelPending() {
        pendingUpdate = nil
    }

    func runPendingUpdates() {
        let update = pendingUpdate
        pendingUpdate = nil
        update?()
    }
}
