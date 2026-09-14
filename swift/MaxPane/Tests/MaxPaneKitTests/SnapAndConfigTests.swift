import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Where a scroll comes to rest.
///
/// All of this is clamping, and clamping is where an off-by-a-lane hides: the
/// first and last lanes cannot be centred, and a snap that pretends otherwise
/// scrolls past the end of the strip and shows a band of nothing.
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
        #expect(left == CGFloat(0))       // lane 0, clamped to the start
        #expect(right == CGFloat(401))    // lane 1, centred
    }

    @Test("the first lane cannot be centred, so it sits at the start")
    func firstLaneClampsToZero() {
        #expect(snap(centre: 100, viewport: 1000, widths: [600, 600, 600]) == CGFloat(0))
    }

    @Test("the last lane cannot be centred, so it sits at the end")
    func lastLaneClampsToTheEnd() {
        let widths: [UInt32] = [600, 600, 600]
        // Total = 600*3 + 1*3 borders = 1803, so the furthest left edge that
        // still fills the viewport is 803.
        let offset = snap(centre: 1750, viewport: 1000, widths: widths)
        #expect(offset == CGFloat(803))
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
            for (index, id) in strip.map(\.id).enumerated() {
                let target = StripReveal.focused(from: 0, to: id, lanes: strip, viewport: viewport)!
                // Between the ends the plain snap agrees on its own. At a
                // clamped end the middle of the screen can be nearer the
                // neighbour, which is what `settle` is for.
                if index > 0, index < strip.count - 1 {
                    #expect(LaneSnap.offset(
                        forCentre: target + viewport / 2, viewport: viewport, lanes: strip, minPeek: 28)
                        == target)
                }
                #expect(LaneSnap.settle(
                    from: target, viewport: viewport, lanes: strip, minPeek: 28, focused: id)
                    == target)
            }
        }
    }

    @Test("at a clamped end with mixed widths, the snap holds the focused lane")
    func settleHoldsTheFocusedEndLane() {
        // Focus lane 0: the strip sits at 0. The middle of a 1200 pt screen is
        // nearer the 300 pt lane 1, which on its own would snap to 151.
        let strip = lanes([600, 300, 600, 300, 600])
        #expect(StripReveal.focused(from: 400, to: "lane-0", lanes: strip, viewport: 1200) == CGFloat(0))
        #expect(LaneSnap.offset(forCentre: 600, viewport: 1200, lanes: strip, minPeek: 28) == CGFloat(151))
        #expect(LaneSnap.settle(from: 0, viewport: 1200, lanes: strip, minPeek: 28, focused: "lane-0")
            == CGFloat(0))
        // A drag away from it is settled as any other scroll.
        #expect(LaneSnap.settle(from: 140, viewport: 1200, lanes: strip, minPeek: 28, focused: "lane-0")
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
