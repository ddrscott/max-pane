import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Dropping a pane, or a whole lane, somewhere on the strip or the gallery.
///
/// **The drag itself is AppKit's and cannot be exercised here** — there is no
/// synthetic mouse in this suite — so everything that can be *wrong* rather
/// than merely ugly is in `PaneDrag` and is what this file is about: which pane
/// the pointer is over, which edge of it, what index the ledger takes for that,
/// and whether the drop would do anything at all.
///
/// The case that has to be right is the one `SidebarModelTests` documents for
/// the bookmark bar, because it is the same one-off: **the index a move takes
/// counts siblings without the moved row, while the gaps the pointer is picking
/// between count a list that still has it.** `reorderingDownwardsCountsWithout`
/// is that, for panes.
@Suite("dropping a pane")
@MainActor
struct PaneDragTests {
    /// A window's worth of lane. Tall enough that nothing is against
    /// `PaneSplit.minPaneHeight`, so the shares are the only thing deciding.
    private let laneHeight: CGFloat = 900
    private let width: UInt32 = 656

    private func pane(_ id: String, _ lane: String, _ position: UInt32, weight: Double = 1) -> Pane {
        Pane(id: id, laneId: lane, position: position, kind: .pty, relaySessionId: id,
             url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
             heightWeight: weight, zoom: 1)
    }

    private func lane(_ id: String, _ paneIds: [String], widthPt: UInt32? = nil) -> Lane {
        Lane(id: id, ordinal: 0, widthPt: widthPt ?? width, title: id, projectRoot: nil,
             projectSource: .inherited, createdAt: 0, lastFocusAt: 0, keepLive: false,
             dock: nil, span: 1,
             panes: paneIds.enumerated().map { pane($1, id, UInt32($0)) })
    }

    private func boxes(_ lanes: [Lane]) -> [PaneDrag.LaneBox] {
        PaneDrag.boxes(lanes: lanes, laneHeight: laneHeight)
    }

    /// A point at `(u, v)` of pane `index`'s slot in `box` — 0 the left or top
    /// edge, 1 the right or bottom.
    private func at(_ box: PaneDrag.LaneBox, pane index: Int, u: CGFloat = 0.5, v: CGFloat) -> CGPoint {
        let slot = box.panes[index]
        return CGPoint(x: box.minX + box.width * u, y: slot.top + slot.height * v)
    }

    private func target(
        _ point: CGPoint, _ all: [PaneDrag.LaneBox], _ source: PaneDrag.Source
    ) -> PaneDrag.Target? {
        PaneDrag.drop(at: point, in: all, dragging: source)?.target
    }

    // MARK: - the geometry

    @Test("lanes are laid out by summing widths and a border, exactly as the strip does")
    func lanesSumTheSameWayTheStripDoes() {
        let got = boxes([lane("a", ["1"]), lane("b", ["2"]), lane("c", ["3"])])
        #expect(got[0].minX == 0)
        #expect(got[1].minX == CGFloat(width) + Theme.borderWidth)
        #expect(got[2].minX == 2 * (CGFloat(width) + Theme.borderWidth))
    }

    @Test("a pane's slot starts below the header and the slots tile the lane")
    func slotsTileTheLane() {
        let got = boxes([lane("a", ["1", "2", "3"])])[0]
        #expect(got.panes[0].top == Theme.laneHeaderHeight)
        for (upper, lower) in zip(got.panes, got.panes.dropFirst()) {
            // Exactly one seam between two slots, which is what makes the
            // boundary the pointer aims at the boundary the eye sees.
            #expect(abs((upper.top + upper.height + PaneSplit.seam) - lower.top) < 0.001)
        }
        let last = got.panes[2]
        #expect(abs((last.top + last.height) - laneHeight) < 0.001)
    }

