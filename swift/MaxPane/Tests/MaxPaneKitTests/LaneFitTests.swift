import AppKit
import Testing
import LanedCore
@testable import MaxPaneKit

/// A lane wider than the room left on screen fits it, and springs back when
/// the room comes back (ADR-0047). The window clamps; the ledger keeps.
///
/// Every expected number is an explicit `CGFloat` or `UInt32`, for the reason
/// `StripRevealTests` gives: a literal expression inside `#expect` is re-typed.
@Suite("a lane fits the room")
@MainActor
struct LaneFitTests {
    private func lanes(_ widths: [UInt32], span: UInt32 = 1) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: span, panes: [])
        }
    }

    // MARK: - the room

    @Test("the room is the visible strip less a peek each side, and all of it for a lane alone")
    func theRoom() {
        #expect(LaneFit.room(viewport: 800, laneCount: 3, peek: 28) == CGFloat(744))
        #expect(LaneFit.room(viewport: 800, laneCount: 1, peek: 28) == CGFloat(800))
        // No peek configured, no peek taken.
        #expect(LaneFit.room(viewport: 800, laneCount: 3, peek: 0) == CGFloat(800))
    }

    @Test("a dock or the sidebar is already off the viewport it is handed, so it narrows the room")
    func docksAndSidebarNarrowIt() {
        // 1600 pt window, a 420 pt inset dock and the rails: the strip's
        // visible window is what `layoutDocks` measures, and the room follows.
        let open = LaneFit.room(viewport: 1600 - 420, laneCount: 3, peek: 28)
        let closed = LaneFit.room(viewport: 1600, laneCount: 3, peek: 28)
        #expect(open == CGFloat(1124))
        #expect(closed == CGFloat(1544))
    }

    @Test("an unknown viewport clamps nothing, and a tiny one stops at the floor")
    func theEdges() {
        #expect(LaneFit.room(viewport: 0, laneCount: 3, peek: 28) == .infinity)
        #expect(LaneFit.room(viewport: 90, laneCount: 3, peek: 28) == LaneFit.floorPt)
        let strip = lanes([656, 1312])
        #expect(LaneFit.fit(strip, room: .infinity) == strip)
    }

    // MARK: - the clamp

    @Test("only a lane wider than the room is clamped, and to exactly the room")
    func onlyTheWideOnes() {
        let strip = lanes([420, 656, 1312])
        let fitted = LaneFit.fit(strip, room: 600)
        #expect(fitted.map(\.widthPt) == [UInt32(420), 600, 600])
        // Same lanes, same order, so every index into one is an index into
        // the other — the invariant the eviction window rests on.
        #expect(fitted.map(\.id) == strip.map(\.id))
        // Nothing ever grows past its own width.
        #expect(LaneFit.fit(strip, room: 2000) == strip)
    }

    @Test("an xl lane in a window that fits one m fits the room, and is xl again with more")
    func xlFitsAndComesBack() {
        let xl = lanes([1312], span: 2)
        // A window that fits one m: 656 + two peeks, with neighbours.
        let small = LaneFit.room(viewport: 712, laneCount: 3, peek: 28)
        let fitted = LaneFit.fit(xl, room: small)
        #expect(fitted[0].widthPt == UInt32(656))
        // Span, zoom and everything else about the lane are the ledger's.
        #expect(fitted[0].span == UInt32(2))
        let big = LaneFit.room(viewport: 2560, laneCount: 3, peek: 28)
        #expect(LaneFit.fit(xl, room: big)[0].widthPt == UInt32(1312))
    }

    @Test("the carousel still peeks around a clamped lane")
    func theCarouselStillPeeks() throws {
        let viewport: CGFloat = 700
        let strip = LaneFit.fit(
            lanes([656, 1312, 656]),
            room: LaneFit.room(viewport: viewport, laneCount: 3, peek: 28))
        let slots = StripEdges.slots(of: strip)
        // Narrower than the window, so it is a carousel and centres...
        #expect(StripReveal.isCarousel(around: 1, slots: slots, viewport: viewport))
        let offset = try #require(StripReveal.focused(
            from: 0, to: "lane-1", lanes: strip, viewport: viewport))
        let lane = slots[1]
        // ...with the whole lane on screen and a sliver of each neighbour.
        #expect(lane.origin >= offset)
        #expect(lane.end <= offset + viewport)
        #expect(lane.origin - offset > 20)
        #expect(offset + viewport - lane.end > 20)
    }

    @Test("whether a change of room changes anything drawn")
    func differs() {
        let strip = lanes([420, 656])
        #expect(!LaneFit.differs(strip, 800, 900))
        #expect(LaneFit.differs(strip, 600, 900))
    }

    // MARK: - on a real strip

    /// The splitLane's two panes, the other two lanes' one each: every pane's
    /// width as drawn.
    private func widths(_ rig: MaximizeRig) -> [String: CGFloat] {
        rig.frames().mapValues(\.width)
    }

    @Test("a window narrower than a lane fits it; widening brings its own width back; the ledger never hears")
    func theWindowClampsTheLedgerKeeps() async throws {
        try await MaximizeRig.with { rig in
            let ledger = rig.store.state.lanes.map(\.widthPt)
            let own = try #require(rig.store.lane(rig.splitLane)).widthPt
            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            let before = widths(rig)
            #expect(abs(before[rig.splitTop]! - CGFloat(own)) < 2)

            rig.window.setContentSize(NSSize(width: 560, height: 1000))
            await rig.settle()
            let scroll = try #require(rig.strip.view.firstDescendant(NSScrollView.self))
            let visible = scroll.contentView.bounds.width
            // Narrower than it wants to be, and whole on screen: exactly the
            // room, both panes of the split alike.
            let clamped = try #require(widths(rig)[rig.splitTop])
            #expect(clamped < CGFloat(own) - 50)
            #expect(clamped <= visible)
            #expect(abs(widths(rig)[rig.splitBottom]! - clamped) < 1)
            // Brought to the middle, it is whole on screen with room to spare
            // for the neighbours' slivers — which no scroll could do for a
            // lane wider than the window.
            rig.strip.reveal(laneId: rig.splitLane, flash: false)
            await rig.settle()
            let pane = rig.stub(rig.splitTop).view
            let onScreen = pane.convert(pane.bounds, to: scroll.contentView)
            #expect(onScreen.minX >= scroll.contentView.bounds.minX - 1)
            #expect(onScreen.maxX <= scroll.contentView.bounds.maxX + 1)

            // Nothing was written.
            rig.store.refreshIfChanged()
            #expect(rig.store.state.lanes.map(\.widthPt) == ledger)

            rig.window.setContentSize(NSSize(width: 1600, height: 1000))
            await rig.settle()
            #expect(abs(widths(rig)[rig.splitTop]! - before[rig.splitTop]!) < 1)
            #expect(rig.store.state.lanes.map(\.widthPt) == ledger)
        }
    }

    @Test("docking a lane reclamps the rest, and undocking gives them their width back")
    func aDockReclamps() async throws {
        try await MaximizeRig.with { rig in
            rig.window.setContentSize(NSSize(width: 1100, height: 1000))
            await rig.settle()
            let own = try #require(rig.store.lane(rig.splitLane)).widthPt
            #expect(abs(widths(rig)[rig.splitTop]! - CGFloat(own)) < 2)

            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 520)
            await rig.settle()
            let scroll = try #require(rig.strip.view.firstDescendant(NSScrollView.self))
            let clamped = widths(rig)[rig.splitTop]!
            #expect(clamped < CGFloat(own))
            #expect(clamped <= scroll.contentView.bounds.width)

            try rig.store.undockLane(rig.rightLane)
            await rig.settle()
            #expect(abs(widths(rig)[rig.splitTop]! - CGFloat(own)) < 2)
            #expect(rig.store.lane(rig.splitLane)?.widthPt == own)
        }
    }
}
