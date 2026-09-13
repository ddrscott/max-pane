import AppKit
import LanedCore

/// Where a pane being dragged would land, and what index that means.
///
/// **The whole decision half of pane drag-and-drop, and none of the gesture.**
/// The AppKit side of a drag cannot be tested here — there is no synthetic
/// mouse — so everything that could be *wrong* rather than merely ugly lives in
/// this file: which zone a point is in, which gap in a stack, what index the
/// ledger takes for that gap, and whether the drop would do anything at all.
/// What is left outside is a mouse-down, a mouse-up, and a rectangle to draw.
///
/// The precedent is `SidebarModel.dropTarget`, deliberately, and so is the
/// subtlety it documents: **the index a move takes counts siblings *without*
/// the moved row, while the view's gaps count a list that still has it.** The
/// bookmark bar and a lane's stack are the same problem — a row leaving one
/// ordered sibling list and joining another — and the one-off is in the same
/// place in both.
///
/// # The zones
///
/// ```text
///   ┌──────────┬──────────────────────────────┬──────────┐
///   │ new lane │          into this lane      │ new lane │   ← by x
///   │  before  │  at the gap the pointer is    │  after   │
///   │   this   │  nearest, by y                │   this   │
///   └──────────┴──────────────────────────────┴──────────┘
/// ```
///
/// A band at each edge of a lane means *between two columns*; everything
/// between them means *into this column's stack*. A one-point gap between two
/// lanes is what the layout actually leaves (`Theme.borderWidth`), and a
/// one-point drop target is not a target, so the band is taken out of the
/// lane rather than found between them.
enum PaneDrag {
    /// One pane's slot, measured **downward** from the top of its lane.
    ///
    /// Down, because `StripContentView` is flipped: the strip's document view
    /// and this arithmetic are then the same coordinate space, and the wiring
    /// converts a window point and stops.
    struct PaneBox: Equatable {
        let paneId: String
        let top: CGFloat
        let height: CGFloat
    }

    /// One lane's column, in the strip's own coordinates.
    struct LaneBox: Equatable {
        let laneId: String
        let minX: CGFloat
        let width: CGFloat
        /// Top to bottom. Empty is representable and means the same as a lane
        /// with one slot: everything lands at index 0.
        let panes: [PaneBox]

        var maxX: CGFloat { minX + width }
    }

    /// What the drop would do.
    enum Target: Equatable {
        /// Into `laneId`'s stack, at `index` among the panes that will be its
        /// siblings — counted **without** the pane being dragged.
        case into(laneId: String, index: Int)
        /// Out into a lane of its own, immediately left of `before` — or at the
        /// far right of the strip when that is nil.
        case newLane(before: String?)
    }

    /// How much of each end of a lane means "between two columns".
    ///
    /// 64 pt is about a tenth of a default 656 pt lane and a seventh of the
    /// 420 pt floor — wide enough to aim at without looking, narrow enough that
    /// the middle of a column is unambiguously the column. It is capped at a
    /// third of the lane so a lane dragged to its minimum still has a middle:
    /// two bands meeting in the centre would make "into this lane" unreachable
    /// on exactly the lanes where stacking matters most.
    static let edgeBandPt: CGFloat = 64

    static func band(for width: CGFloat) -> CGFloat {
        min(edgeBandPt, max(0, width / 3))
    }

    // MARK: - the geometry, derived from the snapshot

    /// The strip's columns and every pane slot in them, from the snapshot alone.
    ///
    /// No view is read. The heights come from `PaneSplit.heights`, which is the
    /// same function `LaneView.applyPaneHeights` resolves its constraints with,
    /// so the rectangle this file decides against and the rectangle on screen
    /// cannot come to disagree — they are one computation, called twice.
    ///
    /// `lanes` must be the lanes the strip actually lays out
    /// (`StripStore.stripLanes`): a docked lane is not in the row and has no x
    /// to be found at.
    static func boxes(lanes: [Lane], laneHeight: CGFloat) -> [LaneBox] {
        var x: CGFloat = 0
        var out: [LaneBox] = []
        for lane in lanes {
            let width = CGFloat(lane.widthPt)
            let seams = CGFloat(max(0, lane.panes.count - 1)) * PaneSplit.seam
            let available = max(0, laneHeight - Theme.laneHeaderHeight - seams)
            let heights = PaneSplit.heights(
                weights: lane.panes.map(\.heightWeight), available: available)
            var panes: [PaneBox] = []
            for (index, pane) in lane.panes.enumerated() {
                panes.append(PaneBox(
                    paneId: pane.id,
                    top: Theme.laneHeaderHeight + PaneSplit.top(ofPaneAt: index, heights: heights),
                    height: heights.indices.contains(index) ? heights[index] : 0))
            }
            out.append(LaneBox(laneId: lane.id, minX: x, width: width, panes: panes))
            // The strip lays lanes out by summing widths and a border
            // (ADR-0004). Same sum, or the bands land a point off per lane and
            // forty lanes along they land in the wrong column.
            x += width + Theme.borderWidth
        }
        return out
    }

