import AppKit
import LanedCore

/// Where a pane or a lane being dragged would land, and what that means to the
/// ledger.
///
/// **The whole decision half of drag-and-drop, and none of the gesture.** The
/// AppKit side of a drag cannot be tested here — there is no synthetic mouse —
/// so everything that could be *wrong* rather than merely ugly lives in this
/// file: which pane the pointer is over, which edge of it, what index the
/// ledger takes for that, and whether the drop would do anything at all. What
/// is left outside is a mouse-down, a mouse-up, and a rectangle to draw.
///
/// The precedent is `SidebarModel.dropTarget`, deliberately, and so is the
/// subtlety it documents: **the index a move takes counts siblings *without*
/// the moved row, while the view's gaps count a list that still has it.**
///
/// # The zones
///
/// Every pane is cut along its diagonals, and the edge the pointer is nearest
/// is the edge the arrival goes against:
///
/// ```text
///   ┌──────────────────────┐
///   │╲        top         ╱│   top / bottom — into this lane's stack,
///   │  ╲                ╱  │                  above or below this pane
///   │    ╲            ╱    │
///   │left  ╲        ╱ right│   left / right — a column of its own,
///   │        ╲    ╱        │                  beside this lane
///   │         ╱  ╲         │
///   │       ╱      ╲       │
///   │     ╱  bottom  ╲     │
///   └──────────────────────┘
/// ```
///
/// That is the owner's gesture — *"hover over the top, left, right, bottom of
/// another pane to subdivide it up to a single level"* — and it is also the
/// whole of what one level of nesting can say. Panes stack inside a lane and
/// lanes sit side by side, so above and below a pane is its lane's stack and
/// beside it is the strip. There is no drop that makes a tree because there is
/// no third place to put anything.
///
/// Cut on the diagonals of the pane's *own* shape, not by fixed bands, so a
/// short pane in a stack of four and a whole-height portrait column both give
/// every edge a quarter of their area. The header belongs to the top pane and
/// reads as its top edge, and a seam belongs to the pane below it.
enum PaneDrag {
    /// What was picked up.
    enum Source: Equatable {
        /// One pane, by its grip — the only way to take one pane out of a stack.
        case pane(String)
        /// A whole lane, by its header. A lane of one pane *is* that pane, and
        /// the core treats it so; a lane of several moves as one.
        case lane(String)
    }

    /// One pane's slot, in the same space as the `LaneBox` holding it.
    struct PaneBox: Equatable {
        let paneId: String
        let top: CGFloat
        let height: CGFloat
    }

    /// One lane as it is drawn, in a flipped space — the strip's document view
    /// or the gallery, which are both measured downward from their top.
    struct LaneBox: Equatable {
        let laneId: String
        let frame: NSRect
        /// Top to bottom.
        let panes: [PaneBox]

        var minX: CGFloat { frame.minX }
        var maxX: CGFloat { frame.maxX }
        var width: CGFloat { frame.width }
    }

    /// What the drop would do.
    enum Target: Equatable {
        /// Into `laneId`'s stack, at `index` among the panes that will be its
        /// siblings — counted **without** the pane being dragged. For a lane
        /// source every one of its panes goes in there, in order.
        case into(laneId: String, index: Int)
        /// A column of its own, immediately left of `before` — or at the far
        /// right of the strip when that is nil. For a lane source the lane
        /// itself moves there.
        case newLane(before: String?)
    }

    enum Edge: Equatable, CaseIterable { case top, bottom, left, right }

    /// A target, and the rectangle to show it with: the half of the pane — or
    /// of the lane, for a new column — that the arrival will take.
    struct Drop: Equatable {
        let target: Target
        let region: NSRect
    }

    // MARK: - the geometry, derived from the snapshot

