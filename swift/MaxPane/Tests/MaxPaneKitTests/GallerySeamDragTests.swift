import AppKit
import LanedCore
import Testing
@testable import MaxPaneKit

private func pane(_ id: String, _ lane: String, _ position: UInt32) -> Pane {
    Pane(id: id, laneId: lane, position: position, kind: .pty, relaySessionId: id, relayServer: nil,
         url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
         heightWeight: 1, zoom: 1, mobile: false)
}

private func lane(_ id: String, _ paneIds: [String]) -> Lane {
    Lane(id: id, ordinal: 0, widthPt: 656, title: "claude — \(id)", projectRoot: "/Users/x/code/\(id)",
         projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false,
         dock: nil, span: 1, panes: paneIds.enumerated().map { pane($1, id, UInt32($0)) })
}

/// The seams of an expanded gallery tile.
///
/// The owner: *"I should be able to change (adjust the heights) of stacked
/// panes by dragging the separator in the same way as lanes layout mode."*
/// ADR-0011 kept every tile's seams inert because a height chosen from a
/// thumbnail is chosen blind; an expanded tile is the lane at its real size, so
/// that reason is gone and its seams are the strip's. What has to hold: an
/// unexpanded tile is exactly as handle-free as before, an expanded one drags
/// with the strip's own arithmetic, and a tile clamped below real size maps the
/// pointer through its scale so the seam stays under it.
@Suite("an expanded tile's seams")
@MainActor
struct GallerySeamDragTests {
    private let size = CGSize(width: 656, height: 1000)

    /// A two-pane lane laid out on its own, as the strip or a tile would.
    private func stacked() -> (lane: LaneView, top: NSView, bottom: NSView) {
        let laneView = LaneView(lane: lane("a", ["a1", "a2"]), widthBounds: 420...900)
        let top = NSView(), bottom = NSView()
        laneView.setPaneView(top, for: "a1", at: 0)
        laneView.setPaneView(bottom, for: "a2", at: 1)
        laneView.frame = CGRect(origin: .zero, size: size)
        laneView.layoutSubtreeIfNeeded()
        return (laneView, top, bottom)
    }

    @Test("a thumbnail hides its grips and disarms its seams; the same view expanded shows them; put back, they go")
    func handlesFollowExpansion() throws {
        let (laneView, _, _) = stacked()
        // On the strip: a stack has grips and a live seam.
        #expect(laneView.gripsAreVisible)
        #expect(laneView.seamsAreLive)
        #expect(try #require(laneView.seamDividers.first).isEnabled)

        // As an unexpanded tile: the seam is still drawn — the tile keeps the
        // lane's proportions — but it is not a handle, and the grips are gone.
        laneView.thumbnailScale = 0.4
        laneView.layoutSubtreeIfNeeded()
        #expect(!laneView.gripsAreVisible)
        #expect(!laneView.seamsAreLive)
        let divider = try #require(laneView.seamDividers.first)
        #expect(!divider.isHidden)
        #expect(!divider.isEnabled)
        #expect(divider.hitTest(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY)) == nil,
                "an inert seam must let the click through to the lane")

        // Expanded at the lane's real size: the strip's handles.
        laneView.isExpandedTile = true
        laneView.thumbnailScale = 1
        laneView.layoutSubtreeIfNeeded()
        #expect(laneView.gripsAreVisible)
        #expect(laneView.seamsAreLive)
        #expect(divider.isEnabled)

        // Expanded but clamped: still live above the threshold.
        laneView.thumbnailScale = PaneSplit.minimumLiveScale
        laneView.layoutSubtreeIfNeeded()
        #expect(laneView.seamsAreLive)
        #expect(laneView.gripsAreVisible)

        // Clamped below it: the handles would be smaller than targets, so hidden.
        laneView.thumbnailScale = PaneSplit.minimumLiveScale - 0.05
        laneView.layoutSubtreeIfNeeded()
        #expect(!laneView.seamsAreLive)
        #expect(!laneView.gripsAreVisible)

