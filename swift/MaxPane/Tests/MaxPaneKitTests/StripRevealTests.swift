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
                 keepLive: false, dock: nil, span: 1, panes: [])
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

    // MARK: - the carousel: fewer than three lanes fit

    @Test("one lane fits: focus centres it, with equal slivers either side")
    func carouselOneLaneFits() {
        let strip = lanes([600, 600, 600, 600, 600])
        // Lane 2 starts at 1202; centred in 1000 pt the strip sits at 1002,
        // where `minimal` from 0 would have stopped at 802 with lane 2 flush
        // right and nothing of lane 3 to click on.
        let target = StripReveal.focused(from: 0, to: "lane-2", lanes: strip, viewport: 1000)
        #expect(target == CGFloat(1002))
        #expect(StripReveal.minimal(from: 0, to: "lane-2", lanes: strip, viewport: 1000) == CGFloat(802))
        // Lane 1 ends at 1201 and lane 3 starts at 1803: 199 pt of each.
        #expect(CGFloat(1201) - target! == CGFloat(199))
        #expect(target! + 1000 - CGFloat(1803) == CGFloat(199))
    }

    @Test("two lanes fit: still exactly centred, the neighbours half showing")
    func carouselTwoLanesFit() {
        let strip = lanes([600, 600, 600, 600, 600])
        let target = StripReveal.focused(from: 0, to: "lane-2", lanes: strip, viewport: 1500)
        #expect(target == CGFloat(752))
        #expect(CGFloat(1201) - target! == CGFloat(449))
        #expect(target! + 1500 - CGFloat(1803) == CGFloat(449))
        // ⌘P, the sidebar and an arriving lane land on the same place.
        #expect(StripReveal.centred(on: "lane-2", lanes: strip, viewport: 1500, peek: 28) == target)
    }

    @Test("three lanes fit: focus is the least movement, exactly as before")
    func threeLanesFitIsUnchanged() {
        let strip = lanes([UInt32](repeating: 600, count: 7))
        let tiling = CGFloat(600) + 2 * CGFloat(601)
        for viewport in [tiling, CGFloat(2000), CGFloat(2600)] {
            for offset in [CGFloat(0), CGFloat(300), CGFloat(1202)] {
                for id in strip.map(\.id) {
                    #expect(StripReveal.carousel(on: id, lanes: strip, viewport: viewport) == nil)
                    #expect(StripReveal.focused(from: offset, to: id, lanes: strip, viewport: viewport)
                        == StripReveal.minimal(from: offset, to: id, lanes: strip, viewport: viewport))
                }
            }
        }
    }

    @Test("mixed widths: the lanes around the focused one decide, not a count")
    func carouselMixedWidths() {
        // An xl lane between s lanes. Lanes 1…3 span 421…2463, 2042 pt, which
        // is more than 1800: a carousel around lane 2.
        let mixed = lanes([420, 420, 1200, 420, 420])
        #expect(StripReveal.focused(from: 0, to: "lane-2", lanes: mixed, viewport: 1800)
            == CGFloat(842 - 300))
        // The same window over five s lanes fits three of them: no carousel.
        let small = lanes([420, 420, 420, 420, 420])
        #expect(StripReveal.carousel(on: "lane-2", lanes: small, viewport: 1800) == nil)
    }

    @Test("a carousel is centred exactly even where the peek would have nudged it")
    func carouselIgnoresThePeek() {
        // Lane 2 (600 pt at 902) centred in 1200 pt puts the left edge 1 pt
        // into lane 1 and the right edge 1 pt short of lane 3's end: both
        // flush within the hairline, the case `LanePeek` exists for. Lanes 1…3
        // span 601…1803, 1202 pt, two more than fits.
        let strip = lanes([600, 300, 600, 300, 600])
        #expect(LanePeek.adjust(offset: 602, viewport: 1200, lanes: strip, minimum: 28) != CGFloat(602))
        #expect(StripReveal.centred(on: "lane-2", lanes: strip, viewport: 1200, peek: 28) == CGFloat(602))
        #expect(StripReveal.focused(from: 0, to: "lane-2", lanes: strip, viewport: 1200) == CGFloat(602))
    }

    @Test("the first and last lanes clamp to the ends of the strip")
    func carouselClampsAtTheEnds() {
        let strip = lanes([600, 600, 600, 600, 600])
        let limit = StripEdges.contentWidth(of: strip) - 1000
        #expect(StripReveal.focused(from: 1500, to: "lane-0", lanes: strip, viewport: 1000) == CGFloat(0))
        #expect(StripReveal.focused(from: 0, to: "lane-4", lanes: strip, viewport: 1000) == limit)
        #expect(limit == CGFloat(2005))
    }

    @Test("a dock taking room from the strip can turn it into a carousel")
    func aDockNarrowsTheStripIntoACarousel() {
        let strip = lanes([600, 600, 600, 600, 600])
        // 2000 pt fits three 600 pt lanes.
        #expect(StripReveal.carousel(on: "lane-2", lanes: strip, viewport: 2000) == nil)
        // A 320 pt inset dock: the clip view is made 320 narrower.
        let inset = DockGeometry.visible(
            clipOffset: 0, clipWidth: 1680,
            layout: DockGeometry.Layout(left: .init(width: 320, mode: .inset), right: nil))
        // A 320 pt overlay dock: the clip keeps its width and loses the view.
        let overlay = DockGeometry.visible(
            clipOffset: 0, clipWidth: 2000,
            layout: DockGeometry.Layout(left: .init(width: 320, mode: .overlay), right: nil))
        for window in [inset, overlay] {
            #expect(window.width == CGFloat(1680))
            #expect(StripReveal.carousel(on: "lane-2", lanes: strip, viewport: window.width)
                == CGFloat(1202 - 540))
        }
    }

    @Test("a lane wider than the window keeps its leading edge, carousel or not")
    func aLaneWiderThanTheWindowIsNotACarousel() {
        let strip = lanes([1400, 600])
        #expect(StripReveal.carousel(on: "lane-0", lanes: strip, viewport: 1000) == nil)
        #expect(StripReveal.focused(from: 300, to: "lane-0", lanes: strip, viewport: 1000) == CGFloat(0))
    }

    @Test("a lane already centred asks for no movement")
    func carouselAlreadyCentred() {
        let strip = lanes([600, 600, 600, 600, 600])
        #expect(StripReveal.focused(from: 1002, to: "lane-2", lanes: strip, viewport: 1000) == CGFloat(1002))
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