    @Test("a gallery tile's slots are the lane's own, scaled into the tile")
    func aTileIsTheLaneScaled() {
        let real = CGSize(width: CGFloat(width), height: laneHeight)
        let tile = NSRect(x: 100, y: 50, width: real.width / 2, height: real.height / 2)
        let strip = boxes([lane("a", ["1", "2"])])[0]
        let got = PaneDrag.box(for: lane("a", ["1", "2"]), laneSize: real, drawnIn: tile)
        #expect(got.frame == tile)
        for (small, big) in zip(got.panes, strip.panes) {
            #expect(abs(small.top - (tile.minY + big.top / 2)) < 0.001)
            #expect(abs(small.height - big.height / 2) < 0.001)
        }
    }

    // MARK: - which edge

    @Test("the edge is the nearest one in the pane's own proportions, and the centre stacks")
    func theNearestEdgeWins() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 400)
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 50, y: 20), in: rect) == .top)
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 50, y: 390), in: rect) == .bottom)
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 10, y: 200), in: rect) == .left)
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 90, y: 200), in: rect) == .right)
        // 20 pt from the left of a 100 pt pane is a fifth of the way; 60 pt
        // from the top of a 400 pt one is less than a sixth. Proportions, not
        // points — so the top wins, where fixed bands would have said left.
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 20, y: 60), in: rect) == .top)
        #expect(PaneDrag.nearestEdge(to: CGPoint(x: 50, y: 200), in: rect) == .top)
    }

    @Test("the top of a pane in another lane stacks above it, the bottom below it")
    func topAndBottomStack() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y", "z"])])
        for index in 0..<3 {
            #expect(target(at(all[1], pane: index, v: 0.1), all, .pane("1"))
                    == .into(laneId: "b", index: index))
            #expect(target(at(all[1], pane: index, v: 0.9), all, .pane("1"))
                    == .into(laneId: "b", index: index + 1))
        }
    }

    @Test("the left and right of a pane open a column beside its lane")
    func leftAndRightOpenAColumn() {
        let all = boxes([lane("a", ["1", "9"]), lane("b", ["x", "y"]), lane("c", ["3"])])
        for index in 0..<2 {
            #expect(target(at(all[1], pane: index, u: 0.05, v: 0.5), all, .pane("1"))
                    == .newLane(before: "b"))
            #expect(target(at(all[1], pane: index, u: 0.95, v: 0.5), all, .pane("1"))
                    == .newLane(before: "c"))
        }
        #expect(target(at(all[2], pane: 0, u: 0.95, v: 0.5), all, .pane("1")) == .newLane(before: nil))
    }

    @Test("the header is the top of the stack, and a seam belongs to the pane below it")
    func theHeaderAndTheSeams() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        let header = CGPoint(x: all[1].minX + all[1].width / 2, y: Theme.laneHeaderHeight / 2)
        #expect(target(header, all, .pane("1")) == .into(laneId: "b", index: 0))

        let seam = CGPoint(x: header.x, y: all[1].panes[1].top - PaneSplit.seam / 2)
        #expect(target(seam, all, .pane("1")) == .into(laneId: "b", index: 1))
    }

    @Test("the one-point border between two lanes belongs to the lane before it")
    func theBorderIsNotAHole() {
        let all = boxes([lane("a", ["1"]), lane("b", ["2", "3"])])
        let border = CGPoint(x: all[0].maxX + Theme.borderWidth / 2, y: laneHeight / 2)
        #expect(target(border, all, .pane("3")) == .newLane(before: "b"))
    }

    @Test("on the strip, past either end is that end; in the gallery, between tiles is nowhere")
    func theEnds() {
        let all = boxes([lane("a", ["1", "9"]), lane("b", ["2"])])
        #expect(target(CGPoint(x: all[1].maxX + 200, y: 10), all, .pane("1")) == .newLane(before: nil))
        #expect(target(CGPoint(x: -40, y: 10), all, .pane("2")) == .newLane(before: "a"))

        let size = CGSize(width: CGFloat(width), height: laneHeight)
        let tiles = [
            PaneDrag.box(for: lane("a", ["1"]), laneSize: size,
                         drawnIn: NSRect(x: 10, y: 10, width: 164, height: 225)),
            PaneDrag.box(for: lane("b", ["2"]), laneSize: size,
                         drawnIn: NSRect(x: 184, y: 10, width: 164, height: 225)),
        ]
        #expect(PaneDrag.drop(at: CGPoint(x: 179, y: 100), in: tiles, dragging: .pane("1"), openEnds: false) == nil)
        #expect(PaneDrag.drop(at: CGPoint(x: 500, y: 100), in: tiles, dragging: .pane("1"), openEnds: false) == nil)
        #expect(PaneDrag.drop(at: CGPoint(x: 266, y: 40), in: tiles, dragging: .pane("1"), openEnds: false)?
            .target == .into(laneId: "b", index: 0))
    }

    @Test("an expanded tile drawn over its neighbours takes the point")
    func theTopmostTileWins() {
        let size = CGSize(width: CGFloat(width), height: laneHeight)
        let tiles = [
            PaneDrag.box(for: lane("under", ["u"]), laneSize: size,
                         drawnIn: NSRect(x: 0, y: 0, width: 328, height: 450)),
            PaneDrag.box(for: lane("over", ["o"]), laneSize: size,
                         drawnIn: NSRect(x: 100, y: 100, width: 328, height: 450)),
        ]
        // Near the top of both: a fifth of the way across the tile on top, the
        // middle of the one under it.
        let point = CGPoint(x: 164, y: 130)
        #expect(PaneDrag.drop(at: point, in: tiles, dragging: .pane("x"), topmost: "over", openEnds: false)?
            .target == .into(laneId: "over", index: 0))
        #expect(PaneDrag.drop(at: point, in: tiles, dragging: .pane("x"), openEnds: false)?
            .target == .into(laneId: "under", index: 0))
    }

    // MARK: - a pane, by its grip

    /// **The one-off.** Moving a pane *down* inside its own lane: the gaps the
    /// pointer picks between are counted over a stack that still contains it,
    /// and the ledger wants a place among the panes that will be its siblings.
    @Test("reordering downwards counts the gaps without the pane being moved")
    func reorderingDownwardsCountsWithout() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        // The bottom of the last pane: gap 3 of three, index 2 of the two left.
        #expect(target(at(all[0], pane: 2, v: 0.9), all, .pane("x")) == .into(laneId: "a", index: 2))
        // The top of it: gap 2, index 1 — between the two survivors.
        #expect(target(at(all[0], pane: 2, v: 0.1), all, .pane("x")) == .into(laneId: "a", index: 1))
    }

    @Test("reordering upwards needs no adjustment at all")
    func reorderingUpwardsIsPlain() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        #expect(target(at(all[0], pane: 0, v: 0.1), all, .pane("z")) == .into(laneId: "a", index: 0))
    }

    @Test("both edges of a pane that touch it put it back where it is")
    func theGapsEitherSideAreRefused() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        // Its own top and bottom, the bottom of the pane above, the top of the one below.
        #expect(target(at(all[0], pane: 1, v: 0.1), all, .pane("y")) == nil)
        #expect(target(at(all[0], pane: 1, v: 0.9), all, .pane("y")) == nil)
        #expect(target(at(all[0], pane: 0, v: 0.9), all, .pane("y")) == nil)
        #expect(target(at(all[0], pane: 2, v: 0.1), all, .pane("y")) == nil)
    }

    @Test("a pane out of a stack can open a column beside its own lane")
    func aStackedPaneCanLeaveBesideItsLane() {
        let all = boxes([lane("a", ["x", "y"])])
        #expect(target(at(all[0], pane: 0, u: 0.05, v: 0.5), all, .pane("y")) == .newLane(before: "a"))
        #expect(target(at(all[0], pane: 1, u: 0.95, v: 0.5), all, .pane("y")) == .newLane(before: nil))
    }

    @Test("the only pane of a lane cannot be dropped onto or beside its own lane")
    func aLonePaneOntoItsOwnLaneIsNothing() {
        let all = boxes([lane("a", ["1"]), lane("solo", ["only"]), lane("c", ["3"])])
        for (u, v) in [(0.5, 0.1), (0.5, 0.9), (0.05, 0.5), (0.95, 0.5)] as [(CGFloat, CGFloat)] {
            #expect(target(at(all[1], pane: 0, u: u, v: v), all, .pane("only")) == nil)
        }
        // The right of the lane before it and the left of the lane after it are
        // the two columns that are already where it is.
        #expect(target(at(all[0], pane: 0, u: 0.95, v: 0.5), all, .pane("only")) == nil)
        #expect(target(at(all[2], pane: 0, u: 0.05, v: 0.5), all, .pane("only")) == nil)
        // The far sides are real moves.
        #expect(target(at(all[0], pane: 0, u: 0.05, v: 0.5), all, .pane("only")) == .newLane(before: "a"))
        #expect(target(at(all[2], pane: 0, u: 0.95, v: 0.5), all, .pane("only")) == .newLane(before: nil))
    }

    @Test("a pane dragged from a lane that is not on the strip lands normally")
    func aPaneFromADockedLaneLandsNormally() {
        let all = boxes([lane("a", ["x", "y"])])
        #expect(target(at(all[0], pane: 0, v: 0.1), all, .pane("docked")) == .into(laneId: "a", index: 0))
    }

    // MARK: - a lane, by its header

    @Test("a lane cannot be dropped into itself or beside itself")
    func aLaneOntoItselfIsNothing() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"]), lane("c", ["3"])])
        for index in 0..<2 {
            for (u, v) in [(0.5, 0.1), (0.5, 0.9), (0.05, 0.5), (0.95, 0.5)] as [(CGFloat, CGFloat)] {
                #expect(target(at(all[1], pane: index, u: u, v: v), all, .lane("b")) == nil)
            }
        }
        #expect(target(at(all[0], pane: 0, u: 0.95, v: 0.5), all, .lane("b")) == nil)
        #expect(target(at(all[2], pane: 0, u: 0.05, v: 0.5), all, .lane("b")) == nil)
    }

    @Test("a lane of several goes into another stack as a whole, at the edge it was dropped on")
    func aLaneJoinsAStack() {
        let all = boxes([lane("a", ["1", "2"]), lane("b", ["x", "y"])])
        #expect(target(at(all[1], pane: 1, v: 0.1), all, .lane("a")) == .into(laneId: "b", index: 1))
        #expect(target(at(all[1], pane: 1, v: 0.9), all, .lane("a")) == .into(laneId: "b", index: 2))
        #expect(target(at(all[1], pane: 0, u: 0.95, v: 0.5), all, .lane("a")) == .newLane(before: nil))
    }

    @Test("a docked lane, which has no place in the row, moves beside any lane")
    func aDockedLaneMovesAnywhere() {
        let all = boxes([lane("a", ["1"])])
        #expect(target(at(all[0], pane: 0, u: 0.05, v: 0.5), all, .lane("dock")) == .newLane(before: "a"))
        #expect(target(at(all[0], pane: 0, u: 0.95, v: 0.5), all, .lane("dock")) == .newLane(before: nil))
    }

    // MARK: - reachability

    /// The analogue of the bar's `everyPlaceOnAFlatBarIsReachable`: sweep the
    /// pointer over the whole strip and collect what comes back. A place no
    /// point resolves to is a place the user cannot drop, whatever the
    /// arithmetic says.
    private func sweep(_ all: [PaneDrag.LaneBox], _ source: PaneDrag.Source) -> Set<String> {
        var reached: Set<String> = []
        var x = -20.0 as CGFloat
        while x < (all.last?.maxX ?? 0) + 40 {
            var y = 0.0 as CGFloat
            while y < laneHeight {
                if let got = target(CGPoint(x: x, y: y), all, source) { reached.insert("\(got)") }
                y += 7
            }
            x += 7
        }
        return reached
    }

    private let sweepLanes = [
        ("a", ["a1", "a2"]), ("b", ["b1"]), ("c", ["c1", "c2", "c3"]),
    ]

    @Test("from a grip, every place in every stack and every column is reachable")
    func everyPlaceIsReachableForAPane() {
        let all = boxes(sweepLanes.map { lane($0.0, $0.1) })
        var wanted: Set<String> = []
        // In its own lane, only below a2 is somewhere else.
        wanted.insert("\(PaneDrag.Target.into(laneId: "a", index: 1))")
        for gap in 0...1 { wanted.insert("\(PaneDrag.Target.into(laneId: "b", index: gap))") }
        for gap in 0...3 { wanted.insert("\(PaneDrag.Target.into(laneId: "c", index: gap))") }
        for before in ["a", "b", "c"] as [String?] + [nil] {
            wanted.insert("\(PaneDrag.Target.newLane(before: before))")
        }
        let reached = sweep(all, .pane("a1"))
        #expect(reached == wanted,
                "unreachable: \(wanted.subtracting(reached).sorted()); unexpected: \(reached.subtracting(wanted).sorted())")
    }

    @Test("from a header, every other stack and every other column is reachable")
    func everyPlaceIsReachableForALane() {
        let all = boxes(sweepLanes.map { lane($0.0, $0.1) })
        var wanted: Set<String> = []
        for gap in 0...2 { wanted.insert("\(PaneDrag.Target.into(laneId: "a", index: gap))") }
        for gap in 0...3 { wanted.insert("\(PaneDrag.Target.into(laneId: "c", index: gap))") }
        // Left of b and left of c are where b already is.
        wanted.insert("\(PaneDrag.Target.newLane(before: "a"))")
        wanted.insert("\(PaneDrag.Target.newLane(before: nil))")
        let reached = sweep(all, .lane("b"))
        #expect(reached == wanted,
                "unreachable: \(wanted.subtracting(reached).sorted()); unexpected: \(reached.subtracting(wanted).sorted())")
    }

    // MARK: - what gets drawn

    @Test("the region is the half of the pane, or of the lane, the arrival will take")
    func theRegionIsTheHalfItTakes() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        let slot = all[1].panes[1]
        let top = PaneDrag.drop(at: at(all[1], pane: 1, v: 0.1), in: all, dragging: .pane("1"))
        #expect(top?.region == NSRect(x: all[1].minX, y: slot.top, width: all[1].width, height: slot.height / 2))
        let bottom = PaneDrag.drop(at: at(all[1], pane: 1, v: 0.9), in: all, dragging: .pane("1"))
        #expect(bottom?.region == NSRect(
            x: all[1].minX, y: slot.top + slot.height / 2, width: all[1].width, height: slot.height / 2))

        // From off the strip, so neither column is where the pane already is.
        let left = PaneDrag.drop(at: at(all[1], pane: 1, u: 0.05, v: 0.5), in: all, dragging: .pane("dock"))
        #expect(left?.region == NSRect(x: all[1].minX, y: 0, width: all[1].width / 2, height: laneHeight))
        let right = PaneDrag.drop(at: at(all[1], pane: 0, u: 0.95, v: 0.5), in: all, dragging: .pane("dock"))
        #expect(right?.region == NSRect(x: all[1].frame.midX, y: 0, width: all[1].width / 2, height: laneHeight))
    }

    @Test("what a drag picked up is the pane's own slot, or the whole lane")
    func theSourceMark() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        #expect(PaneDrag.slot(of: .pane("y"), in: all) == NSRect(
            x: all[1].minX, y: all[1].panes[1].top, width: all[1].width, height: all[1].panes[1].height))
        #expect(PaneDrag.slot(of: .lane("b"), in: all) == all[1].frame)
        #expect(PaneDrag.slot(of: .pane("not-here"), in: all) == nil)
        #expect(PaneDrag.slot(of: .lane("not-here"), in: all) == nil)
    }

    @Test("an empty strip has nowhere to drop")
    func anEmptyStripHasNowhereToDrop() {
        #expect(PaneDrag.drop(at: CGPoint(x: 10, y: 10), in: [], dragging: .pane("1")) == nil)
        #expect(PaneDrag.drop(at: CGPoint(x: 10, y: 10), in: [], dragging: .lane("a")) == nil)
    }
}

