import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Where a scroll comes to rest.
///
/// All of this is clamping, and clamping is where an off-by-a-lane hides. In a
/// carousel the first and last lanes centre like any other, and the band of
/// empty strip past them is the point — it is what says the strip ends there.
/// Everywhere else they cannot be centred, and a snap that pretends otherwise
/// scrolls past the end of the strip for nothing.
@Suite("scroll snapping")
@MainActor
struct SnapTests {
    /// Lanes of a given width, in order.
    private func lanes(_ widths: [UInt32]) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: 1, panes: [])
        }
    }

    private func snap(centre: CGFloat, viewport: CGFloat, widths: [UInt32]) -> CGFloat? {
        LaneSnap.offset(forCentre: centre, viewport: viewport, lanes: lanes(widths))
    }

    @Test("the nearest lane ends up centred")
    func centresTheNearestLane() {
        // Three 600pt lanes (601 apart with the border) in a 1000pt viewport.
        // Lane 1 spans 601…1201, its centre is 901.
        let offset = snap(centre: 900, viewport: 1000, widths: [600, 600, 600])
        // Lane 1 starts at 601, so centring it in 1000pt puts the scroll at
        // 601 - (1000 - 600)/2. Spelled out: a literal expression here gets
        // re-typed inside the expectation macro and compares as an Int.
        #expect(offset == CGFloat(401))
    }

    @Test("a scroll that stops between two lanes picks the closer one")
    func picksTheCloserNeighbour() {
        let widths: [UInt32] = [600, 600, 600]
        // Just left of the boundary between lane 0 and lane 1.
        let left = snap(centre: 580, viewport: 1000, widths: widths)
        let right = snap(centre: 800, viewport: 1000, widths: widths)
        #expect(left != right)
        #expect(left == CGFloat(-200))    // lane 0, centred into the margin
        #expect(right == CGFloat(401))    // lane 1, centred
    }

    @Test("in a carousel the first lane centres, with empty strip before it")
    func firstLaneCentresIntoTheMargin() {
        // Three 600 pt lanes in 1000 pt is a carousel: lane 0 centred is -200.
        #expect(snap(centre: 100, viewport: 1000, widths: [600, 600, 600]) == CGFloat(-200))
    }

    @Test("in a carousel the last lane centres, with empty strip after it")
    func lastLaneCentresIntoTheMargin() {
        let widths: [UInt32] = [600, 600, 600]
        // Total = 600*3 + 1*3 borders = 1803, so the furthest left edge that
        // still fills the viewport is 803 — and lane 2 centred, at 1202 - 200,
        // is 199 pt past it, inside the 200 pt margin.
        let offset = snap(centre: 1750, viewport: 1000, widths: widths)
        #expect(offset == CGFloat(1002))
    }

    @Test("outside a carousel the ends are the ends")
    func endsClampWhenThreeFit() {
        // Seven 600 pt lanes with room for three: no margin, so the first sits
        // at 0 and the last flush with the end, peek and all.
        let widths = [UInt32](repeating: 600, count: 7)
        #expect(snap(centre: 100, viewport: 2000, widths: widths) == CGFloat(0))
        let total = CGFloat(601 * 7)
        #expect(snap(centre: total - 100, viewport: 2000, widths: widths) == total - 2000)
    }

    @Test("lanes of different widths still centre on themselves")
    func mixedWidths() {
        // 420, then a 900 spanning 421…1321 with centre 871.
        let offset = snap(centre: 871, viewport: 1000, widths: [420, 900, 420])
        #expect(offset == CGFloat(371))
    }

    @Test("an empty strip has nothing to snap to")
    func emptyStrip() {
        #expect(snap(centre: 0, viewport: 1000, widths: []) == nil)
    }

    @Test("a single lane narrower than the viewport stays at the start")
    func oneShortLane() {
        #expect(snap(centre: 300, viewport: 1000, widths: [600]) == CGFloat(0))
    }

    // MARK: - the carousel

    @Test("under the carousel a snap centres exactly, with the peek configured")
    func carouselSnapIgnoresThePeek() {
        // Lane 2 centred in 1200 pt leaves both edges flush; lanes 1…3 do not
        // fit, so the snap takes the carousel's exact centre, not a nudge.
        let strip = lanes([600, 300, 600, 300, 600])
        // Lane 2 spans 902…1502, its centre is 1202.
        #expect(LaneSnap.offset(forCentre: 1202, viewport: 1200, lanes: strip, minPeek: 28)
            == CGFloat(602))
    }

    @Test("when three lanes fit, the snap still takes the peek")
    func threeFitSnapStillPeeks() {
        let strip = lanes([UInt32](repeating: 600, count: 7))
        let tiling = CGFloat(1802)
        #expect(LaneSnap.offset(forCentre: 1202 + tiling / 2, viewport: tiling, lanes: strip, minPeek: 28)
            == CGFloat(1231))
    }

    @Test("a snap after a centring focus settles where the focus put the strip")
    func snapAgreesWithTheCarousel() {
        let strip = lanes([UInt32](repeating: 600, count: 7))
        for viewport in [CGFloat(1000), CGFloat(1500)] {
            for id in strip.map(\.id) {
                let target = StripReveal.focused(from: 0, to: id, lanes: strip, viewport: viewport)!
                // The ends included: centred into the margin, the focused lane
                // is the one under the middle of the screen.
                #expect(LaneSnap.offset(
                    forCentre: target + viewport / 2, viewport: viewport, lanes: strip, minPeek: 28)
                    == target)
                #expect(LaneSnap.settle(
                    from: target, viewport: viewport, lanes: strip, minPeek: 28, focused: id)
                    == target)
            }
        }
    }

    @Test("at an end with mixed widths, the snap holds the focused lane")
    func settleHoldsTheFocusedEndLane() {
        // Focus lane 0: centred at -300, 300 pt of margin before it. A strip
        // that has been left at 0 instead has the 300 pt lane 1 nearer the
        // middle of the screen, which snaps to 151.
        let strip = lanes([600, 300, 600, 300, 600])
        #expect(StripReveal.focused(from: 400, to: "lane-0", lanes: strip, viewport: 1200) == CGFloat(-300))
        #expect(LaneSnap.offset(forCentre: 600, viewport: 1200, lanes: strip, minPeek: 28) == CGFloat(151))
        #expect(LaneSnap.settle(from: -300, viewport: 1200, lanes: strip, minPeek: 28, focused: "lane-0")
            == CGFloat(-300))
        // A drag away from it is settled as any other scroll.
        #expect(LaneSnap.settle(from: 0, viewport: 1200, lanes: strip, minPeek: 28, focused: "lane-0")
            == CGFloat(151))
    }

    @Test("a drag under the carousel settles on the nearest lane, centred")
    func carouselDragPagesToTheNearestLane() {
        let strip = lanes([600, 600, 600, 600, 600])
        // Lane 2 centred is 1002, lane 3 centred is 1603. A drag that stops
        // short of halfway goes back; past it, on.
        #expect(LaneSnap.settle(from: 1252, viewport: 1000, lanes: strip, minPeek: 28, focused: "lane-2")
            == CGFloat(1002))
        #expect(LaneSnap.settle(from: 1352, viewport: 1000, lanes: strip, minPeek: 28, focused: "lane-2")
            == CGFloat(1603))
    }
}