    // MARK: - the decision

    /// Where the pane would land, or nil when the drop would change nothing.
    ///
    /// nil is both "nowhere" and "back where it started", and they are the same
    /// answer on purpose: the indicator is drawn from this, so a gesture that
    /// would do nothing shows nothing — which is the sidebar's rule, and the
    /// only one that does not promise a move and then decline to make it.
    static func target(at point: CGPoint, in lanes: [LaneBox], dragging paneId: String) -> Target? {
        guard !lanes.isEmpty else { return nil }

        let home = lanes.firstIndex { $0.panes.contains { $0.paneId == paneId } }
        // A lane that is only this pane has no stack to be pulled out of: it is
        // already a column, so the gaps either side of it put it back.
        let alone = home.map { lanes[$0].panes.count == 1 } ?? false

        if point.x < lanes[0].minX {
            return newLane(before: lanes[0].laneId, in: lanes, home: home, alone: alone)
        }
        guard let index = lanes.firstIndex(where: { point.x < $0.maxX }) else {
            return newLane(before: nil, in: lanes, home: home, alone: alone)
        }

        let lane = lanes[index]
        let band = band(for: lane.width)
        if point.x < lane.minX + band {
            return newLane(before: lane.laneId, in: lanes, home: home, alone: alone)
        }
        if point.x > lane.maxX - band {
            let after = index + 1 < lanes.count ? lanes[index + 1].laneId : nil
            return newLane(before: after, in: lanes, home: home, alone: alone)
        }
        return into(lane: lane, y: point.y, dragging: paneId)
    }

    /// Into a lane's stack, at the gap the pointer is nearest.
    private static func into(lane: LaneBox, y: CGFloat, dragging paneId: String) -> Target? {
        // Which gap, counted over the panes the lane has **now** — the list the
        // pointer is looking at, dragged pane included.
        var gap = lane.panes.count
        for (index, box) in lane.panes.enumerated() where y < box.top + box.height / 2 {
            gap = index
            break
        }

        guard let from = lane.panes.firstIndex(where: { $0.paneId == paneId }) else {
            return .into(laneId: lane.laneId, index: gap)
        }
        // The ledger counts the pane's new siblings, which do not include it.
        var index = gap
        if gap > from { index -= 1 }
        // Both gaps either side of a pane put it back where it is.
        if index == from { return nil }
        return .into(laneId: lane.laneId, index: index)
    }

    /// Out into a column of its own — refusing the two places that are already
    /// where it is.
    private static func newLane(
        before: String?, in lanes: [LaneBox], home: Int?, alone: Bool
    ) -> Target? {
        guard alone, let home else { return .newLane(before: before) }
        // The lane *is* the pane, so "a new column here" and "the column it is
        // already in" are the same place on both sides of it.
        if before == lanes[home].laneId { return nil }
        if let before, lanes.firstIndex(where: { $0.laneId == before }) == home + 1 { return nil }
        if before == nil, home == lanes.count - 1 { return nil }
        return .newLane(before: before)
    }

    // MARK: - what to draw

    /// The rectangle a target should be drawn over, in the strip's coordinates.
    ///
    /// Here rather than in the view for the same reason the decision is: it is
    /// derived from the same boxes, and an indicator drawn a lane to the left of
    /// where the drop will land is a lie that no assertion about the drop would
    /// catch.
    enum Indicator: Equatable {
        /// A rule across `lane`, at `y` below the top of the strip, with the
        /// whole column outlined.
        case insertion(lane: NSRect, y: CGFloat)
        /// A hard vertical rule where the new column will open.
        case seam(NSRect)
    }

    /// How wide the bar drawn between two columns is. Thicker than a lane's own
    /// border by enough that it cannot be read as one.
    static let seamWidthPt: CGFloat = 4

