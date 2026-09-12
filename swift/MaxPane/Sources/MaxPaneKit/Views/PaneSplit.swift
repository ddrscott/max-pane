import AppKit

/// How a lane's height is divided between its panes, and what dragging the
/// seam between two of them does to that division.
///
/// Pure arithmetic, kept out of the view for the same reason `LaneSnap` and
/// `PaneStackPlan` are: the failure it guards against is never visual. A drag
/// that moves the wrong pair, a floor honoured for two panes out of three, a
/// residual point that makes the stack one point taller than the lane — none of
/// those look like anything on screen except "the divider is slightly wrong",
/// which is the hardest kind of bug to see and the easiest kind to assert.
///
/// The one rule everything here follows: **a pane's height is its share of the
/// lane, and the share is what persists.** Points are derived, every time, from
/// however tall the lane happens to be. That is what makes the split survive a
/// window resize, a fullscreen toggle and a second display without a single
/// write, and it is why the ledger stores a weight rather than a height.
enum PaneSplit {
    /// The shortest a pane may be dragged.
    ///
    /// 72pt is about four rows of JetBrains Mono at the default 13pt plus the
    /// terminal's own 4pt inset — the least that still shows a command, a line
    /// of its output and the next prompt, which is the smallest a terminal can
    /// be and still be one. It is a floor on the *pane*, not on the drag: the
    /// seam stays where the pointer leaves it and stays grabbable, so a pane
    /// squeezed to the floor is always one drag away from coming back.
    static let minPaneHeight: CGFloat = 72

    /// The gap the stack leaves between two panes, and the width of the seam
    /// drawn in it.
    ///
    /// The lane's own border is `Theme.borderWidth`, and the seam is a rule of
    /// exactly that weight top and bottom so a split lane reads as one column
    /// divided rather than two columns stacked. The 3pt between them is the
    /// trough — the same strip background that shows between two lanes.
    static let seam: CGFloat = 5

    /// How tall the thing you can actually grab is.
    ///
    /// Wider than the seam it draws, and overlapping its neighbours by 3pt
    /// either side. Measured rather than guessed: a synthetic drag starting two
    /// points above a 5pt seam produced nothing at all, and a seam you have to
    /// aim at is a seam that reads as not being draggable. The overlap costs
    /// the two panes 3pt of clickable edge each, which is a trade worth making
    /// in a column where the thing under that edge is blank margin.
    static let grab: CGFloat = 11

    /// The height each pane gets, in points, in a lane with `available` points
    /// of room for panes — the lane's height less its header and less every
    /// seam.
    ///
    /// Returns as many heights as there are weights, summing to exactly
    /// `available`. "Exactly" matters: these become constraint constants inside
    /// a stack that is pinned top and bottom, so a sum that is a point out is a
    /// constraint conflict rather than a point of slack.
    static func heights(weights: [Double], available: CGFloat) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        guard available > 0 else { return Array(repeating: 0, count: n) }

        // A weight that is not a ratio would poison every sibling — one NaN in
        // the sum and the whole lane lays out as NaN. The core refuses to store
        // one; this is the same refusal on the read side, because a ledger
        // written by an older build or edited by hand is not this code's
        // promise to keep.
        let sane = weights.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let total = sane.reduce(0, +)
        let shares = sane.map { CGFloat($0 / total) }

        // Too short to give everyone the floor, so nobody gets it.
        //
        // The tempting alternative is to honour the floor for as many panes as
        // fit, which quietly squeezes the last pane to nothing: a lane that
        // *looks* unsplit in a short window, with a pane you cannot see and
        // cannot get back. Three panes that are all too small is the honest
        // rendering of the same situation, and it is one window-resize away
        // from being right.
        guard CGFloat(n) * minPaneHeight <= available else {
            return exact(shares.map { $0 * available }, summingTo: available)
        }