    /// The strip's columns and every pane slot in them, from the snapshot alone.
    ///
    /// No view is read. The heights come from `PaneSplit.heights`, which is the
    /// same function `LaneView.applyPaneHeights` resolves its constraints with,
    /// so the rectangle this file decides against and the rectangle on screen
    /// are one computation, called twice.
    ///
    /// `lanes` must be the lanes the strip actually lays out
    /// (`StripStore.stripLanes`): a docked lane is not in the row and has no x
    /// to be found at.
    static func boxes(lanes: [Lane], laneHeight: CGFloat) -> [LaneBox] {
        var x: CGFloat = 0
        var out: [LaneBox] = []
        for lane in lanes {
            let width = CGFloat(lane.widthPt)
            let size = CGSize(width: width, height: laneHeight)
            out.append(box(for: lane, laneSize: size, drawnIn: NSRect(origin: CGPoint(x: x, y: 0), size: size)))
            // The strip lays lanes out by summing widths and a border
            // (ADR-0004). Same sum, or the zones land a point off per lane and
            // forty lanes along they land in the wrong column.
            x += width + Theme.borderWidth
        }
        return out
    }

    /// One lane, laid out at its real `laneSize` and drawn into `frame`.
    ///
    /// On the strip the two are the same size. In the gallery the frame is the
    /// tile and the lane is its real size under a transform (ADR-0011), so the
    /// slots are worked out at the size the lane lays itself out at and then
    /// scaled into the tile — which is exactly what AppKit does to the views.
    static func box(for lane: Lane, laneSize: CGSize, drawnIn frame: NSRect) -> LaneBox {
        let seams = CGFloat(max(0, lane.panes.count - 1)) * PaneSplit.seam
        let available = max(0, laneSize.height - Theme.laneHeaderHeight - seams)
        let heights = PaneSplit.heights(weights: lane.panes.map(\.heightWeight), available: available)
        let scale = laneSize.height > 0 ? frame.height / laneSize.height : 1
        let panes = lane.panes.enumerated().map { index, pane in
            PaneBox(
                paneId: pane.id,
                top: frame.minY
                    + (Theme.laneHeaderHeight + PaneSplit.top(ofPaneAt: index, heights: heights)) * scale,
                height: (heights.indices.contains(index) ? heights[index] : 0) * scale)
        }
        return LaneBox(laneId: lane.id, frame: frame, panes: panes)
    }

    // MARK: - the decision

    /// Where the drop would land, or nil when it would change nothing.
    ///
    /// nil is both "nowhere" and "back where it started", and they are the same
    /// answer on purpose: the indicator is drawn from this, so a gesture that
    /// would do nothing shows nothing — the sidebar's rule, and the only one
    /// that does not promise a move and then decline to make it.
    ///
    /// - Parameters:
    ///   - topmost: a lane drawn over the others — the gallery's expanded tile —
    ///     which wins a point inside it.
    ///   - openEnds: whether the space before the first lane and after the last
    ///     means the outer edge of that lane. True on the strip, where the lanes
    ///     are one row and the window past its end is where a new column goes;
    ///     false in the gallery, where the space between tiles is not a place.
    static func drop(
        at point: CGPoint, in lanes: [LaneBox], dragging source: Source,
        topmost: String? = nil, openEnds: Bool = true
    ) -> Drop? {
        guard let first = lanes.first, let last = lanes.last else { return nil }

        let index: Int
        let forced: Edge?
        if let hit = laneIndex(at: point, in: lanes, topmost: topmost) {
            index = hit
            forced = nil
        } else if openEnds, point.x < first.minX {
            index = 0
            forced = .left
        } else if openEnds, point.x >= last.maxX {
            index = lanes.count - 1
            forced = .right
        } else {
            return nil
        }

        let lane = lanes[index]
        let (slot, rect) = paneSlot(at: point.y, in: lane)
        let edge = forced ?? nearestEdge(to: point, in: rect)

        let target: Target
        let region: NSRect
        switch edge {
        case .top:
            target = .into(laneId: lane.laneId, index: slot)
            region = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom:
            target = .into(laneId: lane.laneId, index: lane.panes.isEmpty ? 0 : slot + 1)
            region = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .left:
            target = .newLane(before: lane.laneId)
            region = NSRect(x: lane.minX, y: lane.frame.minY, width: lane.width / 2, height: lane.frame.height)
        case .right:
            target = .newLane(before: index + 1 < lanes.count ? lanes[index + 1].laneId : nil)
            region = NSRect(x: lane.frame.midX, y: lane.frame.minY, width: lane.width / 2, height: lane.frame.height)
        }
        guard let resolved = resolve(target, in: lanes, dragging: source) else { return nil }
        return Drop(target: resolved, region: region)
    }

