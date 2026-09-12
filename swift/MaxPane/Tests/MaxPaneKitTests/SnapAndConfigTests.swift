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
                 pinned: false, span: 1, panes: [])
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
}