        // Water-filling. Panes that fall under the floor are pinned to it in
        // turn and the rest re-split what is left, in their own proportions,
        // until nobody is under. At most `n` passes, because each pass pins one
        // more pane and a fully pinned stack is the terminating case.
        var pinned = Set<Int>()
        var heights = [CGFloat](repeating: 0, count: n)
        while true {
            let free = (0..<n).filter { !pinned.contains($0) }
            let room = available - CGFloat(pinned.count) * minPaneHeight
            guard !free.isEmpty else {
                // Everyone is at the floor and there is room left over —
                // possible only when the lane is barely tall enough. Split the
                // remainder evenly; there is no ratio left to honour.
                let spare = (available - CGFloat(n) * minPaneHeight) / CGFloat(n)
                heights = Array(repeating: minPaneHeight + spare, count: n)
                break
            }
            for i in pinned { heights[i] = minPaneHeight }
            let freeShare = free.map { shares[$0] }.reduce(0, +)
            for i in free {
                heights[i] = freeShare > 0
                    ? room * shares[i] / freeShare
                    : room / CGFloat(free.count)
            }
            guard let starved = free.first(where: { heights[$0] < minPaneHeight }) else { break }
            pinned.insert(starved)
        }
        return exact(heights, summingTo: available)
    }

    /// The heights to lay a stack out at while the pane at `arriving` is still
    /// opening — its slot at `progress` of the height it will end up with, and
    /// everybody else sharing what is left in the proportions they already
    /// stood in.
    ///
    /// The seam count is the *finished* one throughout, which is what makes the
    /// entrance readable: the rule appears on the first frame and the new pane's
    /// slot opens away from it, so there is an edge the pane came out of. A seam
    /// that arrived with the pane would have nothing to come from.
    ///
    /// **This exists because `NSStackView` could not be talked into it.** ⇧⌘D
    /// used to unhide the arriving view inside an animation group and let the
    /// stack animate its own attach. Measured frame by frame, the incumbent pane
    /// went `[66,1411] → [554,1225] → [288,295] → [214,443] → [66,737]` — it
    /// imploded and reopened at half height in 167 ms while the arriving pane
    /// went from not-detected to full size in three frames. You saw the lane
    /// blink; you could not see where the new pane came from. Every height here
    /// is monotonic in `progress` by construction, so there is no frame in which
    /// anything moves the wrong way.
    static func opening(
        weights: [Double], arriving: Int, progress: CGFloat, available: CGFloat
    ) -> [CGFloat] {
        let full = heights(weights: weights, available: available)
        guard weights.indices.contains(arriving), progress < 1 else { return full }
        // The only pane in the lane has no seam to come out of and nobody to
        // take the room from, so there is no entrance to make: opening it
        // against the lane itself would be a pane growing out of its own
        // header, which says nothing and walks a live terminal down to no rows
        // on the way.
        guard weights.count > 1 else { return full }

        // **A pane never exists at a height it could not be dragged to.** The
        // entrance opens from `minPaneHeight` rather than from nothing, and that
        // is not a rounding choice: a live view at 654 × 0 is what Ghostty
        // refuses with `surface rebuild skipped: invalid view size=654.00x0.00`,
        // measured in this app's own log during a ⇧⌘D. It costs 72 pt of the
        // first frame out of the ~400 the slot travels, and buys a stack in
        // which no pane is ever a degenerate rectangle with a live terminal
        // inside it.
        let slot = min(full[arriving], max(minPaneHeight, full[arriving] * max(0, progress))).rounded()
        var rest = weights
        rest.remove(at: arriving)
        // The floor is deliberately not honoured for the incumbents mid-opening.
        // `heights` will refuse to squeeze them below 72 pt and the sum would
        // then exceed the lane — a constraint conflict, in a stack pinned top
        // and bottom, for the two tenths of a second nobody is dragging
        // anything. Proportional is the honest rendering of a lane that is
        // momentarily too short.
        let room = max(0, available - slot)
        let total = rest.map { $0.isFinite && $0 > 0 ? $0 : 1 }.reduce(0, +)
        var out = rest.map { w -> CGFloat in
            let sane = w.isFinite && w > 0 ? w : 1
            return total > 0 ? room * CGFloat(sane / total) : room / CGFloat(rest.count)
        }
        out.insert(slot, at: arriving)
        return exact(out, summingTo: available)
    }

    /// The weights after dragging the seam below pane `divider` by `delta`
    /// points, positive meaning the pane *above* the seam grows.
    ///
    /// **A seam moves exactly two panes.** Every other weight comes back
    /// bit-identical, and the pair's combined weight is unchanged, so a stack of
    /// four that the user has arranged does not quietly re-proportion itself
    /// because they nudged one seam. That invariant is the whole reason this
    /// converts back into the pair's own weight rather than into a global
    /// points-per-weight scale: the scale is only exact when nothing hit the
    /// floor, and the pair total is exact always.
    static func drag(weights: [Double], divider: Int, delta: CGFloat, available: CGFloat) -> [Double] {
        guard weights.indices.contains(divider), weights.indices.contains(divider + 1) else {
            return weights
        }
        let heights = heights(weights: weights, available: available)
        let pairHeight = heights[divider] + heights[divider + 1]
        let pairWeight = weights[divider] + weights[divider + 1]
        // Two panes that cannot hold two floors between them have no room for a
        // decision, so the seam does not move rather than moving to a lie.
        guard pairHeight >= 2 * minPaneHeight, pairWeight > 0 else { return weights }

        let top = min(max(heights[divider] + delta, minPaneHeight), pairHeight - minPaneHeight)
        var next = weights
        next[divider] = pairWeight * Double(top / pairHeight)
        next[divider + 1] = pairWeight - next[divider]
        return next
    }

    /// The weight a pane joining a stack should arrive with.
    ///
    /// The mean of what is already there, which is the one value that gives the
    /// newcomer an equal share of the *enlarged* lane while leaving every
    /// existing ratio untouched: the panes already in the lane give up height in
    /// proportion to what they had, so none of them is singled out to pay for
    /// the split.
    ///
    /// The mirror rule, for a pane *leaving*, needs no code at all: heights are
    /// shares, so removing a weight hands its room to the survivors in exactly
    /// the proportions they already stood in. One rule — the share is what
    /// persists — covers joining, leaving and the window changing height, and
    /// three separate rules is how those three end up disagreeing.
    ///
    /// The core is what actually writes this on `add_pane`; it is here too so a
    /// test can state the rule in the same terms the layout does.
    static func weightForJoining(_ existing: [Double]) -> Double {
        let sane = existing.filter { $0.isFinite && $0 > 0 }
        guard !sane.isEmpty else { return 1 }
        return sane.reduce(0, +) / Double(existing.count)
    }

    /// Whole points, summing to exactly what the caller asked for.
    ///
    /// Both halves are load-bearing and both were measured on screen. **Whole
    /// points**: a seam that lands on a half-point is drawn by blending two
    /// rows, and the 1pt rule in it came out as two rows of half-strength grey
    /// against a terminal — 21 against 24, which is nothing. Rounded, the same
    /// rule is one crisp row. It also stops a terminal's grid flickering
    /// between two row counts on alternate layout passes. **Summing to the
    /// total**: these are constraint constants inside a stack pinned top and
    /// bottom, so a point of slack is a conflict rather than a gap — hence the
    /// residual landing on the last pane rather than each pane keeping its own
    /// rounding error.
    private static func exact(_ heights: [CGFloat], summingTo total: CGFloat) -> [CGFloat] {
        guard let last = heights.indices.last else { return heights }
        var out = heights.map { $0.rounded() }
        out[last] = total - out[..<last].reduce(0, +)
        return out
    }
}

