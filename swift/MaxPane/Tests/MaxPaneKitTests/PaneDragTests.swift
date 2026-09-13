import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Dropping a pane somewhere on the strip.
///
/// **The drag itself is AppKit's and cannot be exercised here** — there is no
/// synthetic mouse in this suite — so everything that can be *wrong* rather
/// than merely ugly is in `PaneDrag` and is what this file is about: which zone
/// a point is in, which gap in a stack, what index the ledger takes for that
/// gap, and whether the drop would do anything at all.
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

    /// The horizontal middle of lane `index` — unambiguously "into this lane".
    private func middleX(of index: Int, in boxes: [PaneDrag.LaneBox]) -> CGFloat {
        boxes[index].minX + boxes[index].width / 2
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

    // MARK: - which zone

    @Test("the middle of a lane is that lane's stack")
    func theMiddleIsTheStack() {
        let all = boxes([lane("a", ["1"]), lane("b", ["2", "3"])])
        let point = CGPoint(x: middleX(of: 1, in: all), y: laneHeight / 2)
        #expect(PaneDrag.target(at: point, in: all, dragging: "1") != nil)
        guard case .into(let laneId, _)? =
            PaneDrag.target(at: point, in: all, dragging: "1") else {
            Issue.record("the middle of a lane was not a stack"); return
        }
        #expect(laneId == "b")
    }

    @Test("a band at each end of a lane means between two columns")
    func theEndsOfALaneAreTheGapsBetweenThem() {
        // Dragged out of a *stack*, so every gap is a real move: the only pane
        // of a lane already has a column, and the two gaps touching it are
        // where it is — `theGapsEitherSideOfALoneLaneAreRefused` is that half.
        let all = boxes([lane("a", ["1", "9"]), lane("b", ["2"]), lane("c", ["3"])])
        let band = PaneDrag.band(for: CGFloat(width))
        let y = laneHeight / 2

        // Just inside lane b's leading edge: the gap between a and b.
        let leading = CGPoint(x: all[1].minX + band / 2, y: y)
        #expect(PaneDrag.target(at: leading, in: all, dragging: "1") == .newLane(before: "b"))

        // Just inside its trailing edge: the gap between b and c.
        let trailing = CGPoint(x: all[1].maxX - band / 2, y: y)
        #expect(PaneDrag.target(at: trailing, in: all, dragging: "1") == .newLane(before: "c"))
    }

    @Test("past the last lane is the end of the strip, and before the first is the front")
    func theEndsOfTheStrip() {
        let all = boxes([lane("a", ["1", "9"]), lane("b", ["2"])])
        #expect(PaneDrag.target(at: CGPoint(x: all[1].maxX + 200, y: 10), in: all, dragging: "1")
                == .newLane(before: nil))
        #expect(PaneDrag.target(at: CGPoint(x: -40, y: 10), in: all, dragging: "2")
                == .newLane(before: "a"))
    }

    @Test("a lane dragged to its minimum still has a middle")
    func theBandNeverEatsTheWholeLane() {
        // Two 64 pt bands in a 420 pt lane would leave 292; two in a 150 pt one
        // would leave 22. The cap is what keeps "into this lane" reachable.
        #expect(PaneDrag.band(for: 420) == PaneDrag.edgeBandPt)
        #expect(PaneDrag.band(for: 150) == 50)
        for laneWidth in [150.0, 300.0, 420.0, 656.0, 900.0] as [CGFloat] {
            #expect(2 * PaneDrag.band(for: laneWidth) < laneWidth)
        }
    }

    // MARK: - which gap, and what index that is

    @Test("dropping in the top half of a pane puts the arrival above it")
    func theTopHalfIsAbove() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y", "z"])])
        let slots = all[1].panes
        let x = middleX(of: 1, in: all)
        for (index, slot) in slots.enumerated() {
            let point = CGPoint(x: x, y: slot.top + slot.height * 0.25)
            #expect(PaneDrag.target(at: point, in: all, dragging: "1")
                    == .into(laneId: "b", index: index))
        }
    }

    @Test("dropping in the bottom half of the last pane appends")
    func theBottomHalfOfTheLastPaneAppends() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        let last = all[1].panes[1]
        let point = CGPoint(x: middleX(of: 1, in: all), y: last.top + last.height * 0.9)
        #expect(PaneDrag.target(at: point, in: all, dragging: "1")
                == .into(laneId: "b", index: 2))
    }

    @Test("over the header is the top of the stack")
    func theHeaderIsTheTopOfTheStack() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        let point = CGPoint(x: middleX(of: 1, in: all), y: Theme.laneHeaderHeight / 2)
        #expect(PaneDrag.target(at: point, in: all, dragging: "1")
                == .into(laneId: "b", index: 0))
    }

    /// **The one-off.** Moving a pane *down* inside its own lane: the gaps the
    /// pointer picks between are counted over a stack that still contains it,
    /// and the ledger wants a place among the panes that will be its siblings.
    @Test("reordering downwards counts the gaps without the pane being moved")
    func reorderingDownwardsCountsWithout() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        let slots = all[0].panes
        let x = middleX(of: 0, in: all)

        // Dragging the top pane into the bottom half of the last one: gap 3 of
        // three panes, which is index 2 of the two that remain.
        let bottom = CGPoint(x: x, y: slots[2].top + slots[2].height * 0.9)
        #expect(PaneDrag.target(at: bottom, in: all, dragging: "x")
                == .into(laneId: "a", index: 2))

        // And into the top half of the last one: gap 2, index 1 — between the
        // two survivors, which is where the eye says it is going.
        let middle = CGPoint(x: x, y: slots[2].top + slots[2].height * 0.25)
        #expect(PaneDrag.target(at: middle, in: all, dragging: "x")
                == .into(laneId: "a", index: 1))
    }

    @Test("reordering upwards needs no adjustment at all")
    func reorderingUpwardsIsPlain() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        let slots = all[0].panes
        let point = CGPoint(x: middleX(of: 0, in: all), y: slots[0].top + slots[0].height * 0.25)
        #expect(PaneDrag.target(at: point, in: all, dragging: "z")
                == .into(laneId: "a", index: 0))
    }

    @Test("both gaps either side of a pane put it back where it is")
    func theGapsEitherSideAreRefused() {
        let all = boxes([lane("a", ["x", "y", "z"])])
        let slots = all[0].panes
        let x = middleX(of: 0, in: all)
        // The gap above y, and the gap below it.
        #expect(PaneDrag.target(
            at: CGPoint(x: x, y: slots[1].top + slots[1].height * 0.25),
            in: all, dragging: "y") == nil)
        #expect(PaneDrag.target(
            at: CGPoint(x: x, y: slots[1].top + slots[1].height * 0.9),
            in: all, dragging: "y") == nil)
    }

    // MARK: - a lane that is only this pane

    @Test("the only pane of a lane cannot be dropped onto its own lane")
    func aLoneePaneOntoItsOwnLaneIsNothing() {
        // The case that would otherwise destroy the lane and put the pane back
        // into the lane it just dissolved.
        let all = boxes([lane("a", ["only"]), lane("b", ["x"])])
        let x = middleX(of: 0, in: all)
        for y in [Theme.laneHeaderHeight / 2, laneHeight * 0.25, laneHeight * 0.9] {
            #expect(PaneDrag.target(at: CGPoint(x: x, y: y), in: all, dragging: "only") == nil)
        }
    }

    @Test("the gaps either side of a lane of one put it back where it is")
    func theGapsEitherSideOfALoneLaneAreRefused() {
        let all = boxes([lane("a", ["1"]), lane("solo", ["only"]), lane("c", ["3"])])
        let band = PaneDrag.band(for: CGFloat(width))
        let y = laneHeight / 2
        // Its own leading edge, and the leading edge of the lane after it.
        #expect(PaneDrag.target(
            at: CGPoint(x: all[1].minX + band / 2, y: y), in: all, dragging: "only") == nil)
        #expect(PaneDrag.target(
            at: CGPoint(x: all[1].maxX - band / 2, y: y), in: all, dragging: "only") == nil)
        // But the far side of the strip is a real move.
        #expect(PaneDrag.target(
            at: CGPoint(x: all[0].minX + band / 2, y: y), in: all, dragging: "only")
                == .newLane(before: "a"))
    }

    @Test("the end of the strip is refused only for the lane already at the end")
    func theEndOfTheStripIsRefusedForTheLastLane() {
        let atTheEnd = boxes([lane("a", ["1"]), lane("solo", ["only"])])
        #expect(PaneDrag.target(
            at: CGPoint(x: atTheEnd[1].maxX + 200, y: 10), in: atTheEnd, dragging: "only") == nil)

        let notAtTheEnd = boxes([lane("solo", ["only"]), lane("a", ["1"])])
        #expect(PaneDrag.target(
            at: CGPoint(x: notAtTheEnd[1].maxX + 200, y: 10), in: notAtTheEnd, dragging: "only")
                == .newLane(before: nil))
    }

    @Test("a lane of one is still a pane you can stack into somebody else's column")
    func aLonePaneCanJoinAnotherStack() {
        let all = boxes([lane("solo", ["only"]), lane("b", ["x", "y"])])
        let slots = all[1].panes
        let point = CGPoint(x: middleX(of: 1, in: all), y: slots[1].top + slots[1].height * 0.9)
        #expect(PaneDrag.target(at: point, in: all, dragging: "only")
                == .into(laneId: "b", index: 2))
    }

    @Test("a pane dragged from a lane that is not on the strip lands normally")
    func aPaneFromADockedLaneLandsNormally() {
        // A docked lane has no x — it is not in the row the strip lays out — so
        // the drag has no home among these boxes and every drop is a real move.
        let all = boxes([lane("a", ["x", "y"])])
        let slots = all[0].panes
        #expect(PaneDrag.target(
            at: CGPoint(x: middleX(of: 0, in: all), y: slots[0].top + slots[0].height * 0.25),
            in: all, dragging: "docked") == .into(laneId: "a", index: 0))
    }

    // MARK: - reachability

    @Test("every place in every stack, and every gap between columns, is reachable")
    func everyPlaceOnTheStripIsReachable() {
        // The analogue of the bar's `everyPlaceOnAFlatBarIsReachable`: sweep the
        // pointer over the whole strip and collect what comes back. A zone that
        // no point resolves to is a place the user cannot drop, whatever the
        // arithmetic says.
        let lanes = [lane("a", ["a1", "a2"]), lane("b", ["b1"]), lane("c", ["c1", "c2", "c3"])]
        let all = boxes(lanes)
        var reached: Set<String> = []
        var x = -20.0 as CGFloat
        while x < all[2].maxX + 40 {
            var y = 0.0 as CGFloat
            while y < laneHeight {
                if let target = PaneDrag.target(at: CGPoint(x: x, y: y), in: all, dragging: "a1") {
                    reached.insert("\(target)")
                }
                y += 7
            }
            x += 7
        }

        var wanted: Set<String> = []
        // In its own lane, only the far side of a2 is somewhere else.
        wanted.insert("\(PaneDrag.Target.into(laneId: "a", index: 1))")
        for gap in 0...1 { wanted.insert("\(PaneDrag.Target.into(laneId: "b", index: gap))") }
        for gap in 0...3 { wanted.insert("\(PaneDrag.Target.into(laneId: "c", index: gap))") }
        // And every gap between columns, including both ends of the strip.
        for before in ["a", "b", "c"] {
            wanted.insert("\(PaneDrag.Target.newLane(before: before))")
        }
        wanted.insert("\(PaneDrag.Target.newLane(before: nil))")

        let missing = wanted.subtracting(reached).sorted()
        let extra = reached.subtracting(wanted).sorted()
        #expect(reached == wanted, "unreachable: \(missing); unexpected: \(extra)")
    }

    // MARK: - what gets drawn

    @Test("the rule is drawn at the boundary the pointer is at, not at the ledger's index")
    func theIndicatorIsDrawnAtTheGapTheEyeIsOn() {
        // The one-off run backwards. Dragging the top pane of three to the
        // bottom is index 2 of the survivors and gap 3 of the stack on screen,
        // and the rule belongs under the bottom pane — not under the middle one.
        let all = boxes([lane("a", ["x", "y", "z"])])
        let slots = all[0].panes
        guard case .insertion(_, let y)? = PaneDrag.indicator(
            for: .into(laneId: "a", index: 2), in: all, laneHeight: laneHeight, dragging: "x")
        else {
            Issue.record("no insertion indicator"); return
        }
        #expect(abs(y - (slots[2].top + slots[2].height)) < 0.001)
    }

    @Test("an insertion is drawn over the column it is going into")
    func theInsertionCoversTheTargetColumn() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        guard case .insertion(let rect, let y)? = PaneDrag.indicator(
            for: .into(laneId: "b", index: 1), in: all, laneHeight: laneHeight, dragging: "1")
        else {
            Issue.record("no insertion indicator"); return
        }
        #expect(rect == NSRect(x: all[1].minX, y: 0, width: all[1].width, height: laneHeight))
        // Halfway down the seam between the two panes.
        #expect(abs(y - (all[1].panes[1].top - PaneSplit.seam / 2)) < 0.001)
    }

    @Test("a new column is drawn as a bar in the gap it will open in")
    func theSeamIsDrawnInTheGap() {
        let all = boxes([lane("a", ["1"]), lane("b", ["2"])])
        guard case .seam(let rect)? = PaneDrag.indicator(
            for: .newLane(before: "b"), in: all, laneHeight: laneHeight, dragging: "1")
        else {
            Issue.record("no seam indicator"); return
        }
        #expect(rect.width == PaneDrag.seamWidthPt)
        #expect(rect.height == laneHeight)
        #expect(abs(rect.midX - (all[1].minX - Theme.borderWidth / 2)) < 0.001)

        guard case .seam(let end)? = PaneDrag.indicator(
            for: .newLane(before: nil), in: all, laneHeight: laneHeight, dragging: "1")
        else {
            Issue.record("no seam indicator at the end"); return
        }
        #expect(end.midX > all[1].minX)
        // And both ends stay inside the strip: the document view is exactly as
        // wide as the lanes, so a bar centred on either end would be half
        // undrawn.
        #expect(end.maxX <= all[1].maxX)
        guard case .seam(let front)? = PaneDrag.indicator(
            for: .newLane(before: "a"), in: all, laneHeight: laneHeight, dragging: "2")
        else {
            Issue.record("no seam indicator at the front"); return
        }
        #expect(front.minX >= all[0].minX)
    }

    @Test("the slot a drag picked up is the pane's own rectangle")
    func theSourceMarkIsThePanesSlot() {
        let all = boxes([lane("a", ["1"]), lane("b", ["x", "y"])])
        let slot = PaneDrag.slot(of: "y", in: all)
        #expect(slot == NSRect(x: all[1].minX, y: all[1].panes[1].top,
                               width: all[1].width, height: all[1].panes[1].height))
        #expect(PaneDrag.slot(of: "not-here", in: all) == nil)
    }

    @Test("an empty strip has nowhere to drop")
    func anEmptyStripHasNowhereToDrop() {
        #expect(PaneDrag.target(at: CGPoint(x: 10, y: 10), in: [], dragging: "1") == nil)
    }
}