/// The drag, drawn.
///
/// Whether half a pane washed in the accent reads as *it goes here*, and
/// whether the source mark and the region stay distinct when both are in one
/// column, are not questions an assertion can answer. This writes the picture
/// and a human looks at it — real `LaneView`s, real grips, real indicator, the
/// same `PaneDrag` arithmetic the drop will use, from a pointer position.
///
///     ./scripts/test.sh shots /tmp/shots
///
/// Gated on `MAXPANE_SHOTS` like every other sheet.
@Suite("pane drop feedback rendering")
@MainActor
struct PaneDropRenderTests {
    /// Flipped, because `StripContentView` and `GalleryView` are.
    private final class Sheet: NSView {
        override var isFlipped: Bool { true }
    }

    /// A stand-in for a live pane — a dark rectangle with its name on it, which
    /// is what a terminal looks like from the lane's point of view.
    private func stub(_ name: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        let label = NSTextField(labelWithString: name)
        label.font = Theme.mono(11)
        label.textColor = NSColor(white: 0.55, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
        ])
        return view
    }

    private func pane(_ id: String, _ lane: String, _ position: UInt32) -> Pane {
        Pane(id: id, laneId: lane, position: position, kind: .pty, relaySessionId: id,
             url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
             heightWeight: 1, zoom: 1)
    }

    private func lane(_ id: String, _ title: String, _ paneIds: [String], width: UInt32) -> Lane {
        Lane(id: id, ordinal: 0, widthPt: width, title: title, projectRoot: "/Users/x/code/\(id)",
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false,
             dock: nil, span: 1,
             panes: paneIds.enumerated().map { pane($1, id, UInt32($0)) })
    }

    @Test("renders every shape the drop feedback has")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        let width: UInt32 = 420
        let laneHeight: CGFloat = 560
        let lanes = [
            lane("a", "claude — max-pane", ["a1", "a2"], width: width),
            lane("b", "relay-tty", ["b1", "b2", "b3"], width: width),
            lane("c", "docs", ["c1"], width: width),
        ]
        let boxes = PaneDrag.boxes(lanes: lanes, laneHeight: laneHeight)
        func point(_ lane: Int, _ pane: Int, u: CGFloat, v: CGFloat) -> CGPoint {
            let box = boxes[lane], slot = box.panes[pane]
            return CGPoint(x: box.minX + box.width * u, y: slot.top + slot.height * v)
        }

        // One picture per gesture, each placed by where the pointer is.
        let cases: [(String, PaneDrag.Source, CGPoint)] = [
            ("above-a-pane", .lane("c"), point(1, 1, u: 0.5, v: 0.15)),
            ("below-a-pane", .pane("a1"), point(1, 2, u: 0.5, v: 0.85)),
            ("beside-a-lane", .lane("c"), point(0, 0, u: 0.1, v: 0.5)),
            ("reorder-in-stack", .pane("b1"), point(1, 2, u: 0.5, v: 0.85)),
        ]

        for (name, source, pointer) in cases {
            let total = (boxes.last?.maxX ?? 0)
            let sheet = Sheet(frame: NSRect(x: 0, y: 0, width: total, height: laneHeight))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.stripBackground.cgColor

            for (lane, box) in zip(lanes, boxes) {
                let laneView = LaneView(lane: lane, widthBounds: 420...900)
                laneView.frame = box.frame
                for (index, pane) in lane.panes.enumerated() {
                    laneView.setPaneView(stub(pane.id), for: pane.id, at: index)
                }
                laneView.focusedPaneId = lane.panes.first?.id
                sheet.addSubview(laneView)
                laneView.layoutSubtreeIfNeeded()
            }

            if let slot = PaneDrag.slot(of: source, in: boxes) {
                let mark = PaneDropIndicatorView()
                sheet.addSubview(mark)
                mark.show(.source, frame: slot)
            }
            let drop = try #require(PaneDrag.drop(at: pointer, in: boxes, dragging: source))
            let view = PaneDropIndicatorView()
            sheet.addSubview(view)
            view.show(.region, frame: drop.region)

            sheet.layoutSubtreeIfNeeded()
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("pane-drop-\(name).png"))
        }
    }
}
