import AppKit
import Testing
@testable import MaxPaneKit

/// ⌘[ ⌘] and ⇧⌘[ ⇧⌘] with a gallery tile expanded: the expansion moves to
/// the neighbour (ADR-0011, amended 2026-09-23 and 2026-09-24).
///
/// Since the general rule landed, the keys only move *focus*
/// (`moveFocusAcrossTiles`) and `ensureVisible` moves the expansion after it —
/// so what these tests pin is the walk: where it goes, where it stops, the
/// split lane's stack, and the dock it steps over.
///
/// On the `MaximizeRig` strip — three lanes, the middle one split — put up as
/// a gallery.
@Suite("gallery cycle", .serialized)
@MainActor
struct GalleryCycleTests {
    @Test("⌘] and ⌘[ move the expansion along the strip and stop at the ends")
    func plainPair() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.leftLane, paneId: rig.left)
            await rig.settle()

            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)
            #expect(rig.stub(rig.splitTop).focusCount > 0)

            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(rig.store.state.focusedPaneId == rig.right)

            // The end: nothing happens, the tile stays.
            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(rig.store.state.focusedPaneId == rig.right)

            rig.strip.moveFocus(.left)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)
            rig.strip.moveFocus(.left)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(rig.store.state.focusedPaneId == rig.left)
            rig.strip.moveFocus(.left)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(rig.store.state.focusedPaneId == rig.left)
            #expect(rig.strip.isGallery)
        }
    }

    @Test("⇧⌘] and ⇧⌘[ walk a split lane's stack, then cross at its edge")
    func shiftPair() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.leftLane, paneId: rig.left)
            await rig.settle()

            // A single-pane lane: exactly the plain pair.
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)
            // Inside the split lane the key keeps its meaning...
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            // ...until the edge.
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(rig.store.state.focusedPaneId == rig.right)
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == rig.rightLane)

            // Back up: into the split lane through its bottom pane.
            rig.strip.moveFocus(.up)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            rig.strip.moveFocus(.up)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)
            rig.strip.moveFocus(.up)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(rig.store.state.focusedPaneId == rig.left)
            rig.strip.moveFocus(.up)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
        }
    }

    /// The cycle walks `stripLanes`, which is the strip's own order.
    ///
    /// A docked lane cannot take the expansion (`docs/critiques/docking.md`
    /// § 3, and `GalleryFocusExpansionTests`), so stepping onto one would move
    /// the ring off the tile being read and leave nothing readable behind it —
    /// the complaint this whole rule exists to fix. ⌥⌘[ / ⌥⌘] remain the way
    /// in, and going in leaves the expansion where it is.
    @Test("the cycle steps over a docked lane, exactly as ⌘[ / ⌘] do on the strip")
    func dockIsNotInTheCycle() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset)
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.leftLane, paneId: rig.left)
            await rig.settle()

            // Left → the split lane, and no further: the dock is not a stop,
            // and the split lane is now the end of the walk.
            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)
            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitTop)

            // The ⇧ pair still reads the stack, and still stops at the dock.
            rig.strip.moveFocus(.down)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)

            rig.strip.moveFocus(.left)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(rig.store.state.focusedPaneId == rig.left)
        }
    }

    @Test("with nothing expanded the keys walk focus as they always did")
    func nothingExpanded() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)

            rig.strip.moveFocus(.right)
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.store.state.focusedPaneId == rig.right)
            rig.strip.moveFocus(.left)
            rig.strip.moveFocus(.down)
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            rig.strip.moveFocus(.down)
            // The strip's rule: the bottom of the stack is the end of it.
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
            #expect(rig.strip.expandedLaneId == nil)
        }
    }

    @Test("both tiles move at once, on the lane's clock, and a repeat turns round mid-flight")
    func theMotion() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.leftLane, paneId: rig.left)
            await rig.settle()

            @MainActor func layer(_ laneId: String) throws -> CALayer {
                try #require(rig.strip.layoutMotionLayer(laneId: laneId)).layer
            }
            @MainActor func move(_ laneId: String) throws -> CABasicAnimation? {
                try layer(laneId).animation(forKey: "galleryMove") as? CABasicAnimation
            }
            /// Where a flight begins: the inverse of `GalleryLayout.moveTransforms`.
            @MainActor func start(_ laneId: String) throws -> CGRect? {
                let layer = try layer(laneId)
                guard let move = try move(laneId),
                      let from = (move.fromValue as? NSValue)?.caTransform3DValue else { return nil }
                let t = CATransform3DConcat(CATransform3DInvert(layer.transform), from)
                let to = layer.frame, p = layer.position
                return CGRect(
                    x: t.m41 + t.m11 * (to.minX - p.x) + p.x, y: t.m42 + t.m22 * (to.minY - p.y) + p.y,
                    width: t.m11 * to.width, height: t.m22 * to.height)
            }
            func near(_ a: CGRect, _ b: CGRect) -> Bool {
                abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
                    && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
            }

            let leftUp = try layer(rig.leftLane).frame
            let splitSmall = try layer(rig.splitLane).frame
            rig.strip.moveFocus(.right)
            rig.layout()
            let leftSmall = try layer(rig.leftLane).frame
            let splitUp = try layer(rig.splitLane).frame
            #expect(leftSmall.width < leftUp.width)
            #expect(splitUp.width > splitSmall.width)
            if Motion.isReduced {
                #expect(try move(rig.leftLane) == nil)
                #expect(try move(rig.splitLane) == nil)
            } else {
                // At once: the old tile shrinks from its expanded rect, the
                // new one grows from its slot, both on the lane's clock.
                let shrinking = try #require(try move(rig.leftLane))
                let growing = try #require(try move(rig.splitLane))
                #expect(shrinking.duration == Motion.lane)
                #expect(growing.duration == Motion.lane)
                #expect(near(try #require(try start(rig.leftLane)), leftUp))
                #expect(near(try #require(try start(rig.splitLane)), splitSmall))

                // A repeat before it lands turns round: the flight back begins
                // between where it was and where it was going, never snapped
                // to either end, and it is the tile's only animation.
                rig.strip.moveFocus(.left)
                rig.layout()
                #expect(rig.strip.expandedLaneId == rig.leftLane)
                #expect(try layer(rig.leftLane).frame == leftUp)
                let back = try #require(try start(rig.leftLane))
                let low = min(leftSmall.width, leftUp.width) - 1, high = max(leftSmall.width, leftUp.width) + 1
                #expect(back.width >= low && back.width <= high)
                #expect(try layer(rig.leftLane).animationKeys()?.count == 1)
                #expect(try layer(rig.splitLane).animationKeys()?.count == 1)
            }
        }
    }
}
