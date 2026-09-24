import AppKit
import Testing
@testable import MaxPaneKit

/// The gallery has walls: a docked lane is pinned and readable there too
/// (ADR-0011 and ADR-0019, both amended 2026-09-24;
/// `docs/critiques/docking.md` finding 1).
///
/// Judged against the one sentence the whole feature answers to: *"The purpose
/// of docking is to pin one or more lanes in expanded mode so I can keep them
/// readable as I navigate some other lanes temporarily."* Until this landed,
/// ⌘G threw the pin away — `layoutDocks` returned before placing a wall and the
/// lane became one thumbnail among twenty.
///
/// On the `MaximizeRig` strip: three lanes, the middle one split, in a real
/// window 1600 × 1000.
@Suite("gallery walls", .serialized)
@MainActor
struct DockGalleryWallTests {
    /// The lane's drawn rect in window coordinates, measured from its pane's
    /// view rather than from a private lane view.
    private func paneRect(_ rig: MaximizeRig, _ paneId: String) -> CGRect {
        let view = rig.stub(paneId).view
        return view.convert(view.bounds, to: nil)
    }

    // MARK: - it does not move

    @Test("⌘G moves a docked lane not at all, and ⌘G again brings it back to the same rect")
    func theWallDoesNotMove() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 420)
            await rig.settle()
            let onTheStrip = paneRect(rig, rig.right)
            #expect(abs(onTheStrip.width - 420) < 2)

            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            #expect(rig.strip.isGallery)
            // The whole point: the same rect, to the point.
            #expect(paneRect(rig, rig.right) == onTheStrip)
            // And still its own lane at scale 1, not a tile: no tile exists for
            // it, so nothing is drawing it smaller.
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) == nil)
            // It never left the window, which is the audio guarantee.
            #expect(rig.stub(rig.right).view.window != nil)

            #expect(rig.strip.setLayout(.lanes))
            await rig.settle()
            #expect(paneRect(rig, rig.right) == onTheStrip)
            #expect(rig.stub(rig.right).view.window != nil)
        }
    }

    @Test("a wall is the lane at full size, where every other lane is a thumbnail")
    func theWallIsReadable() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.leftLane, side: .left, mode: .inset, widthPt: 400)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()

            let wall = paneRect(rig, rig.left)
            // Its real size, exactly: the dock's width, at scale 1.
            #expect(abs(wall.width - 400) < 2)
            // The gallery is 1000 pt tall and the wall takes all of it, less
            // nothing but its own header — a real column, not a sliver.
            #expect(wall.height > 800)

            // Every other lane is drawn smaller than it really is, which is
            // what a tile is. The wall is the one that is not.
            let right = try #require(rig.store.lane(rig.rightLane))
            #expect(paneRect(rig, rig.right).width < CGFloat(right.widthPt))
        }
    }

    // MARK: - the grid around it

    @Test("the tiles are laid into the gallery less its walls, on one edge and on both")
    func theGridClearsTheWalls() async throws {
        try await MaximizeRig.with { rig in
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            let window = rig.strip.view.convert(rig.strip.view.bounds, to: nil)

            try rig.store.dockLane(rig.leftLane, side: .left, mode: .inset, widthPt: 400)
            await rig.settle()
            let leftWall = paneRect(rig, rig.left)
            let oneWall = try #require(rig.strip.tileRect(rig.splitLane))
            #expect(oneWall.minX >= leftWall.maxX - 0.5)
            #expect(oneWall.maxX <= window.maxX + 0.5)

            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 400)
            await rig.settle()
            let rightWall = paneRect(rig, rig.right)
            let bothWalls = try #require(rig.strip.tileRect(rig.splitLane))
            #expect(bothWalls.minX >= leftWall.maxX - 0.5)
            #expect(bothWalls.maxX <= rightWall.minX + 0.5)
            // 1600 pt less two 400 pt walls and the rail's width outside each:
            // the grid really is laid into what is left, not over it.
            #expect(bothWalls.width <= 1600 - 2 * (400 + StripEdgeRail.width))
            // Both docked lanes are at a wall, so neither has a tile.
            #expect(rig.strip.layoutMotionLayer(laneId: rig.leftLane) == nil)
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) == nil)
        }
    }

    @Test("an overlay wall takes its room too, because the gallery cannot be scrolled out from under one")
    func overlayTakesItsRoom() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.leftLane, side: .left, mode: .overlay, widthPt: 400)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()

            let wall = paneRect(rig, rig.left)
            let tile = try #require(rig.strip.tileRect(rig.splitLane))
            #expect(tile.minX >= wall.maxX - 0.5)
            // ⌃⌘\ back to inset: the grid is in the same place, because both
            // modes cost the gallery the same room. What changes is the drawing.
            try rig.store.toggleDockMode(rig.leftLane)
            await rig.settle()
            #expect(rig.strip.tileRect(rig.splitLane) == tile)
            #expect(paneRect(rig, rig.left) == wall)
        }
    }

    // MARK: - what navigation may do to it

    @Test("a docked lane can never be the expanded tile, by key, double click or sidebar row")
    func theWallIsNeverExpanded() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()

            rig.strip.expandTile(laneId: rig.rightLane, paneId: rig.right)
            #expect(rig.strip.expandedLaneId == nil)

            // A double click on its session row selects it and expands nothing.
            rig.strip.openLane(laneId: rig.rightLane, paneId: rig.right)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.store.state.focusedPaneId == rig.right)

            // With another tile up, focusing the wall leaves the expansion
            // where it is — the exemption at `ensureVisible`'s first line.
            rig.strip.expandTile(laneId: rig.leftLane, paneId: rig.left)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            rig.strip.openLane(laneId: rig.rightLane, paneId: rig.right)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
        }
    }

    @Test("⇧⌘↩ maximizes clear of the walls in the gallery, as it does on the strip")
    func maximizeClearsTheWalls() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.leftLane, side: .left, mode: .inset, widthPt: 400)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            let wall = paneRect(rig, rig.left)

            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            rig.strip.toggleMaximizeFocusedPane()
            rig.layout()
            #expect(rig.strip.isPaneMaximized)
            let viewport = rig.strip.maximizedViewportRect
            #expect(viewport.minX >= 400)
            #expect(viewport.maxX == rig.strip.view.bounds.maxX)
            // The pinned lane is still readable, which is what it is pinned for.
            #expect(paneRect(rig, rig.left) == wall)
            #expect(paneRect(rig, rig.splitTop).minX >= wall.maxX - 0.5)

            rig.strip.toggleMaximizeFocusedPane()
            rig.strip.landMaximizeTransition()
            await rig.settle()
            #expect(paneRect(rig, rig.left) == wall)
        }
    }

    // MARK: - docking and undocking with the gallery up

    @Test("⌃⌘] in the gallery moves the lane to the wall and back, and never out of the window")
    func dockingInTheGallery() async throws {
        try await MaximizeRig.with { rig in
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) != nil)

            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 380)
            await rig.settle()
            // A wall now: no tile, full height, the dock's width — and the same
            // view, never taken out of the window on the way.
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) == nil)
            #expect(rig.stub(rig.right).view.window != nil)
            let wall = paneRect(rig, rig.right)
            #expect(abs(wall.width - 380) < 2)
            #expect(wall.height > 800)
            #expect(try #require(rig.strip.tileRect(rig.splitLane)).maxX <= wall.minX + 0.5)

            try rig.store.undockLane(rig.rightLane)
            await rig.settle()
            // Back on the grid as an ordinary tile, drawn smaller than it is,
            // and still in the window the whole way.
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) != nil)
            #expect(rig.stub(rig.right).view.window != nil)
            let right = try #require(rig.store.lane(rig.rightLane))
            #expect(paneRect(rig, rig.right).width < CGFloat(right.widthPt))
        }
    }

    @Test("docking the expanded tile puts the expansion down rather than carrying it to the wall")
    func dockingWhatWasExpanded() async throws {
        try await MaximizeRig.with { rig in
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.rightLane, paneId: rig.right)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.rightLane)

            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 380)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.strip.layoutMotionLayer(laneId: rig.rightLane) == nil)
            #expect(rig.stub(rig.right).view.window != nil)
        }
    }
}
