import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Whether the strip's edges tell the truth about what is past them.
///
/// The bug this arithmetic exists for only appears at particular window widths —
/// the ones where a whole number of lanes happens to fit — so it is exactly the
/// kind of thing that looks fine on the machine it was written on and is broken
/// on the machine it is used on. Every case here is a width, spelled out.
///
/// `LaneSnap`'s own tests carry a warning that applies to every `#expect` below:
/// a literal arithmetic expression inside the macro gets re-typed and compared
/// as an `Int`, so every expected number is written as an explicit `CGFloat`.
@Suite("strip edges")
@MainActor
struct StripEdgeTests {
    private func lanes(_ widths: [UInt32]) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: 1, panes: [])
        }
    }

    /// Uniform 600 pt lanes: the pitch is 601 with the 1 pt border, and a
    /// viewport of 600 + 2×601 = 1802 is the width at which centring a lane puts
    /// both edges exactly on a lane boundary. That window is the whole bug.
    private let width: UInt32 = 600
    private var pitch: CGFloat { CGFloat(width) + Theme.borderWidth }
    private var tiling: CGFloat { CGFloat(width) + 2 * (CGFloat(width) + Theme.borderWidth) }

    private func peek(_ offset: CGFloat, _ viewport: CGFloat, _ widths: [UInt32], _ minimum: CGFloat = 28) -> CGFloat {
        LanePeek.adjust(offset: offset, viewport: viewport, lanes: lanes(widths), minimum: minimum)
    }

    @Test("a window that fits a whole number of lanes does not rest flush")
    func breaksAnExactTiling() {
        let widths = [UInt32](repeating: width, count: 7)
        // Lane 3 centred: origin 3×601 = 1803, minus one whole lane of slack on
        // each side, lands the left edge exactly on lane 2's origin. Nothing
        // peeks in from either side; this is the screen Scott could not place
        // himself on.
        let centred = 2 * pitch
        #expect(centred == CGFloat(1202))
        let rested = peek(centred, tiling, widths)
        #expect(rested != centred)
        #expect(rested - centred == CGFloat(29))
    }

    @Test("after settling, both edges are cutting through a lane")
    func bothEdgesCutALane() {
        let widths = [UInt32](repeating: width, count: 7)
        let rested = peek(2 * pitch, tiling, widths)
        let slots = StripEdges.slots(of: lanes(widths))

        // The right edge: how much of the first lane it does not clear is showing.
        let right = rested + tiling
        let cutRight = slots.first { $0.end > right }
        #expect(cutRight != nil)
        #expect(right - (cutRight?.origin ?? 0) >= CGFloat(28))

        // The left edge: the tail of the last lane that starts before it.
        let cutLeft = slots.last { $0.origin < rested }
        #expect(cutLeft != nil)
        #expect((cutLeft?.end ?? 0) - rested >= CGFloat(28))
    }

    @Test("a window that does not tile is left exactly where the snap put it")
    func leavesAnHonestOffsetAlone() {
        let widths = [UInt32](repeating: width, count: 7)
        // A 1500 pt window is not a whole number of 601 pt lanes, so centring
        // lane 3 (origin 1803) already leaves 449 pt of a lane showing at each
        // edge. Moving that would be meddling.
        let centred = CGFloat(1353)
        #expect(peek(centred, 1500, widths) == centred)
    }

    @Test("the settle never moves further than the peek it is buying")
    func neverMovesMoreThanTheMinimum() {
        let widths = [UInt32](repeating: width, count: 9)
        // Every offset a snap could produce, at a handful of window widths
        // including the pathological one. The bound is the argument for doing
        // this in the snap at all: a settle that can jump 200 pt is a settle
        // that fights the user.
        //
        // Peek plus two, not peek: an edge can start out in the 1 pt gap
        // *between* two lanes, and the hairline tolerance treats another point
        // either side of that as the same nothing. Both are slop in the lane's
        // favour — they can only ever make the sliver wider than asked for.
        let bound = CGFloat(28) + Theme.borderWidth + StripEdges.hairline
        for viewport in [CGFloat(700), CGFloat(1202), tiling, CGFloat(1500), CGFloat(2405)] {
            let limit = StripEdges.contentWidth(of: lanes(widths)) - viewport
            for step in 0...48 {
                // Offsets a scroll can actually be at. Past the end, `adjust`
                // clamps, and a clamp is not a nudge.
                let offset = min(CGFloat(step) * 100, limit)
                let rested = peek(offset, viewport, widths)
                #expect(abs(rested - offset) <= bound)
            }
        }
    }

    @Test("the start of the strip stays at the start")
    func doesNotScrollAwayFromTheFirstLane() {
        let widths = [UInt32](repeating: width, count: 7)
        // Even though the right edge is flush here, shifting would hide the
        // first 28 pt of lane 0 with no offset that ever shows it again — the
        // snap would pull back to the shifted position every time.
        #expect(peek(0, tiling, widths) == CGFloat(0))
    }

    @Test("the end of the strip stays at the end")
    func doesNotScrollAwayFromTheLastLane() {
        let widths = [UInt32](repeating: width, count: 7)
        let limit = StripEdges.contentWidth(of: lanes(widths)) - tiling
        #expect(peek(limit, tiling, widths) == limit)
    }

    @Test("a strip that fits the window is left alone")
    func nothingToProveWhenItAllFits() {
        #expect(peek(0, 4000, [width, width, width]) == CGFloat(0))
    }

    @Test("a lane wider than the window is already cut at both edges")
    func aLaneWiderThanTheViewport() {
        // A 400 pt window inside a 900 pt lane. Both edges are deep inside the
        // same lane, so the strip is *visibly* continuing in both directions
        // already and there is nothing to fix — the narrow-window case must not
        // become a permanent 28 pt twitch.
        for offset in [CGFloat(100), CGFloat(200), CGFloat(300)] {
            #expect(peek(offset, 400, [900, 900, 900]) == offset)
        }
    }

    @Test("turning the peek off restores exactly centred snapping")
    func zeroDisablesIt() {
        let widths = [UInt32](repeating: width, count: 7)
        #expect(peek(2 * pitch, tiling, widths, 0) == 2 * pitch)
    }

    @Test("the peek reaches the snap, not just its own function")
    func snapAppliesThePeek() {
        let widths = [UInt32](repeating: width, count: 7)
        let centre = 2 * pitch + tiling / 2
        let plain = LaneSnap.offset(forCentre: centre, viewport: tiling, lanes: lanes(widths), minPeek: 0)
        let peeked = LaneSnap.offset(forCentre: centre, viewport: tiling, lanes: lanes(widths), minPeek: 28)
        #expect(plain == CGFloat(1202))
        #expect(peeked == CGFloat(1231))
    }
}

