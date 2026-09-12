import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Where the strip has to stop for a lane to be readable.
///
/// This is the arithmetic behind the round-2 finding, and it is tested with
/// numbers rather than pixels because the bug was never in the pixels: the
/// target was computed against the *view's* width, and an arriving lane's column
/// opens from zero, so the view was up to a whole lane narrower than the strip
/// at exactly the moment the target was taken. Measured on a running instance
/// before the fix: two 654 pt lanes in a 1264 pt viewport, a third opened and
/// focused, 66 pt of scroll and 26 pt of the new lane showing.
///
/// Every case below hands `StripReveal` the lanes the ledger has *after* the
/// insert — which is the fix stated as a signature: there is no view to ask.
///
/// `LaneSnap`'s tests carry a warning that applies to every `#expect` here: a
/// literal arithmetic expression inside the macro is re-typed and compared as an
/// `Int`, so every expected number is written as an explicit `CGFloat`.
@Suite("revealing a lane")
@MainActor
struct StripRevealTests {
    private func lanes(_ widths: [UInt32]) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 pinned: false, span: 1, panes: [])
        }
    }

    /// The instance the failure was measured on: 654 pt lanes, a 1264 pt strip
    /// viewport, so two lanes already overflow it.
    private let wide: UInt32 = 654
    private let viewport: CGFloat = 1264

    // MARK: - the finding

    @Test("a third lane arriving on a two-lane strip is brought fully on screen")
    func theArrivingLaneIsFullyRevealed() {
        let strip = lanes([wide, wide, wide])
        let target = StripReveal.centred(
            on: "lane-2", lanes: strip, viewport: viewport, peek: 28)
        // Lane 2 starts at 2 × 655 = 1310 and is 654 wide, so the whole strip is
        // 1965 and the furthest right the viewport can go is 1965 - 1264 = 701.
        // Centring wants 1310 - (1264 - 654)/2 = 1005, which is past that, so
        // the strip ends flush with the end — where it must, because the
        // arriving lane is the last one.
        #expect(target == CGFloat(701))
        // And that is enough to show all of it: the lane ends at 1964, the
        // viewport at 701 + 1264 = 1965.
        #expect(target! + viewport >= CGFloat(1310 + 654))
    }

    @Test("the target does not depend on a content view that has not grown yet")
    func targetIsIndependentOfTheView() {
        // The bug, stated: with the arriving lane's column still at zero width,
        // the document view is only as wide as the two lanes that were there —
        // 1310 — and clamping to that gives 1310 - 1264 = 46 pt of scroll and a
        // lane nobody can see. The number below is what the ledger says instead.
        let stale = max(0, CGFloat(2 * 655) - viewport)
        let target = StripReveal.centred(
            on: "lane-2", lanes: lanes([wide, wide, wide]), viewport: viewport, peek: 28)!
        #expect(stale == CGFloat(46))
        #expect(target > stale)
    }

    @Test("a window that fits a whole number of lanes still moves for the new one")
    func exactTilingStillScrolls() {
        // The other half of the finding: "lanes 3 and 4 arrived with zero pixel
        // change". Two 600 pt lanes fit a 1201 pt viewport exactly, so before
        // the third arrives there is nothing to scroll and the offset is 0.
        let strip = lanes([600, 600, 600])
        let target = StripReveal.centred(on: "lane-2", lanes: strip, viewport: 1201, peek: 28)
        #expect(target != CGFloat(0))
        #expect(target == CGFloat(1803 - 1201))
    }

    // MARK: - centring

    @Test("a lane in the middle of the strip is centred")
    func middleLaneIsCentred() {
        let strip = lanes([600, 600, 600, 600, 600])
        // Lane 2 starts at 2 × 601 = 1202; centring it in 1000 pt of viewport
        // puts the scroll at 1202 - (1000 - 600)/2 = 1002. No peek asked for.
        let target = StripReveal.centred(on: "lane-2", lanes: strip, viewport: 1000, peek: 0)
        #expect(target == CGFloat(1002))
    }

    @Test("the first lane cannot be centred, so the strip sits at the start")
    func firstLaneClampsToZero() {
        let target = StripReveal.centred(
            on: "lane-0", lanes: lanes([600, 600, 600]), viewport: 1000, peek: 0)
        #expect(target == CGFloat(0))
    }

    @Test("a lane the strip does not have reveals nothing rather than scrolling to zero")
    func unknownLaneIsRefused() {
        #expect(StripReveal.centred(
            on: "nope", lanes: lanes([600, 600]), viewport: 1000, peek: 0) == nil)
        #expect(StripReveal.minimal(
            from: 0, to: "nope", lanes: lanes([600, 600]), viewport: 1000) == nil)
    }

    @Test("a viewport of zero — a window not yet on screen — has no answer")
    func noViewportNoTarget() {
        #expect(StripReveal.centred(
            on: "lane-0", lanes: lanes([600]), viewport: 0, peek: 0) == nil)
    }

    @Test("the peek applies to a reveal, as it does to a snap")
    func revealTakesThePeek() {
        // Seven 600 pt lanes in the width that tiles exactly: centring lane 3
        // would leave both edges flush while the strip continues past them.
        let widths = [UInt32](repeating: 600, count: 7)
        let tiling = CGFloat(600) + 2 * CGFloat(601)
        let centred = StripReveal.centred(on: "lane-3", lanes: lanes(widths), viewport: tiling, peek: 0)!
        let peeked = StripReveal.centred(on: "lane-3", lanes: lanes(widths), viewport: tiling, peek: 28)!
        #expect(peeked != centred)
        #expect(abs(peeked - centred) <= CGFloat(28 + Theme.borderWidth + StripEdges.hairline))
    }

    // MARK: - the least movement

    @Test("a lane already on screen does not move the strip at all")
    func visibleLaneDoesNotMove() {
        let strip = lanes([600, 600, 600])
        let target = StripReveal.minimal(from: 0, to: "lane-0", lanes: strip, viewport: 1000)
        #expect(target == CGFloat(0))
    }

    @Test("a lane off the right edge is brought just far enough on")
    func scrollsTheLeastItCan() {
        let strip = lanes([600, 600, 600])
        // Lane 1 ends at 601 + 600 = 1201; a 1000 pt viewport at 0 has to move
        // to 201 and no further — recentring here is the disorienting jump
        // arrow-key focus must not make.
        let target = StripReveal.minimal(from: 0, to: "lane-1", lanes: strip, viewport: 1000)
        #expect(target == CGFloat(201))
    }

    @Test("a lane off the left edge shows its start, not its end")
    func alignsTheLeadingEdge() {
        let strip = lanes([600, 600, 600])
        let target = StripReveal.minimal(from: 1200, to: "lane-0", lanes: strip, viewport: 1000)
        #expect(target == CGFloat(0))
    }

    @Test("a lane wider than the window shows its top-left, where its header is")
    func aLaneWiderThanTheWindow() {
        let strip = lanes([1400, 600])
        // The header, the address bar and the top of the page are all at the
        // lane's leading edge, so that is the half to show.
        let target = StripReveal.minimal(from: 300, to: "lane-0", lanes: strip, viewport: 1000)
        #expect(target == CGFloat(0))
    }

    @Test("neither reveal ever asks for a scroll past the end of the strip")
    func neverPastTheEnd() {
        let widths: [UInt32] = [600, 700, 500, 900]
        let strip = lanes(widths)
        let limit = StripEdges.contentWidth(of: strip) - 1000
        for id in strip.map(\.id) {
            let centred = StripReveal.centred(on: id, lanes: strip, viewport: 1000, peek: 28)!
            let minimal = StripReveal.minimal(from: 0, to: id, lanes: strip, viewport: 1000)!
            #expect(centred >= CGFloat(0) && centred <= limit)
            #expect(minimal >= CGFloat(0) && minimal <= limit)
        }
    }

    // MARK: - the reason the scroll rides the insert's timer

    /// The claim the carried scroll rests on: while a lane's column opens, the
    /// content view grows at the same eased rate the scroll does, and the scroll
    /// stays inside the growing clamp at every step. If that were not true the
    /// clip view would clip the motion short and the whole exercise would be
    /// back where it started.
    @Test("an eased scroll is never clamped by the column still opening under it")
    func theCarriedScrollIsNeverClamped() {
        let before = lanes([wide, wide])
        let after = lanes([wide, wide, wide])
        let start = StripEdges.contentWidth(of: before) - viewport   // the strip, at rest
        let target = StripReveal.centred(on: "lane-2", lanes: after, viewport: viewport, peek: 28)!
        let opening = CGFloat(wide)

        for frame in 0...13 {
            let eased = Motion.easeOut(CGFloat(frame) / 13)
            // What the strip asks for, against what the document view can give
            // it. `StripContentView.layOut` sizes itself to every lane's *slot*
            // plus its border, so mid-entrance it is the finished strip less
            // the part of the opening column that has not opened yet — the
            // border is already there from the first frame, which is the one
            // point of slack that keeps the first frame from being clamped.
            let wanted = start + (target - start) * eased
            let available =
                StripEdges.contentWidth(of: after) - opening * (1 - eased) - viewport
            #expect(wanted <= available + 0.0001)
        }
    }
}
