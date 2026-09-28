import AppKit
import Testing
@testable import MaxPaneKit

/// A click on a docked lane goes to the dock, never to the strip lane that has
/// scrolled under it.
///
/// The bug this pins: `pane(at:)` walked every lane view in dictionary order,
/// and an overlay dock is drawn *over* a strip lane, so a point on the dock was
/// inside both. Half the time the strip lane won, and since that lane was half
/// hidden behind the dock, the click was a "click that moves the strip": it
/// focused the lane underneath, slid the strip to it and swallowed the press.
/// `FocusClickTests` asked `clickOnlyFocuses` about the dock's pane directly,
/// which is why it never saw the hit test get the pane wrong.
///
/// The click tests go through `handleClick`, the click monitor's own body, at a
/// window point where a strip lane really is under the dock. **On their own they
/// are a coin toss against the old code**: Swift seeds dictionary hashing per
/// process and the lane ids are fresh ULIDs, so one run resolves every click
/// the same way, right or wrong. The hit-order test is the deterministic guard;
/// the click tests say what the order is for. The strip's position is
/// read off the clip view, which is what `scroll_x` mirrors: the ledger write
/// is debounced and `store.state` does not refresh for it, so reading
/// `state.scrollX` here would compare two stale numbers.
@MainActor
@Suite("a click on a dock goes to the dock", .serialized)
struct DockClickTests {
    private func atRest(_ rig: MaximizeRig, _ laneId: String) async -> Bool {
        for _ in 0..<60 {
            await rig.settle()
            if !rig.strip.revealWouldMove(laneId: laneId) { return true }
        }
        return false
    }

    /// The right lane docked as an overlay on the left wall, with the split
    /// lane focused and centred: the left lane peeks out from under the dock.
    private func dockOverTheStrip(_ rig: MaximizeRig) async throws {
        try rig.store.dockLane(rig.rightLane, side: .left, mode: .overlay, widthPt: 400)
        await rig.settle()
        try rig.store.focusPane(rig.splitTop)
        #expect(await atRest(rig, rig.splitLane))
    }

    /// Points on the dock's pane that a strip lane is also under — the only
    /// points where the hit order can be wrong.
    private func contestedPoints(_ rig: MaximizeRig) throws -> [NSPoint] {
        let dockPane = rig.stub(rig.right).view
        let dockRect = dockPane.convert(dockPane.bounds, to: nil)
        var points: [NSPoint] = []
        for fraction in stride(from: 0.1, through: 0.9, by: 0.2) {
            let point = NSPoint(x: dockRect.minX + dockRect.width * fraction, y: dockRect.midY)
            let underneath = [rig.leftLane, rig.splitLane].contains { laneId in
                guard let laneView = rig.strip.laneView(for: laneId) else { return false }
                return laneView.bounds.contains(laneView.convert(point, from: nil))
            }
            if underneath { points.append(point) }
        }
        return points
    }

