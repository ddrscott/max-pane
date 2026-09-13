import Testing
import AppKit
@testable import MaxPaneKit

/// Where the focused pane's outline goes.
///
/// Focus used to be the lane's border, which in a split lane said "one of these
/// three" and left the owner to guess which — with a screenshot of a lane
/// outlined in orange around a pane that did not have the keyboard. The outline
/// is now drawn around the pane, and its frame is arithmetic on the same
/// heights the seams are placed from, so it is tested as arithmetic: a rect a
/// point off is "the border looks slightly wrong" on screen and a wrong number
/// here.
@Suite("the focused pane's outline")
@MainActor
struct PaneFocusOutlineTests {
    private let lane = NSSize(width: 656, height: 900)
    private var paneArea: CGFloat { lane.height - Theme.laneHeaderHeight }
    private let edge = Theme.borderWidth

    @Test("one pane: everything below the header, just inside the lane's own border")
    func singlePane() {
        let rect = PaneSplit.focusOutline(ofPaneAt: 0, heights: [paneArea], laneSize: lane)
        // Inside the neutral 1 pt border, not on it: a layer's border is drawn
        // over its sublayers, so an outline flush with the lane edge would lose
        // its outer point to grey on three sides.
        #expect(rect == NSRect(x: edge, y: edge, width: lane.width - 2 * edge, height: paneArea - edge))
    }

    @Test("the header is never inside it")
    func headerIsOutside() {
        let rect = PaneSplit.focusOutline(ofPaneAt: 0, heights: [paneArea], laneSize: lane)
        #expect(rect.map { $0.maxY } == paneArea)
    }

    @Test("the upper of two panes stops at the seam")
    func upperPane() {
        let rect = PaneSplit.focusOutline(ofPaneAt: 0, heights: [400, 400], laneSize: lane)
        #expect(rect == NSRect(x: edge, y: paneArea - 400, width: lane.width - 2 * edge, height: 400))
    }

    @Test("the lower of two panes starts below the seam, at the height the seam sits at")
    func lowerPane() {
        let heights: [CGFloat] = [400, 400]
        let rect = PaneSplit.focusOutline(ofPaneAt: 1, heights: heights, laneSize: lane)
        let top = paneArea - PaneSplit.top(ofPaneAt: 1, heights: heights)
        #expect(rect?.maxY == top)
        #expect(rect?.minY == max(edge, top - 400))
    }

    @Test("a pane the lane does not have gets no outline", arguments: [-1, 2, 9])
    func outOfRange(index: Int) {
        #expect(PaneSplit.focusOutline(ofPaneAt: index, heights: [400, 400], laneSize: lane) == nil)
    }
}