/// The config file's lane width, all the way to a lane.
@Suite("default lane width")
@MainActor
struct LaneDefaultWidthTests {
    /// The bug this covers is not arithmetic, it is wiring: `laneDefaultPt` was
    /// read, decoded, clamped and then never handed to the thing that makes
    /// lanes, which used a Rust constant holding the same number. A test that
    /// only checked `Config` would have passed throughout.
    @Test("a lane is born at the width the config asked for")
    func theConfiguredWidthReachesTheLedger() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try StripStore(
            ledgerPath: dir.appendingPathComponent("ledger.db").path, laneDefaultPt: 520)
        try store.newWebLane(url: "https://example.com", near: nil)
        #expect(store.state.lanes.first?.widthPt == UInt32(520))
    }
}

/// The counts on the rails.
///
/// "How many are off screen" is the half a sliver cannot say, and it is one
/// `<=` away from being wrong by a lane at each end.
@Suite("edge lane counts")
@MainActor
struct StripEdgeCountTests {
    private func lanes(_ widths: [UInt32]) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: 1, panes: [])
        }
    }

    private func hidden(_ offset: CGFloat, _ viewport: CGFloat, _ widths: [UInt32]) -> (left: Int, right: Int) {
        StripEdges.hidden(lanes: lanes(widths), offset: offset, viewport: viewport)
    }

    @Test("at the start of the strip nothing is off the left")
    func atTheStart() {
        let counts = hidden(0, 1300, [UInt32](repeating: 600, count: 7))
        #expect(counts.left == 0)
        // 1300 shows lane 0 whole, lane 1 whole (601…1201) and 99 pt of lane 2.
        #expect(counts.right == 4)
    }

    @Test("a lane with a sliver showing is not hidden")
    func aSliverIsNotHidden() {
        // Lane 2 starts at 1202; a viewport ending at 1212 shows 10 pt of it.
        let counts = hidden(0, 1212, [UInt32](repeating: 600, count: 4))
        #expect(counts.right == 1)
    }

    @Test("a lane that ends exactly on the edge is hidden")
    func flushIsHidden() {
        // Lane 0 spans 0…600 and the border takes it to 601. At offset 601 it is
        // gone, not "showing a 1 pt border" — which is what the hairline
        // tolerance is for.
        let counts = hidden(601, 1300, [UInt32](repeating: 600, count: 7))
        #expect(counts.left == 1)
    }

    @Test("an empty strip has nothing off either end")
    func emptyStrip() {
        let counts = hidden(0, 1300, [])
        #expect(counts.left == 0)
        #expect(counts.right == 0)
    }

    @Test("a strip narrower than the window hides nothing")
    func everythingFits() {
        let counts = hidden(0, 4000, [600, 600, 600])
        #expect(counts.left == 0)
        #expect(counts.right == 0)
    }
}