    static func indicator(
        for target: Target, in lanes: [LaneBox], laneHeight: CGFloat, dragging paneId: String
    ) -> Indicator? {
        switch target {
        case .into(let laneId, let index):
            guard let lane = lanes.first(where: { $0.laneId == laneId }) else { return nil }
            let rect = NSRect(x: lane.minX, y: 0, width: lane.width, height: laneHeight)
            return .insertion(lane: rect, y: gapTop(at: index, in: lane, dragging: paneId))

        case .newLane(let before):
            let boundary: CGFloat
            if let before, let lane = lanes.first(where: { $0.laneId == before }) {
                boundary = lane.minX - Theme.borderWidth / 2
            } else {
                boundary = (lanes.last?.maxX ?? 0) + Theme.borderWidth / 2
            }
            // Kept inside the strip. The document view is exactly as wide as
            // the lanes, so a bar centred on either end is half off it — and
            // the half that is off is not drawn at all. Measured in a render
            // sheet: "a column at the end of the strip" showed as a two-point
            // sliver against the window's edge, which is the one drop target
            // that most needs to be unmistakable.
            let half = seamWidthPt / 2
            let x = min(max(boundary, half), max(half, (lanes.last?.maxX ?? 0) - half))
            return .seam(NSRect(x: x - half, y: 0, width: seamWidthPt, height: laneHeight))
        }
    }

    /// The slot a pane currently occupies, for marking what the drag picked up.
    static func slot(of paneId: String, in lanes: [LaneBox]) -> NSRect? {
        for lane in lanes {
            guard let box = lane.panes.first(where: { $0.paneId == paneId }) else { continue }
            return NSRect(x: lane.minX, y: box.top, width: lane.width, height: box.height)
        }
        return nil
    }

    /// Where the rule goes for a landing index.
    ///
    /// **This is the one-off run backwards, and it has to be.** `Target.into`
    /// counts the panes that will be the arrival's siblings; the stack on
    /// screen still has the dragged pane in it. In the lane the pane came out
    /// of, index 1 among the survivors is a different boundary from index 1
    /// among all of them, so drawing the rule straight from the index puts it a
    /// pane too high for every drop below where the pane started — the one
    /// error this whole file exists to keep in one place.
    private static func gapTop(at index: Int, in lane: LaneBox, dragging paneId: String) -> CGFloat {
        guard !lane.panes.isEmpty else { return Theme.laneHeaderHeight }
        var gap = index
        if let from = lane.panes.firstIndex(where: { $0.paneId == paneId }), index >= from {
            gap = index + 1
        }
        if gap <= 0 { return lane.panes[0].top }
        if gap >= lane.panes.count {
            let last = lane.panes[lane.panes.count - 1]
            return last.top + last.height
        }
        return lane.panes[gap].top - PaneSplit.seam / 2
    }
}

/// The thing you pick a pane up by.
///
/// A pane has no chrome of its own — a terminal is a Ghostty surface edge to
/// edge and a page is a `WKWebView` with a 26 pt bar at the foot — so a drag
/// has to come from somewhere, and the lane's header is already the handle for
/// the *lane*. This is the pane's: a small grip at the top-left of its slot,
/// square, in the lane's border colour, brightening to the accent under the
/// pointer exactly as the seam does and for exactly as long.
///
/// **It is always there and it always takes the click, and that is a real
/// cost, stated plainly**: 14 × 14 pt at the top-left corner of every pane —
/// about two characters of the first row of a terminal — stop being the pane's
/// to receive. The alternative considered was revealing it on hover and letting
/// clicks through until then, which would give the corner back; it was dropped
/// because it rests on a tracking area firing for a view that refuses
/// `hitTest`, and a handle that is sometimes not there is worse than a handle
/// that costs two characters. What the corner keeps is the cheap half of what
/// it did: a press that never moves is a click, and it focuses the pane rather
/// than being swallowed.
@MainActor
final class PaneGripView: NSView {
    static let size = NSSize(width: 14, height: 14)
    /// Clear of the lane's border, and clear of the focus tick at x = 4, which
    /// is 2 pt wide and means something else.
    static let insetX: CGFloat = 10
    static let insetY: CGFloat = 3