    /// The edge of `rect` that `point` is nearest, measured in the rectangle's
    /// own proportions — its diagonals are the boundaries.
    ///
    /// Ties go top, bottom, left, right, so the dead centre of a pane stacks
    /// rather than opening a column: stacking is the smaller change.
    static func nearestEdge(to point: CGPoint, in rect: NSRect) -> Edge {
        let u = rect.width > 0 ? min(max((point.x - rect.minX) / rect.width, 0), 1) : 0.5
        let v = rect.height > 0 ? min(max((point.y - rect.minY) / rect.height, 0), 1) : 0.5
        let distances: [(Edge, CGFloat)] = [(.top, v), (.bottom, 1 - v), (.left, u), (.right, 1 - u)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// Which lane holds the point, the topmost one first.
    ///
    /// Each lane owns the one-point border after it, so the gap the strip
    /// leaves between two columns is not a hole the indicator flickers through.
    private static func laneIndex(at point: CGPoint, in lanes: [LaneBox], topmost: String?) -> Int? {
        func contains(_ lane: LaneBox) -> Bool {
            point.y >= lane.frame.minY && point.y < lane.frame.maxY
                && point.x >= lane.minX && point.x < lane.maxX + Theme.borderWidth
        }
        if let topmost, let index = lanes.firstIndex(where: { $0.laneId == topmost }), contains(lanes[index]) {
            return index
        }
        return lanes.firstIndex(where: contains)
    }

    /// The pane a height is over — the header counts as the top pane and a
    /// seam as the pane below it — and that pane's rectangle.
    private static func paneSlot(at y: CGFloat, in lane: LaneBox) -> (index: Int, rect: NSRect) {
        guard !lane.panes.isEmpty else {
            let top = lane.frame.minY + min(Theme.laneHeaderHeight, lane.frame.height)
            return (0, NSRect(x: lane.minX, y: top, width: lane.width, height: max(0, lane.frame.maxY - top)))
        }
        let index = lane.panes.firstIndex { y < $0.top + $0.height } ?? lane.panes.count - 1
        let box = lane.panes[index]
        return (index, NSRect(x: lane.minX, y: box.top, width: lane.width, height: box.height))
    }

    /// Turn a place on screen into the move it means for this source — or nil,
    /// for the places that are where it already is.
    private static func resolve(_ target: Target, in lanes: [LaneBox], dragging source: Source) -> Target? {
        switch (source, target) {
        case (.pane(let paneId), .into(let laneId, let gap)):
            guard let lane = lanes.first(where: { $0.laneId == laneId }) else { return nil }
            guard let from = lane.panes.firstIndex(where: { $0.paneId == paneId }) else { return target }
            // The ledger counts the pane's new siblings, which do not include
            // it; both gaps either side of a pane put it back where it is.
            let index = gap > from ? gap - 1 : gap
            return index == from ? nil : .into(laneId: laneId, index: index)

        case (.pane(let paneId), .newLane(let before)):
            // Out of a stack, every column is a real move. Only a lane that is
            // this pane alone is already a column.
            guard let home = lanes.firstIndex(where: { $0.panes.contains { $0.paneId == paneId } }),
                  lanes[home].panes.count == 1
            else { return target }
            return isBeside(before, home: home, in: lanes) ? nil : target

        case (.lane(let laneId), .into(let into, _)):
            return into == laneId ? nil : target

        case (.lane(let laneId), .newLane(let before)):
            // A docked lane has no place in the row, so every column is a move.
            guard let home = lanes.firstIndex(where: { $0.laneId == laneId }) else { return target }
            return isBeside(before, home: home, in: lanes) ? nil : target
        }
    }

    /// Whether "a new column left of `before`" is the column at `home` itself.
    /// It is on both sides of it: left of itself, and left of the lane after it.
    private static func isBeside(_ before: String?, home: Int, in lanes: [LaneBox]) -> Bool {
        guard let before else { return home == lanes.count - 1 }
        if before == lanes[home].laneId { return true }
        return lanes.firstIndex(where: { $0.laneId == before }) == home + 1
    }

    // MARK: - what to draw

    /// What the drag picked up, for marking it: a pane's slot, or a whole lane.
    static func slot(of source: Source, in lanes: [LaneBox]) -> NSRect? {
        switch source {
        case .lane(let laneId):
            return lanes.first { $0.laneId == laneId }?.frame
        case .pane(let paneId):
            for lane in lanes {
                guard let box = lane.panes.first(where: { $0.paneId == paneId }) else { continue }
                return NSRect(x: lane.minX, y: box.top, width: lane.width, height: box.height)
            }
            return nil
        }
    }
}

/// The thing you pick one pane of a stack up by.
///
/// A pane has no chrome of its own — a terminal is a Ghostty surface edge to
/// edge and a page is a `WKWebView` with a 26 pt bar at the foot — and the
/// lane's header picks up the *lane*. In a lane of one pane that is the same
/// thing, so the grip is only there when the lane holds a stack: that is the
/// one case where a handle for a single pane says something the header cannot.
///
/// **Where it is shown it always takes the click, and that is a real cost,
/// stated plainly**: 14 × 14 pt at the top-left corner of the pane — about two
/// characters of the first row of a terminal — stop being the pane's to
/// receive. The alternative considered was revealing it on hover and letting
/// clicks through until then; it was dropped because it rests on a tracking
/// area firing for a view that refuses `hitTest`, and a handle that is
/// sometimes not there is worse than a handle that costs two characters. What
/// the corner keeps is the cheap half of what it did: a press that never moves
/// is a click, and it focuses the pane rather than being swallowed.
@MainActor
final class PaneGripView: NSView {
    static let size = NSSize(width: 14, height: 14)
    /// Clear of the lane's border, and clear of the focused pane's outline —
    /// 2 pt wide and one point in from the edge, so it owns x = 1…3 and the top
    /// 2 pt of the pane; the grip starts at x = 10 and 3 pt down, past both.
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

/// Where the drag will land, drawn over the strip or the gallery while it is
/// live.
///
/// One class, two instances and two shapes, because they are one decision seen
/// from two ends: what you picked up, and where it is going. Both are derived
/// from `PaneDrag.drop` and `PaneDrag.slot`, so the rectangle on screen and the
/// rectangle the drop will use are the same arithmetic.
///
/// Square, hard-edged, in the accent, and gone the instant the mouse comes up.
/// It spends no new meaning: the accent's reserved state is focus, and that is
/// a *state a pane is in* — this outlives nothing, exactly as a lit seam under
/// the pointer does not.
@MainActor
final class PaneDropIndicatorView: NSView {
    enum Shape: Equatable {
        /// The half of a pane or a lane the arrival will take.
        case region
        /// What the drag picked up.
        case source
    }

    var shape: Shape? {
        didSet { if shape != oldValue { needsDisplay = true } }
    }

    /// Flipped, like `StripContentView` and `GalleryView`, the two things it is
    /// drawn in: every frame it is given is measured downward from the top.
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

    /// Put it on screen, fading up the first time and easing between regions
    /// after that. The ease is short and it is not a trail: a region changes
    /// when the pointer crosses a diagonal, a handful of times a drag, and a
    /// half-pane of wash that cuts from the top of a column to its right side
    /// is exactly the jump the eye loses track of.
    func show(_ shape: Shape, frame: NSRect) {
        let appearing = isHidden
        self.shape = shape
        if appearing {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frame = frame
            CATransaction.commit()
            isHidden = false
            guard !Motion.isReduced else { return alphaValue = 1 }
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.pane
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
            return
        }
        guard self.frame != frame else { return }
        guard !Motion.isReduced else { return self.frame = frame }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pane / 2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().frame = frame
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
        case .source:
            // A wash rather than an outline: in a reorder inside one stack the
            // source and the target are the same column, and two accent
            // outlines a pane apart read as one lane with a rendering fault
            // rather than as "this one, going there".
            Theme.accent.withAlphaComponent(0.12).setFill()
            bounds.fill()
            Theme.accent.withAlphaComponent(0.4).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()

        case .region:
            // Stronger wash, and a full-perimeter outline. A single lit edge
            // bent round a corner is the thing this vocabulary refuses; the
            // perimeter says "this half" without claiming a side.
            Theme.accent.withAlphaComponent(0.22).setFill()
            bounds.fill()
            Theme.accent.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}
