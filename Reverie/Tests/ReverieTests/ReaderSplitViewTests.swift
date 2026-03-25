import AppKit
import SwiftUI
import XCTest
@testable import Reverie

@MainActor
final class ReaderSplitViewTests: XCTestCase {
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

    private func makeContainer(
        splitRatio: CGFloat,
        scheduler: any PaneContentUpdateScheduling = ImmediatePaneContentUpdateScheduler(),
        onSplitRatioChange: ((CGFloat) -> Void)? = nil,
        splitRatioCommitScheduler: any SplitRatioCommitScheduling = ImmediateSplitRatioCommitScheduler()
    ) -> ReaderSplitContainerView<Text, Text> {
        ReaderSplitContainerView(
            splitRatio: splitRatio,
            minimumLeadingWidth: ReaderSplitLayout.readerMinimumWidth,
            minimumTrailingWidth: ReaderSplitLayout.aiMinimumWidth,
            onSplitRatioChange: onSplitRatioChange,
            leading: Text("Reader"),
            trailing: Text("AI"),
            paneContentUpdateScheduler: scheduler,
            splitRatioCommitScheduler: splitRatioCommitScheduler
        )
    }
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