/// The seam between two stacked panes: visible, and the thing you drag to
/// change their heights.
///
/// Lanes are separated by a point of strip showing between two bordered
/// columns, and this is that gap turned on its side: a rule in the lane's own
/// border colour, a trough of strip background, another rule. Square, full
/// bleed, no radius and no fill — a seam in a column, not a divider between two
/// cards. A split lane reads as one column with a hard rule across it, which is
/// the thing the owner asked to be able to *see*.
///
/// It brightens to the accent under the pointer. That is the one use of Signal
/// Orange in this file and it is deliberately the same one `LaneHeaderMenuButton`
/// already makes: a momentary "this responds to you" that is gone the instant
/// the pointer leaves. The accent's reserved meanings — focus, and blocked —
/// are both *states a lane is in*, and nothing here outlives the pointer.
@MainActor
final class PaneDividerView: NSView {
    /// `(points the pane above should gain, isFinal)`. Reported live so the
    /// lane relayouts under the pointer, and once more on mouse-up so the
    /// ledger takes one write per drag rather than one per frame.
    var onDrag: ((CGFloat, Bool) -> Void)?

    /// True for the length of a pane's entrance out of this seam.
    ///
    /// The same lit rule the pointer gets, for the same reason and with the same
    /// lifetime — a momentary "this is where that came from" that is gone in
    /// 160 ms. It does not break the accent's two reserved meanings: focus and
    /// BLOCKED are *states a lane is in*, and this outlives nothing.
    var isOpening = false { didSet { if isOpening != oldValue { needsDisplay = true } } }

