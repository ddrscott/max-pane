import AppKit
import Testing
@testable import MaxPaneKit

/// **While a tile is expanded, anything that lands focus on a different lane
/// expands that lane instead** (ADR-0011, amended 2026-09-24).
///
/// The rule lives at one place — `ensureVisible(_:)`, where `focus(_:)` ends
/// and where every focus that arrives through the ledger ends too — so these
/// tests drive the two doors into it rather than one case per command:
///
/// - `store.focusPane` and a settle: the ledger path. ⌘P's hit, ⌘E, an
///   `[[apps]]` web-app chord, `maxpane attach` and `maxpane app` all land
///   here, through `apply(_:)`.
/// - `strip.select(laneId:paneId:)`: the sidebar row, ⌘O, the status bar's
///   BLOCKED count, a search hit, and ⌘J / ⇧⌘J, which reach it through
///   `StripWindowController.attach`.
/// - `strip.handleClick`: the mouse, which is the monitor's own body.
///
/// On the `MaximizeRig` strip — three lanes, the middle one split — put up as
/// a gallery.
@Suite("gallery focus moves the expansion", .serialized)
@MainActor
struct GalleryFocusExpansionTests {
    /// Exactly one tile is expanded, and it is the one the controller names.
    private func expandedTiles(_ rig: MaximizeRig) -> [String] {
        rig.store.state.lanes.map(\.id).filter { rig.strip.laneView(for: $0)?.isExpandedTile == true }
    }

    /// The gallery with `laneId` expanded and its `paneId` holding the keyboard.
    private func gallery(_ rig: MaximizeRig, expanding laneId: String, paneId: String) async throws {
        try rig.store.focusPane(paneId)
        await rig.settle()
        #expect(rig.strip.setLayout(.gallery))
        await rig.settle()
        rig.strip.expandTile(laneId: laneId, paneId: paneId)
        await rig.settle()
        #expect(rig.strip.expandedLaneId == laneId)
    }