/// The drag, drawn.
///
/// Whether a 4 pt bar in a one-point gap reads as *a column opens here*, and
/// whether a 14 pt grip in the corner of a terminal is findable without being
/// in the way, are not questions an assertion can answer. This writes the
/// picture and a human looks at it — real `LaneView`s, real grips, real
/// indicator, the same `PaneDrag` arithmetic the drop will use.
///
///     ./scripts/test.sh shots /tmp/shots
///
/// Gated on `MAXPANE_SHOTS` like every other sheet.
@Suite("pane drop feedback rendering")
@MainActor
struct PaneDropRenderTests {
    /// Flipped, because `StripContentView` is: the indicator's frames come
    /// straight out of `PaneDrag` and are measured downward from the top of the
    /// strip, so a sheet that disagreed would mirror every one of them.
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

        // One picture per shape, each named for the gesture that produces it.
        let cases: [(String, String, PaneDrag.Target)] = [
            ("into-stack", "a1", .into(laneId: "b", index: 2)),
            ("new-lane", "a1", .newLane(before: "c")),
            ("reorder", "b1", .into(laneId: "b", index: 2)),
            ("end-of-strip", "a1", .newLane(before: nil)),
        ]

        for (name, dragged, target) in cases {
            let total = (boxes.last?.maxX ?? 0)
            let sheet = Sheet(frame: NSRect(x: 0, y: 0, width: total, height: laneHeight))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.stripBackground.cgColor

            for (lane, box) in zip(lanes, boxes) {
                let laneView = LaneView(lane: lane, widthBounds: 420...900)
                laneView.frame = NSRect(x: box.minX, y: 0, width: box.width, height: laneHeight)
                for (index, pane) in lane.panes.enumerated() {
                    laneView.setPaneView(stub(pane.id), for: pane.id, at: index)
                }
                laneView.focusedPaneId = lane.panes.first?.id
                sheet.addSubview(laneView)
                laneView.layoutSubtreeIfNeeded()
            }

            if let slot = PaneDrag.slot(of: dragged, in: boxes) {
                let mark = PaneDropIndicatorView()
                sheet.addSubview(mark)
                mark.show(.source, frame: slot)
            }
            if let indicator = PaneDrag.indicator(
                for: target, in: boxes, laneHeight: laneHeight, dragging: dragged) {
                let view = PaneDropIndicatorView()
                sheet.addSubview(view)
                switch indicator {
                case .insertion(let rect, let y): view.show(.insertion(y: y), frame: rect)
                case .seam(let rect): view.show(.seam, frame: rect)
                }
            }

            sheet.layoutSubtreeIfNeeded()
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("pane-drop-\(name).png"))
        }
    }
}