    private var lastY: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Pane divider")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.cursorUpdate` rather than `resetCursorRects`: this view sits on top
        // of a live `WKWebView` or a Ghostty surface, both of which set the
        // cursor from their own mouse handling, and a cursor *rect* is resolved
        // against the window's rect list where the last writer wins. A tracking
        // area is resolved against what the pointer is actually over, which is
        // this.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Re-derive `hovering` from where the pointer actually is, for the seams
    /// that have just been moved.
    ///
    /// A tracking area answers *the pointer crossed this boundary*, and AppKit
    /// is only reliable about that when the thing that moved is the pointer.
    /// When the **view** travels under a stationary pointer it delivers the
    /// `mouseEntered` and then, often, no matching `mouseExited` at all — so the
    /// seam stays lit for the rest of the session. Measured: a ⇧⌘D whose seam
    /// swept 340 pt past a parked cursor left an orange rule across the lane
    /// two and a half seconds later, and it was still there after the next
    /// split. A drag or a window resize could always do this; the entrance does
    /// it every time, which is what turned a latent bug into a visible one.
    ///
    /// `mouseLocationOutsideOfEventStream` rather than the last event's
    /// location: this is asked from inside `layout`, where there is no event.
    func pointerMayHaveLeft() {
        guard let window, !dragging else { return }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // Window coordinates, not our own: this view moves as the panes resize,
        // so a delta measured in its local space is measured against an origin
        // that the measurement itself just moved, and the drag fights itself.
        // The same reason `LaneResizeHandle` does it, and the same bug.
        lastY = event.locationInWindow.y
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        // Screen y grows upward and the stack runs downward, so the pane above
        // the seam grows when the pointer goes *down*.
        let delta = lastY - y
        lastY = y
        guard delta != 0 else { return }
        onDrag?(delta, false)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onDrag?(0, true)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The trough is strip background — the colour that shows *between* two
        // lanes — with a rule at each edge. That is the gap between two columns
        // turned on its side, exactly: pane border, strip, pane border. It is
        // three tonal steps rather than one, which is the whole difference
        // between a seam you notice and the single hairline this replaced.
        //
        // Measured, not assumed. The hairline alone came out at RGB 31 against
        // a terminal's 21 — a contrast ratio of about 1.15:1, which is another
        // way of spelling the owner's word for the one-point gap it replaced:
        // invisible.
        // Only the seam is painted. The rest of this view is hit area lying
        // over the two panes, and painting it would put a 3pt band of chrome
        // across the bottom line of the terminal above.
        let seam = NSRect(
            x: 0, y: (bounds.height - PaneSplit.seam) / 2,
            width: bounds.width, height: PaneSplit.seam)
        Theme.stripBackground.setFill()
        seam.fill()

        let lit = hovering || dragging || isOpening
        // Under the pointer the rules thicken as well as changing colour. Hue
        // is the one channel a colour-blind reader may not have, and this
        // affordance has to answer "can I grab this" *before* the press.
        let rule = lit ? 2 : Theme.borderWidth
        (lit ? Theme.accent : Theme.laneBorder).setFill()
        NSRect(x: 0, y: seam.minY, width: bounds.width, height: rule).fill()
        NSRect(x: 0, y: seam.maxY - rule, width: bounds.width, height: rule).fill()
    }
}