    @Test("the ledger path — ⌘P, ⌘E, a web-app chord, `maxpane attach` — moves the expansion")
    func theLedgerPath() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.leftLane, paneId: rig.left)

            try rig.store.focusPane(rig.right)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(rig.store.state.focusedPaneId == rig.right)
            #expect(expandedTiles(rig) == [rig.rightLane])
            #expect(rig.stub(rig.right).focusCount > 0)

            // And the pane focused within the new lane keeps the keyboard: the
            // bottom of a split, not its first pane.
            try rig.store.focusPane(rig.splitBottom)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            #expect(expandedTiles(rig) == [rig.splitLane])
        }
    }

    @Test("`select` — the sidebar, ⌘O, ⌘J, the BLOCKED count, a search hit — moves it too")
    func theSelectPath() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.leftLane, paneId: rig.left)

            #expect(rig.strip.select(laneId: rig.splitLane, paneId: rig.splitBottom))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            #expect(expandedTiles(rig) == [rig.splitLane])

            #expect(rig.strip.select(laneId: rig.rightLane, paneId: rig.right))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(expandedTiles(rig) == [rig.rightLane])
        }
    }

    @Test("a single click on another tile moves the expansion; with nothing expanded it only focuses")
    func theSingleClick() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.leftLane, paneId: rig.left)

            _ = rig.strip.handleClick(try rig.click(on: rig.right))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(rig.store.state.focusedPaneId == rig.right)
            #expect(expandedTiles(rig) == [rig.rightLane])

            // Nothing expanded: the click focuses and stops. The double click
            // is still what expands.
            rig.strip.collapseExpandedTile()
            await rig.settle()
            _ = rig.strip.handleClick(try rig.click(on: rig.left))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.store.state.focusedPaneId == rig.left)
            #expect(expandedTiles(rig).isEmpty)

            _ = rig.strip.handleClick(try rig.click(on: rig.left, clicks: 2))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
        }
    }

    @Test("a focus change inside the expanded lane leaves the tile where it is")
    func insideTheExpandedLane() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.splitLane, paneId: rig.splitTop)
            let tile = try #require(rig.strip.layoutMotionLayer(laneId: rig.splitLane)).layer
            let before = tile.frame

            try rig.store.focusPane(rig.splitBottom)
            await rig.settle()
            rig.layout()
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            #expect(tile.frame == before)
            #expect(expandedTiles(rig) == [rig.splitLane])
            // Not re-expanded: no flight at all, so no flicker.
            #expect(tile.animation(forKey: "galleryMove") == nil)
        }
    }

    @Test("focus that lands on the lane already expanded does nothing")
    func theLaneAlreadyExpanded() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.rightLane, paneId: rig.right)
            let tile = try #require(rig.strip.layoutMotionLayer(laneId: rig.rightLane)).layer
            let before = tile.frame

            #expect(rig.strip.select(laneId: rig.rightLane, paneId: rig.right))
            try rig.store.focusPane(rig.right)
            await rig.settle()
            rig.layout()
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(tile.frame == before)
            #expect(tile.animation(forKey: "galleryMove") == nil)
            #expect(expandedTiles(rig) == [rig.rightLane])
        }
    }

    /// The docked-lane exemption (`docs/critiques/docking.md` § 3).
    ///
    /// The purpose of docking is *"to pin one or more lanes in expanded mode so
    /// I can keep them readable as I navigate some other lanes temporarily"*.
    /// Without this, ⌥⌘[ / ⌥⌘] into a dock would yank the expansion onto the
    /// one lane he pinned and the next ⌘J would yank it off again.
    @Test("focus landing on a docked lane never moves the expansion")
    func aDockedLaneIsExempt() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset)
            try await gallery(rig, expanding: rig.splitLane, paneId: rig.splitTop)

            // ⌥⌘] into the dock: the focus goes, the expansion stays.
            try rig.store.focusPane(rig.right)
            await rig.settle()
            #expect(rig.store.state.focusedPaneId == rig.right)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(expandedTiles(rig) == [rig.splitLane])

            // The sidebar row for the docked lane: the same answer.
            #expect(rig.strip.select(laneId: rig.rightLane, paneId: rig.right))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(expandedTiles(rig) == [rig.splitLane])

            // ⌥⌘] back out lands on a strip lane, and that one does move it.
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(expandedTiles(rig) == [rig.leftLane])
        }
    }

    @Test("⌘G and a click on the gallery background are not focus, and do not move it")
    func notMovedByLeavingOrCollapsing() async throws {
        try await MaximizeRig.with { rig in
            try await gallery(rig, expanding: rig.rightLane, paneId: rig.right)

            // The background between the tiles: the expanded one goes back.
            _ = rig.strip.handleClick(try rig.click(atWindowPoint: NSPoint(x: 2, y: 2)))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(expandedTiles(rig).isEmpty)
            #expect(rig.strip.isGallery)

            rig.strip.expandTile(laneId: rig.rightLane, paneId: rig.right)
            await rig.settle()
            // ⌘G: out of the gallery altogether, and nothing is expanded there.
            #expect(rig.strip.setLayout(.lanes))
            await rig.settle()
            #expect(!rig.strip.isGallery)
            #expect(rig.strip.expandedLaneId == nil)
            // And focus on the strip moves no expansion, because there is none.
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
        }
    }
}

extension MaximizeRig {
    /// A left mouse-down over a pane's view, in the rig's window.
    func click(on paneId: String, clicks: Int = 1) throws -> NSEvent {
        let laneId = try #require(store.lane(containing: paneId)?.id)
        let laneView = try #require(strip.laneView(for: laneId))
        let paneView = try #require(laneView.paneView(for: paneId))
        let middle = NSPoint(x: paneView.bounds.midX, y: paneView.bounds.midY)
        return try click(atWindowPoint: paneView.convert(middle, to: nil), clicks: clicks)
    }

    func click(atWindowPoint point: NSPoint, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1))
    }
}