    @Test("the docks are tested first, then the expanded tile, then the rest")
    func hitOrderPutsTheDocksOnTop() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .left, mode: .overlay, widthPt: 400)
            await rig.settle()
            #expect(rig.strip.hitOrder().first?.laneId == rig.rightLane)

            try rig.store.dockLane(rig.leftLane, side: .right, mode: .overlay, widthPt: 400)
            await rig.settle()
            #expect(rig.strip.hitOrder().prefix(2).map(\.laneId) == [rig.rightLane, rig.leftLane])
            // Each lane once: a dock is not also tested as a strip lane.
            #expect(rig.strip.hitOrder().filter { $0.laneId == rig.leftLane }.count == 1)

            // The expanded tile comes after the walls and before everything else.
            try rig.store.undockLane(rig.leftLane)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.expandTile(laneId: rig.splitLane, paneId: rig.splitTop)
            await rig.settle()
            #expect(rig.strip.hitOrder().prefix(2).map(\.laneId) == [rig.rightLane, rig.splitLane])
        }
    }

    @Test("at rest: the dock's pane is focused, the press goes through, the strip does not move")
    func atRestTheDockWins() async throws {
        try await MaximizeRig.with { rig in
            try await dockOverTheStrip(rig)
            let points = try contestedPoints(rig)
            // Without a strip lane under the dock this test proves nothing.
            try #require(!points.isEmpty)
            // The left lane is the one under it, and it is half hidden, so a
            // click resolved to it would move the strip.
            #expect(rig.strip.revealWouldMove(laneId: rig.leftLane))

            let origin = rig.scrollOrigin
            // Several points and several tries: the old bug was a coin toss.
            for point in points {
                for _ in 0..<4 {
                    try rig.store.focusPane(rig.splitTop)
                    let down = try rig.click(atWindowPoint: point)
                    #expect(rig.strip.handleClick(down) != nil, "a dock is a click that moves nothing")
                    #expect(rig.store.state.focusedPaneId == rig.right)
                    let up = try rig.click(atWindowPoint: point, type: .leftMouseUp)
                    #expect(rig.strip.handleClick(up) != nil, "nor is its release swallowed")
                    #expect(rig.scrollOrigin == origin)
                }
            }
            await rig.settle()
            #expect(rig.scrollOrigin == origin)
            #expect(rig.store.state.focusedPaneId == rig.right)
        }
    }

    @Test("mid-animation: the dock wins the same way, and the slide already under way lands where it would have")
    func midAnimationTheDockWins() async throws {
        try await MaximizeRig.with { rig in
            try await dockOverTheStrip(rig)
            // Where a slide to the left lane ends when nothing interrupts it.
            try rig.store.focusPane(rig.left)
            #expect(await atRest(rig, rig.leftLane))
            let target = rig.scrollOrigin

            for attempt in 0..<4 {
                // Back to the split lane, where the left lane is under the dock,
                // then start the slide to the left lane. Nothing runs the loop
                // before the click, so the slide is in flight when it lands and
                // the strip lane is still under the dock.
                try rig.store.focusPane(rig.splitTop)
                #expect(await atRest(rig, rig.splitLane))
                try rig.store.focusPane(rig.left)
                #expect(rig.scrollOrigin != target, "the strip is still on its way")
                let points = try contestedPoints(rig)
                try #require(!points.isEmpty)
                let point = points[attempt % points.count]

                let down = try rig.click(atWindowPoint: point)
                #expect(rig.strip.handleClick(down) != nil)
                #expect(rig.store.state.focusedPaneId == rig.right)
                let up = try rig.click(atWindowPoint: point, type: .leftMouseUp)
                #expect(rig.strip.handleClick(up) != nil)

                // The strip finishes the slide it was on, to the same place.
                #expect(await atRest(rig, rig.leftLane))
                #expect(rig.scrollOrigin == target)
                #expect(rig.store.state.focusedPaneId == rig.right)
            }
        }
    }

    @Test("a strip lane beside the dock keeps today's rule: a click that moves the strip only focuses")
    func theStripKeepsItsRule() async throws {
        try await MaximizeRig.with { rig in
            try await dockOverTheStrip(rig)
            // The left lane, where it is *not* under the dock.
            let laneView = try #require(rig.strip.laneView(for: rig.leftLane))
            let dockPane = rig.stub(rig.right).view
            let dockRight = dockPane.convert(dockPane.bounds, to: nil).maxX
            let laneRect = laneView.convert(laneView.bounds, to: nil)
            try #require(laneRect.maxX > dockRight + 20)
            let point = NSPoint(x: (dockRight + laneRect.maxX) / 2, y: laneRect.midY)

            let down = try rig.click(atWindowPoint: point)
            #expect(rig.strip.handleClick(down) == nil, "a click that moves the strip only focuses")
            #expect(rig.store.state.focusedPaneId == rig.left)
            let up = try rig.click(atWindowPoint: point, type: .leftMouseUp)
            #expect(rig.strip.handleClick(up) == nil)
        }
    }
}