    /// `(where the pointer is, in window coordinates; is this the drop)`.
    /// Reported live so the strip can show where the pane would land, and once
    /// more on mouse-up so the ledger takes one write per drag.
    var onDrag: ((NSPoint, Bool) -> Void)?
    /// A press that never became a drag. A click on a pane focuses it, and this
    /// 14 pt square is part of the pane.
    var onClick: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.cursorUpdate` rather than `resetCursorRects`, for the reason
        // `PaneDividerView` gives: this sits on top of a live Ghostty surface
        // or `WKWebView`, both of which set the cursor from their own mouse
        // handling, and a cursor *rect* is resolved against the window's list
        // where the last writer wins.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Re-derive `hovering` from where the pointer actually is. Same bug and
    /// same fix as `PaneDividerView.pointerMayHaveLeft`: a grip that travels
    /// under a stationary pointer gets the `mouseEntered` and often no matching
    /// exit, and stays lit for the rest of the session.
    func pointerMayHaveLeft() {
        guard let window, !dragging else { return }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        moved = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        moved = true
        onDrag?(event.locationInWindow, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        NSCursor.openHand.set()
        if moved {
            onDrag?(event.locationInWindow, true)
        } else {
            onClick?()
        }
        moved = false
    }

    override func draw(_ dirtyRect: NSRect) {
        // Three rules, square, full-bleed within the grip — the same vocabulary
        // the seam is drawn in, at a quarter of the size. Not dots: a dot grid
        // is a rounded texture in a file whose one rule is that nothing is.
        let lit = hovering || dragging
        (lit ? Theme.accent : Theme.laneBorder).setFill()
        let width: CGFloat = 10
        let x = (bounds.width - width) / 2
        for row in 0..<3 {
            NSRect(x: x, y: bounds.midY - 4 + CGFloat(row) * 4, width: width, height: 1).fill()
        }
    }
}

/// Where the pane will land, drawn over the strip while the drag is live.
///
/// One class, two instances and three shapes, because they are one decision
/// seen from two ends: what you picked up, and where it is going. Both are
/// derived from `PaneDrag.indicator` and `PaneDrag.slot`, so the rectangle on
/// screen and the rectangle the drop will use are the same arithmetic.
///
/// Square, hard-edged, Signal Orange, and gone the instant the mouse comes up.
/// It spends no new meaning: the accent's two reserved states are focus and
/// BLOCKED, and both are *states a lane is in* — this outlives nothing, exactly
/// as a lit seam under the pointer does not.
@MainActor
final class PaneDropIndicatorView: NSView {
    enum Shape: Equatable {
        /// The column the pane is going into, with a rule across it at `y` —
        /// measured down from the top of the strip, which is the view's own
        /// origin because this is flipped like the document view it sits in.
        case insertion(y: CGFloat)
        /// A hard bar where a new column will open.
        case seam
        /// The slot the drag picked up.
        case source
    }

    var shape: Shape? {
        didSet { if shape != oldValue { needsDisplay = true } }
    }

    /// How thick the rule across a column is. Thicker than the 2 pt outline
    /// around it, because it is the part that answers *where*.
    private let ruleWidth: CGFloat = 3

    /// Flipped, like `StripContentView`. The whole of this feature is laid out
    /// with y growing downward; a view that disagreed with its parent about
    /// that would put every rule on the mirror of where it belongs.
    override var isFlipped: Bool { true }

    /// Transparent to the mouse, without exception. It covers a live terminal
    /// and it exists for the length of a drag.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Put it on screen, fading up the first time. Moving it while it is
    /// already showing is deliberately *not* animated: an eased indicator
    /// trails the pointer that is placing it, which is the same reason a seam
    /// takes no implicit animation.
    func show(_ shape: Shape, frame: NSRect) {
        let appearing = isHidden
        self.shape = shape
        if self.frame != frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frame = frame
            CATransaction.commit()
        }
        guard appearing else { return }
        isHidden = false
        guard !Motion.isReduced else { return alphaValue = 1 }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pane
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        alphaValue = 1
        shape = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let shape else { return }
        switch shape {
        case .seam:
            Theme.accent.setFill()
            bounds.fill()

        case .source:
            // A wash rather than an outline, and that is not a taste call: in a
            // reorder *inside* one stack the source and the target are the same
            // column, and two accent outlines a pane apart read as one lane
            // with a rendering fault rather than as "this one, going there".
            // A tint says what was picked up without competing with the rule
            // that says where it lands.
            Theme.accent.withAlphaComponent(0.12).setFill()
            bounds.fill()
            Theme.accent.withAlphaComponent(0.4).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()

        case .insertion(let y):
            // The column, outlined whole. A single-edge rail bent round a
            // corner is the thing this vocabulary refuses; the perimeter says
            // "this column" without claiming an edge.
            Theme.accent.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()

            // And the rule where it will actually land, which is the half of
            // this that answers *where in the stack*.
            //
            // Held a seam's width inside the column. The top of a stack is the
            // bottom of the header and the bottom of a stack is the bottom of
            // the lane, so a rule centred on either is half outside the view
            // and half merged into the outline around it — measured in a render
            // sheet, where "append at the end of this stack" was the one target
            // that showed nothing at all, and then read as a slightly thicker
            // bottom border. A seam is exactly the gap the rule sits in
            // everywhere else in the stack, so the two ends now look like the
            // middle rather than like an edge that has gone bold.
            let half = ruleWidth / 2
            let inset = PaneSplit.seam + half
            let clamped = min(max(y, inset), bounds.height - inset)
            Theme.accent.setFill()
            NSRect(x: 0, y: clamped - half, width: bounds.width, height: ruleWidth).fill()
        }
    }
}