        // Put back at any scale: handle-free again.
        laneView.thumbnailScale = 1
        laneView.isExpandedTile = false
        laneView.layoutSubtreeIfNeeded()
        #expect(!laneView.gripsAreVisible)
        #expect(!laneView.seamsAreLive)
        #expect(!divider.isEnabled)
    }

    /// A tile in a gallery in a window, so a window point converts through the
    /// tile's transform exactly as a real pointer's would.
    private func tile(scale: CGFloat, expanded: Bool) -> (window: NSWindow, lane: LaneView, top: NSView, bottom: NSView) {
        let (laneView, top, bottom) = stacked()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let gallery = GalleryView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1200))
        window.contentView = gallery
        gallery.place(laneView, laneId: "a",
                      frame: CGRect(x: 100, y: 50, width: size.width * scale, height: size.height * scale),
                      laneSize: size)
        laneView.thumbnailScale = scale
        laneView.isExpandedTile = expanded
        gallery.layoutSubtreeIfNeeded()
        return (window, laneView, top, bottom)
    }

    /// Drag the first seam by `lanePoints` downward, given in lane points, with
    /// the pointer moving `lanePoints * scale` window points — which is what a
    /// pointer over a tile at `scale` does.
    private func dragSeam(of laneView: LaneView, lanePoints: CGFloat, scale: CGFloat,
                          final: Bool = false) throws {
        let divider = try #require(laneView.seamDividers.first)
        let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        divider.beginDrag(atWindowPoint: start)
        // Window y grows upward; down on screen is a smaller y.
        divider.continueDrag(toWindowPoint: NSPoint(x: start.x, y: start.y - lanePoints * scale))
        if final { divider.endDrag() }
    }

    @Test("dragged at a scale of 1, the seam produces the heights the strip's arithmetic predicts",
          arguments: [CGFloat(1), 0.7])
    func dragMatchesTheStrip(scale: CGFloat) throws {
        let (window, laneView, top, bottom) = tile(scale: scale, expanded: true)
        defer { window.close() }
        var live: [(paneId: String, weight: Double)] = []
        var finals: [[(paneId: String, weight: Double)]] = []
        laneView.onPaneHeights = { weights, isFinal in
            if isFinal { finals.append(weights) } else { live = weights }
        }

        let available = size.height - Theme.laneHeaderHeight - PaneSplit.seam
        let expected = PaneSplit.drag(weights: [1, 1], divider: 0, delta: 40, available: available)
        let heights = PaneSplit.heights(weights: expected, available: available)

        try dragSeam(of: laneView, lanePoints: 40, scale: scale)

        // The live report carries the strip's weights for the two panes either
        // side of the seam, in order.
        #expect(live.map(\.paneId) == ["a1", "a2"])
        #expect(live.count == 2)
        if live.count == 2 {
            #expect(abs(live[0].weight - expected[0]) < 1e-6)
            #expect(abs(live[1].weight - expected[1]) < 1e-6)
        }
        // And the lane has already redrawn under the pointer, at the heights
        // those weights resolve to — within the tile's pixel rounding
        // (ADR-0011, consequences).
        let tolerance = GalleryLayout.roundingTolerance(scale: scale, backingScale: window.backingScaleFactor) + 0.5
        #expect(abs(top.bounds.height - heights[0]) <= tolerance)
        #expect(abs(bottom.bounds.height - heights[1]) <= tolerance)
        #expect(top.bounds.height > bottom.bounds.height, "the pane above grows when the pointer goes down")

        // The drop: exactly one final report, the same numbers.
        try #require(laneView.seamDividers.first).endDrag()
        #expect(finals.count == 1)
        if let final = finals.first, final.count == 2 {
            #expect(abs(final[0].weight - expected[0]) < 1e-6)
            #expect(abs(final[1].weight - expected[1]) < 1e-6)
        }
    }

    @Test("an unexpanded tile's seam reports nothing, whatever the pointer does")
    func unexpandedTileIsInert() throws {
        let (window, laneView, top, bottom) = tile(scale: 1, expanded: false)
        defer { window.close() }
        var reports = 0
        laneView.onPaneHeights = { _, _ in reports += 1 }
        let before = (top.bounds.height, bottom.bounds.height)

        try dragSeam(of: laneView, lanePoints: 40, scale: 1, final: true)

        #expect(reports == 0)
        #expect(top.bounds.height == before.0)
        #expect(bottom.bounds.height == before.1)
    }

    @Test("a pointer on a live seam is a seam, not the tile; on an inert one it is not")
    func liveSeamIsRecognised() throws {
        let (window, laneView, _, _) = tile(scale: 1, expanded: true)
        defer { window.close() }
        let divider = try #require(laneView.seamDividers.first)
        let onSeam = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        #expect(laneView.isLiveSeam(atWindowPoint: onSeam))
        // Far inside the top pane, well off the grab band.
        let inPane = laneView.convert(NSPoint(x: 300, y: size.height - Theme.laneHeaderHeight - 200), to: nil)
        #expect(!laneView.isLiveSeam(atWindowPoint: inPane))

        laneView.isExpandedTile = false
        laneView.layoutSubtreeIfNeeded()
        #expect(!laneView.isLiveSeam(atWindowPoint: onSeam))
    }
}
