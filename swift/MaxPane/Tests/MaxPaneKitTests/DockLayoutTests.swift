import AppKit
import Testing
import LanedCore
@testable import MaxPaneKit

/// What the docks take, and what the window can actually afford.
///
/// The narrow-window rule is specified in the contract and had never been run:
/// *"Nobody has run two inset docks in an 800 pt window."* It is also the one
/// case a screenshot cannot settle, because getting it wrong looks like a
/// slightly cramped strip rather than like a bug — so the arithmetic is pulled
/// out here for the same reason `LaneSnap` and `LanePeek` were.
///
/// Note the `CGFloat(...)` around every expected number: a literal expression
/// inside `#expect` is re-typed by the macro and compares as an `Int`. Same
/// trap `SnapAndConfigTests` documents.
@Suite("dock layout")
struct DockLayoutTests {
    private func dock(_ side: DockSide, _ mode: DockMode, _ width: UInt32) -> Dock {
        Dock(side: side, mode: mode, widthPt: width)
    }

    /// The window Max Pane actually runs in: 1600 pt of window less the two
    /// 18 pt rails.
    private let wide: CGFloat = 1564
    private let laneMin: CGFloat = 420

    @Test("a dock in a wide window is exactly the width it was given")
    func widthIsHonoured() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .inset, 320), right: nil, viewport: wide, laneMinPt: laneMin)
        #expect(layout.left == DockGeometry.Placement(width: CGFloat(320), mode: .inset))
        #expect(layout.right == nil)
        #expect(layout.insetLeft == CGFloat(320))
        #expect(layout.overlayLeft == CGFloat(0))
    }

    @Test("two inset docks fit either side of a readable lane")
    func twoInsetsInAWideWindow() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .inset, 320), right: dock(.right, .inset, 400),
            viewport: wide, laneMinPt: laneMin)
        #expect(layout.left?.mode == .inset)
        #expect(layout.right?.mode == .inset)
        // 1564 - 420 = 1144 to share, 572 each: both asked for less.
        #expect(layout.insetLeft == CGFloat(320))
        #expect(layout.insetRight == CGFloat(400))
        // ...and a lane is still wider than its minimum afterwards.
        #expect(wide - layout.insetLeft - layout.insetRight >= laneMin)
    }

    /// The clamp, and the half of it that matters: it is not written back.
    /// `resolve` is handed the ledger's `Dock` and returns a *drawing*, so
    /// there is nowhere for a narrowed width to be stored — which is the point.
    @Test("a dock wider than the window can afford is drawn narrower, not stored narrower")
    func clampedNotRewritten() {
        let asked = dock(.left, .inset, 900)
        let layout = DockGeometry.resolve(
            left: asked, right: nil, viewport: 1000, laneMinPt: laneMin)
        // 1000 - 420 = 580 of room, so 900 is drawn at 580.
        #expect(layout.left?.width == CGFloat(580))
        #expect(layout.left?.mode == .inset)
        #expect(asked.widthPt == UInt32(900))

        // Open the window and the dock is 900 again, with nothing to undo.
        let grown = DockGeometry.resolve(
            left: asked, right: nil, viewport: wide, laneMinPt: laneMin)
        #expect(grown.left?.width == CGFloat(900))
    }

    /// Contract position 4. Two inset docks need `2 × 240 + 420 = 900` pt, so
    /// an 800 pt window cannot have them and says so by floating them.
    @Test("two inset docks in an 800 pt window both degrade to overlay")
    func narrowWindowDegradesToOverlay() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .inset, 300), right: dock(.right, .inset, 300),
            viewport: 800, laneMinPt: laneMin)
        #expect(layout.left?.mode == .overlay)
        #expect(layout.right?.mode == .overlay)
        // Nothing is taken out of the strip, so no lane is squeezed under 420.
        #expect(layout.insetLeft == CGFloat(0))
        #expect(layout.insetRight == CGFloat(0))
        // 800 - 160 of strip floor, shared: 320 each, so 300 is honoured.
        #expect(layout.overlayLeft == CGFloat(300))
        #expect(layout.overlayRight == CGFloat(300))
    }

    /// The boundary, stated as the sum it comes from rather than as "about
    /// 900": exactly 900 affords two minimum docks and a minimum lane.
    @Test("900 pt is where two inset docks start fitting")
    func theExactBoundary() {
        let below = DockGeometry.resolve(
            left: dock(.left, .inset, 240), right: dock(.right, .inset, 240),
            viewport: 899, laneMinPt: laneMin)
        #expect(below.left?.mode == .overlay)

        let atIt = DockGeometry.resolve(
            left: dock(.left, .inset, 240), right: dock(.right, .inset, 240),
            viewport: 900, laneMinPt: laneMin)
        #expect(atIt.left?.mode == .inset)
        #expect(atIt.right?.mode == .inset)
        #expect(atIt.insetLeft + atIt.insetRight == CGFloat(480))
    }

    /// Degradation is symmetric on purpose: both inset docks share one budget,
    /// so which of them floats can never depend on the order they were
    /// considered in.
    @Test("neither side wins the narrow window")
    func degradationIsSymmetric() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .inset, 240), right: dock(.right, .inset, 800),
            viewport: 850, laneMinPt: laneMin)
        #expect(layout.left?.mode == .overlay)
        #expect(layout.right?.mode == .overlay)
    }

    @Test("an inset dock beside an overlay one only has to afford itself")
    func oneOfEach() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .inset, 300), right: dock(.right, .overlay, 300),
            viewport: 800, laneMinPt: laneMin)
        // Only one inset dock, so the whole 380 of slack is its share.
        #expect(layout.left?.mode == .inset)
        #expect(layout.insetLeft == CGFloat(300))
        // The overlay is capped against what is left over, not against the
        // whole window: 800 - 300 inset - 160 floor = 340.
        #expect(layout.right?.mode == .overlay)
        #expect(layout.overlayRight == CGFloat(300))
    }

    @Test("a window with no room at all still leaves a strip")
    func pathologicallyNarrow() {
        let layout = DockGeometry.resolve(
            left: dock(.left, .overlay, 400), right: dock(.right, .overlay, 400),
            viewport: 400, laneMinPt: laneMin)
        // (400 - 160) / 2 = 120 each, which is narrower than DOCK_MIN and is
        // the honest answer: there is nothing else to give.
        #expect(layout.overlayLeft == CGFloat(120))
        #expect(layout.overlayRight == CGFloat(120))
        #expect(400 - layout.overlayLeft - layout.overlayRight
            == DockGeometry.stripFloorPt)
    }

    // MARK: - the visible window

    /// The whole of contract position 2, in one function: an overlay dock is an
    /// edge because the strip's visible window genuinely stops there.
    @Test("an inset dock is already gone from the clip view; an overlay is not")
    func visibleWindow() {
        let inset = DockGeometry.resolve(
            left: dock(.left, .inset, 320), right: nil, viewport: wide, laneMinPt: laneMin)
        // The clip view was made 320 narrower, so it reports 1244 and there is
        // nothing left to subtract.
        let a = DockGeometry.visible(clipOffset: 1000, clipWidth: 1244, layout: inset)
        #expect(a.offset == CGFloat(1000))
        #expect(a.width == CGFloat(1244))

        let overlay = DockGeometry.resolve(
            left: dock(.left, .overlay, 320), right: dock(.right, .overlay, 280),
            viewport: wide, laneMinPt: laneMin)
        // The clip view still spans the lot, so both docks come off here.
        let b = DockGeometry.visible(clipOffset: 1000, clipWidth: wide, layout: overlay)
        #expect(b.offset == CGFloat(1320))
        #expect(b.width == wide - 600)
    }

    /// A lane sitting under an overlay must count as hidden, or overlay mode
    /// silently re-breaks what the rails were built to fix: *"i can't tell if
    /// there are more panes to the right or left."*
    @Test("the rails count a lane under an overlay as hidden")
    func railsSeeThroughTheOverlay() {
        let lanes = (0..<6).map { index in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: 600, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: 1, panes: [])
        }
        let overlay = DockGeometry.resolve(
            left: nil, right: dock(.right, .overlay, 620), viewport: 1800, laneMinPt: laneMin)
        // Scrolled to the start of a 3606 pt strip in an 1800 pt window: lanes
        // 0 and 1 are on screen and lane 2 (1202…1802) is all but flush with
        // the right edge.
        let full = StripEdges.hidden(lanes: lanes, offset: 0, viewport: 1800)
        #expect(full.right == 3)

        let window = DockGeometry.visible(clipOffset: 0, clipWidth: 1800, layout: overlay)
        let occluded = StripEdges.hidden(
            lanes: lanes, offset: window.offset, viewport: window.width)
        // With 620 pt of dock over the right-hand end, lane 2 is behind it and
        // the rail says so.
        #expect(occluded.right == 4)
    }
}
