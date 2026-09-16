import AppKit
import LanedCore

/// One column of the strip.
///
/// The design invariant, in code: a lane's width is clamped to
/// `[LANE_MIN, LANE_MAX]` and nothing it contains is allowed to widen it. Wide
/// content scrolls inside the pane, never past the lane's edge.
///
/// A lane is a column with a hard edge — square corners, a 1pt border, and
/// status carried by content (the header's glyph and tag chip) rather than by a
/// coloured rail bent around a radius.
@MainActor
final class LaneView: NSView {
    var laneId: String
    private let header = LaneHeaderView()
    private let stack = NSStackView()
    private let resizeHandle = LaneResizeHandle()
    private var paneViews: [String: NSView] = [:]
    /// Each pane's share of the lane, as the ledger has it.
    private var paneWeights: [String: Double] = [:]
    /// What a seam drag is currently asking for, until the ledger agrees.
    ///
    /// The same shape as `desiredWidth` and for the same reason: the lane draws
    /// what the pointer says while the mouse is down, and the ledger is the
    /// truth the instant it is up. A failed write therefore snaps back to the
    /// real split rather than leaving the screen lying about what was stored.
    private var draggedWeights: [String: Double]?
    /// One per pane, owned here and updated in `layout`. The stack distributes
    /// by these rather than by `.fillEqually`.
    private var heightConstraints: [String: NSLayoutConstraint] = [:]
    /// Two per pane, holding it to the lane's width. Kept so a pane leaving the
    /// stack takes them with it: a view that is removed from the arrangement is
    /// still a subview for the length of its exit, and a stale pin to a stack it
    /// has left is an unsatisfiable constraint the instant it is unparented.
    private var widthConstraints: [String: [NSLayoutConstraint]] = [:]
    /// The seams, one fewer than the number of visible panes. Pooled rather
    /// than rebuilt: a divider that is destroyed and recreated on every layout
    /// pass loses its tracking area, and the cursor stops changing halfway
    /// through a drag.
    private var dividers: [PaneDividerView] = []
    /// One per pane, pooled for the same reason the seams are: a handle that is
    /// destroyed and rebuilt on every layout pass loses its tracking area, and
    /// the cursor stops changing halfway through a drag. `gripPaneIds` is what
    /// each pool slot is currently the handle *for*, read at click time rather
    /// than captured, so a lane view recycled onto a different lane does not
    /// carry a closure naming a pane it no longer holds.
    private var grips: [PaneGripView] = []
    private var gripPaneIds: [String] = []
    /// A pane whose slot is still opening, and how far it has got. Purely
    /// visual: the weights the ledger stores are untouched, so a snapshot
    /// arriving mid-entrance re-lays the lane out without knocking it off
    /// course. See `animatePaneViewIn`.
    private var opening: (paneId: String, progress: CGFloat)?
    private var openingTimer: MotionTimer?

    /// Dragging the right edge. Reports live during the drag and once at the end
    /// so the ledger takes one write rather than one per frame.
    var onResize: ((UInt32, _ final: Bool) -> Void)?
    /// Dragging a seam between two stacked panes. Same shape and same
    /// discipline as `onResize`: live while the pointer moves so the lane
    /// reflows under it, once more on the drop so the ledger takes one write
    /// per decision. Only the two panes either side of the seam appear in it.
    var onPaneHeights: (([(paneId: String, weight: Double)], _ final: Bool) -> Void)?
    var onFocusPane: ((String) -> Void)?
    /// Dragging one pane of a stack by its grip. `(pane, where the pointer is in
    /// window coordinates, is this the drop)` — live while the pointer moves so
    /// the strip can show where the pane would land, once more on the drop so
    /// the ledger takes one write per decision.
    var onPaneGrab: ((String, NSPoint, Bool) -> Void)?
    /// Dragging the header picks up the whole lane: onto the top or bottom of
    /// another pane it joins that stack, beside one it moves there (PRD §7.2).
    /// Same shape and discipline as `onPaneGrab`, without the pane.
    var onLaneGrab: ((NSPoint, _ final: Bool) -> Void)?

    /// The header's overflow menu (`⋯`). These are the lane actions that already
    /// exist as `Command`s; the menu is a mouse-reachable path to them for the
    /// lane under the pointer rather than the focused one.
    ///
    /// Every one is optional and every menu item is disabled while its callback
    /// is nil, so a lane whose owner has not connected them shows a greyed-out
    /// menu instead of crashing.
    var onTogglePin: (() -> Void)?
    var onSetProjectTag: (() -> Void)?
    /// ⌃⌘[ / ⌃⌘] / ⌃⌘\, for the lane under the pointer rather than the focused
    /// one. Toggles, like the keys: the item that docked this lane is the item
    /// that gives the edge back, which is why the menu marks them rather than
    /// renaming them.
    var onDockLeft: (() -> Void)?
    var onDockRight: (() -> Void)?
    var onToggleDockMode: (() -> Void)?
    /// ADR-0007's dangerous one: reshapes the PTY for every client of the
    /// session. Whoever connects this owes the user a confirmation first.
    var onClaimSession: (() -> Void)?
    var onCloseLane: (() -> Void)?
    /// The header's `s | m | xl` switch and the menu's Small / Medium / Extra
    /// Large. The strip does the work; see `StripViewController.applySizePreset`.
    var onSizePreset: ((LaneSizePreset) -> Void)?
    /// The menu's Mobile Layout: every page in the lane asks its site for the
    /// phone layout, or stops. See `WebPaneController.setMobile`.
    var onToggleMobileLayout: (() -> Void)?
    /// What the tick beside it shows. Nil for a lane with no page.
    var mobileLayout: (() -> Bool?)?
    /// The menu's Block Ads on This Site: the blocker off for the site the
    /// lane's page is on, or on again. See `WebPaneController.toggleBlocking`.
    var onToggleBlocking: (() -> Void)?
    /// Its tick: true while ads are blocked on that site, false while they are
    /// let through, nil for a lane with no page or a blocker switched off.
    var blocking: (() -> Bool?)?

    /// The preset this lane is at, lit in the header; nil when it has been
    /// dragged or zoomed off all three. Derived by the strip, never stored.
    var sizePreset: LaneSizePreset? {
        didSet { header.sizePreset = sizePreset }
    }

    /// The presets are offered everywhere but a gallery tile, which writes
    /// nothing but the layout and focus. A docked lane takes them on its dock
    /// width. Whether the switch has *room* is the header's call at layout.
    private func updateSizeSwitchVisibility() {
        header.showsSizeSwitch = !isThumbnail
    }

    /// Whether the header offers the switch at all, for tests.
    var showsSizeSwitch: Bool { header.showsSizeSwitch }

    /// Whether the switch is actually on screen, room included, for tests.
    var sizeSwitchIsVisible: Bool { !header.sizeSwitch.isHidden }

    /// The `⋯` menu as it would open now, for tests.
    var overflowMenu: NSMenu { header.overflowMenu() }

    /// What the drag handle is currently asking for. The parent reads it during
    /// a live resize; the ledger only hears about it on the drop.
    private(set) var desiredWidth: CGFloat = 0
    /// An xl lane (span 2) may be twice as wide (PRD §13 Phase 3), so this is
    /// per lane rather than a constant.
    var widthBounds: ClosedRange<UInt32> = 420...900

    /// Which edge the width handle sits on.
    ///
    /// A lane in the strip is dragged by its right edge, because the strip
    /// grows rightwards and the lane's left edge is its neighbour's business. A
    /// dock at the right of the window has its right edge against the wall, so
    /// the only edge there is to grab is the other one — and it is the inner
    /// edge either way, which is the thing the gesture actually means.
    enum ResizeEdge { case trailing, leading }

    var resizeEdge: ResizeEdge = .trailing {
        didSet {
            guard resizeEdge != oldValue else { return }
            trailingHandle.isActive = resizeEdge == .trailing
            leadingHandle.isActive = resizeEdge == .leading
        }
    }

    private var trailingHandle: NSLayoutConstraint!
    private var leadingHandle: NSLayoutConstraint!

    /// Set when this lane is an **overlay** dock, to the edge of the window it
    /// is held at. `nil` for everything else, inset docks included.
    ///
    /// An overlay has to look like it is in front, or it reads as a lane that
    /// refuses to scroll — and the user's next move is to try to scroll it. The
    /// evidence is three things that agree: a hard, square, full-height rule
    /// down the inner edge (here), a shadow falling from that rule onto the
    /// strip (`DockShadowView`, which is the strip's to draw because it lands
    /// outside this view), and the strip itself visibly moving underneath. The
    /// third is the strongest and it is free; the first two are what make the
    /// still frame readable.
    ///
    /// An inset dock gets none of it, deliberately. It is *beside* the strip,
    /// not over it, and a shadow there would claim a depth that is not true.
    var floatingEdge: DockSide? {
        didSet {
            guard floatingEdge != oldValue else { return }
            dockEdge.isHidden = floatingEdge == nil
            needsLayout = true
        }
    }

    /// The mode this dock is actually drawn in, which is not always the mode
    /// the ledger holds — see `DockGeometry`'s narrow-window degradation. The
    /// header's marker follows this rather than the snapshot, so it never says
    /// "takes its own room" beside a dock that is visibly covering a lane.
    var drawnDockMode: DockMode? {
        didSet {
            guard drawnDockMode != oldValue else { return }
            header.drawnDockMode = drawnDockMode
        }
    }

    private let dockEdge = DockEdgeView()

    /// Which pane in this lane has the keyboard, so the lane can outline it.
    ///
    /// Handed the ledger's focused pane whoever it belongs to; a lane that does
    /// not recognise the id draws nothing, which is how "which lane" stays
    /// answered in one place.
    var focusedPaneId: String? {
        didSet {
            guard focusedPaneId != oldValue else { return }
            needsLayout = true
        }
    }

    /// The outline around the pane with the keyboard — see
    /// `PaneFocusOutlineView`. The one place focus is drawn in the accent.
    private let focusOutline = PaneFocusOutlineView()

    init(lane: Lane, widthBounds: ClosedRange<UInt32>) {
        self.laneId = lane.id
        self.widthBounds = widthBounds
        super.init(frame: .zero)

        wantsLayer = true
        layerBackgroundColor = Theme.laneBackground
        layerBorderColor = Theme.laneBorder
        layer?.borderWidth = Theme.borderWidth
        // Square. Explicitly, so nobody "improves" it later.
        layer?.cornerRadius = 0

        // Frame-positioned, deliberately. `StripContentView` lays lanes out by
        // summing widths (ADR-0004), so the lane's own frame is set from
        // outside. Leaving this false would hand placement to Auto Layout, which
        // has nothing pinning the height and collapses every lane to its header
        // — the whole strip becomes a row of 28pt bars with no panes in it.
        translatesAutoresizingMaskIntoConstraints = true
        frame.size.width = CGFloat(lane.widthPt)

        stack.orientation = .vertical
        // `.fill`, not `.fillEqually`: panes have individual heights now, and
        // this view owns them (see `applyPaneHeights`). `.fillEqually` would
        // install its own equal-height constraints and win, so the split would
        // be stored, read, computed — and then silently discarded at the last
        // step.
        stack.distribution = .fill
        // The gap between panes is the seam, and the seam is a thing you can
        // see and grab, so it is `PaneSplit.seam` wide rather than the single
        // point of lane background it used to be. The rule drawn inside it is
        // still `Theme.borderWidth`; the rest is hit area.
        stack.spacing = PaneSplit.seam
        // Panes have no intrinsic height, so without this the stack hugs them
        // to nothing and the height constraints below fight a hug they cannot
        // see the source of.
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(stack)
        addSubview(resizeHandle)
        // After the stack, for the reason `dockEdge` is added after everything:
        // a pane's view is layer-backed and paints over any sibling added
        // before it. Frame-positioned in `layOutFocusOutline`.
        focusOutline.isHidden = true
        addSubview(focusOutline)
        // Frame-positioned in `layout`, and hidden unless this lane is an
        // overlay dock. Added last so it is drawn over the pane it borders —
        // a `WKWebView` is layer-backed and will otherwise paint over a
        // sibling that was added before it.
        dockEdge.isHidden = true
        addSubview(dockEdge)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.laneHeaderHeight),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 10),
        ])
        trailingHandle = resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor)
        leadingHandle = resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingHandle.isActive = true

        resizeHandle.onDrag = { [weak self] delta, final in
            guard let self else { return }
            // A drag on the leading edge moves the same way and means the
            // opposite: pulling left widens a right-hand dock, because the edge
            // that is not moving is the one against the wall.
            let signed = self.resizeEdge == .leading ? -delta : delta
            let next = UInt32(max(Double(self.widthBounds.lowerBound),
                                  min(Double(self.widthBounds.upperBound),
                                      Double(self.desiredWidth) + signed)))
            self.desiredWidth = CGFloat(next)
            self.onResize?(next, final)
        }
        header.onDrag = { [weak self] point, final in self?.onLaneGrab?(point, final) }
        // The header reads the lane's callbacks through this at click time
        // rather than copying them: the strip connects them after `init`, and
        // reconnects them when it recycles this view onto a different lane. It
        // also lets the menu grey out an action nobody has connected.
        header.actions = self

        apply(lane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Adopt the latest session telemetry, so the header can show what the
    /// attached session is doing.
    func applyTelemetry(_ telemetry: [String: SessionTelemetry]) {
        let sessionId = currentSessionId
        header.telemetry = sessionId.flatMap { telemetry[$0] }
    }

    /// The Relay session this lane's first pty pane is attached to.
    var currentSessionId: String?

    /// Adopt a new snapshot of this lane. Called on every mutation that touches
    /// it, so it does the least work that produces the right result: the header
    /// is cheap to rebuild, the pane views are not and are reused by id.
    func apply(_ lane: Lane) {
        laneId = lane.id
        currentSessionId = lane.panes.first(where: { $0.kind == .pty })?.relaySessionId
        // A docked lane's handle drags the *dock's* width, which is a separate
        // durable number: undocking has to give the lane back at the width it
        // was dragged to in the strip, not at whatever the edge was last set to.
        desiredWidth = CGFloat(lane.dock?.widthPt ?? lane.widthPt)
        // Keyed by pane id and not by position: a snapshot can arrive while a
        // pane is still fading out of the stack, and an array indexed by
        // position would hand the departing pane's height to the one that took
        // its place.
        paneWeights = Dictionary(uniqueKeysWithValues: lane.panes.map { ($0.id, $0.heightWeight) })
        header.apply(lane)
        updateSizeSwitchVisibility()
        needsLayout = true
    }

    /// Install the view for a pane, or take one out. The lane owns arrangement;
    /// the caller owns what a pane view actually is, because a terminal and a
    /// web view have nothing in common but a rectangle.
    func setPaneView(_ view: NSView?, for paneId: String, at position: Int) {
        if let existing = paneViews[paneId] {
            guard existing !== view else { return }
            stack.removeArrangedSubview(existing)
            existing.removeFromSuperview()
            paneViews[paneId] = nil
            heightConstraints[paneId]?.isActive = false
            heightConstraints[paneId] = nil
            widthConstraints.removeValue(forKey: paneId)?.forEach { $0.isActive = false }
        }
        guard let view else { return }
        paneViews[paneId] = view
        let index = min(position, stack.arrangedSubviews.count)
        stack.insertArrangedSubview(view, at: index)

        // A vertical `NSStackView` aligns its arranged views `.centerX` by
        // default, which means "as wide as you want to be, in the middle". A
        // pane view with nothing intrinsic in it happens to come out full
        // width, so this cost nothing until the browser chrome bar put an
        // address field in a web pane's container — after which every web pane
        // was laid out at the *chrome's* fitting width and centred, with the
        // lane background showing either side of it. Measured: a 420 pt lane
        // holding a 167 pt page with 126 pt of gutter, and the number moved
        // with the length of the URL in the bar, because that is what the
        // fitting size was reading. It looked most like a bug in a dock,
        // where the page ran out of a column narrow enough to notice.
        //
        // Pinned rather than `alignment = .width`, which says the arranged
        // views match *each other* and leaves what they match the stack at to
        // the same defaults that caused this.
        for anchor in [
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ] {
            // 999 for the reason the height below is: a window mid-resize can
            // hand the stack a width narrower than the chrome bar's content
            // will compress to, and bending a point there beats breaking one of
            // these at random. Still above the 750 that intrinsic content
            // resists at, so the lane wins the argument that matters.
            anchor.priority = NSLayoutConstraint.Priority(999)
            anchor.isActive = true
            widthConstraints[paneId, default: []].append(anchor)
        }

        // 999, not required. The stack is pinned top and bottom, so these have
        // to add up to the lane exactly — and they do — but a window mid-resize
        // hands the stack a height for one pass that no set of constants was
        // computed against. At 999 that pass bends a point somewhere instead of
        // logging an unsatisfiable-constraints wall and breaking one at random.
        let height = view.heightAnchor.constraint(equalToConstant: 0)
        height.priority = NSLayoutConstraint.Priority(999)
        height.isActive = true
        heightConstraints[paneId] = height
        needsLayout = true
    }

    func paneView(for paneId: String) -> NSView? { paneViews[paneId] }

    var installedPaneIds: Set<String> { Set(paneViews.keys) }

    /// The installed panes in the order the stack actually has them, top to
    /// bottom.
    ///
    /// `installedPaneIds` answers "is this pane on screen", which is what a lane
    /// going away needs. A reconcile needs more than that: a pane can be
    /// installed and still be in the wrong place, and the set cannot tell you.
    var arrangedPaneIds: [String] {
        stack.arrangedSubviews.compactMap { view in
            paneViews.first { $0.value === view }?.key
        }
    }

    /// Put an already-installed pane view somewhere else in the stack.
    ///
    /// `removeArrangedSubview` takes a view out of the *arrangement* and leaves
    /// it a subview, so the view never leaves the window between the two calls.
    /// That distinction is the whole reason this is not "remove then install":
    /// unparenting a `WKWebView`, even for one turn of the run loop, costs its
    /// content process.
    func movePaneView(for paneId: String, to position: Int) {
        guard let view = paneViews[paneId],
              let current = stack.arrangedSubviews.firstIndex(of: view)
        else { return }
        let index = min(position, stack.arrangedSubviews.count - 1)
        guard index != current else { return }
        stack.removeArrangedSubview(view)
        stack.insertArrangedSubview(view, at: index)
    }

    /// Take a pane's view out with a bit of motion, and call back when the stack
    /// has closed over the gap.
    ///
    /// The pane fades while the stack collapses its slot, so the panes that stay
    /// grow into the space rather than jumping into it — after this you know
    /// which of the two terminals went, which a cut cannot tell you. The view is
    /// only unparented in the completion, so the caller's teardown still happens
    /// exactly once and at the end.
    ///
    /// `NSStackView` animates the collapse itself when `isHidden` is set through
    /// the animator proxy; `layoutSubtreeIfNeeded` inside the group is what
    /// makes the siblings travel instead of snapping at the end.
    func fadeOutPaneView(for paneId: String, duration: TimeInterval, completion: @escaping () -> Void) {
        guard let view = paneViews[paneId] else { return completion() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            view.animator().alphaValue = 0
            view.animator().isHidden = true
            // The heights the survivors grow into are worked out in `layout`,
            // so the lane has to be *asked* for one — `layoutSubtreeIfNeeded`
            // on its own does nothing when nothing has invalidated, and the
            // gap would close in a cut at the end instead of over the fade.
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        } completionHandler: {
            // Back to a usable state before it goes: a pane controller can
            // outlive its lane view (ADR-0004) and be parented again later, and
            // a view that comes back hidden and transparent looks like a bug in
            // the thing that brought it back.
            view.alphaValue = 1
            view.isHidden = false
            completion()
        }
    }

    /// A pane joining the stack: its slot opens out of the seam, the panes that
    /// were already there give up the height for it, and it fades up inside it.
    ///
    /// The exit is the shape to match, because a critic watching a recording
    /// judged it good: a closing pane collapses *into* the seam over 117 ms and
    /// you can see which one went. This is that, reversed — same seam, same
    /// direction of travel, opposite sign.
    ///
    /// **Why the arriving pane gets motion of its own after all.** The previous
    /// version moved only the incumbent, reasoning that a fresh shell is a black
    /// rectangle so animating it shows nothing. The reasoning was sound and the
    /// result was not: `NSStackView`'s own attach animation made the incumbent
    /// implode and reopen at half height in 167 ms while the new pane appeared
    /// at 85% of its final size in a single frame. Nobody can read that. So the
    /// stack no longer animates itself — `PaneSplit.opening` resolves every
    /// frame's heights and this drives it — and the newcomer is no longer
    /// invisible either: the seam it comes out of is lit for the length of the
    /// entrance, and a web pane now shows a dark first-paint panel with its host
    /// on it (`WebPaneController`) rather than nothing.
    ///
    /// Nothing is hidden at any point, so the caller can still give the new pane
    /// the keyboard in the same turn. A split that swallows its first keystroke
    /// would be worse than a split with no animation at all.
    func animatePaneViewIn(for paneId: String, duration: TimeInterval) {
        guard let view = paneViews[paneId] else { return }
        openingTimer?.cancel()
        // The first frame, now: a timer's first tick is a run loop away, and the
        // lane must never paint the finished split before the motion that
        // explains it.
        opening = (paneId, 0)
        view.alphaValue = 0
        litDivider = dividerIndex(opening: paneId)
        needsLayout = true
        layoutSubtreeIfNeeded()

        openingTimer = Motion.run(duration: duration) { [weak self, weak view] t in
            guard let self else { return }
            let eased = Motion.easeOut(t)
            self.opening = (paneId, eased)
            view?.alphaValue = eased
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        } completion: { [weak self, weak view] in
            guard let self else { return }
            self.opening = nil
            self.openingTimer = nil
            self.litDivider = nil
            view?.alphaValue = 1
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    /// The seam an arriving pane comes out of: the one between it and the
    /// neighbour that is giving up the room. For a pane joining at the top there
    /// is no seam above it, so it comes out of the one below.
    private func dividerIndex(opening paneId: String) -> Int? {
        guard let index = visiblePaneIds.firstIndex(of: paneId) else { return nil }
        return max(0, index - 1)
    }

    /// The seam an entrance is currently coming out of, lit while it runs.
    private var litDivider: Int?

    /// Remove every pane view, for when the lane scrolls far enough off-screen
    /// that the strip is recycling it.
    func clearPaneViews() {
        // Before the views go. An entrance left running would keep ticking
        // against a lane this view no longer represents, and would hand the
        // recycled chrome a lit seam and a half-open slot belonging to a pane
        // that is not in it.
        openingTimer?.cancel()
        openingTimer = nil
        opening = nil
        litDivider = nil
        for (_, view) in paneViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            // A pane controller outlives its lane view (ADR-0004) and can be
            // parented again later; one that was mid-entrance would come back
            // transparent, which looks like a bug in whatever brought it back.
            view.alphaValue = 1
        }
        paneViews.removeAll()
        for (_, constraint) in heightConstraints { constraint.isActive = false }
        heightConstraints.removeAll()
        // The weights go too. This view is on its way to the recycle pool and
        // will be handed a different lane; a seam left over from the last one
        // would be drawn against panes it knows nothing about.
        paneWeights.removeAll()
        draggedWeights = nil
        for divider in dividers { divider.isHidden = true }
        // And the handles, for the same reason: a grip left pointing at a pane
        // id this view no longer holds is a drag that moves somebody else.
        for grip in grips { grip.isHidden = true }
        gripPaneIds = []
        // And the outline, for the same reason: this chrome is going to the
        // pool and will come back holding a different lane's panes.
        focusedPaneId = nil
        focusOutline.isHidden = true
    }

    // MARK: - opening and closing

    /// How much of this lane is currently showing, in points, while its column
    /// is opening or closing. `nil` is the normal state: all of it.
    ///
    /// **This masks; it does not resize.** The obvious way to open a column is
    /// to animate the lane's width from zero, and it is wrong: the pane inside
    /// is live, so a 0.22s collapse walks a terminal down to one column and back
    /// thirteen times. Ghostty tears its surface down on a zero-width view —
    /// which is how a `maxpane run` lane arrived, logged
    /// `invalid view size=0.00x898.00`, and closed itself again before anyone
    /// could read it — and a terminal *does* have a far end, so re-deriving a
    /// grid mid-animation is ADR-0007's forbidden move on a session that may
    /// have a phone attached to it.
    ///
    /// The lane therefore keeps its real width the whole time and is revealed
    /// through a mask, while the strip gives its *slot* the animated width. The
    /// column still opens and the lanes beside it still move; nothing inside it
    /// is told anything happened.
    var revealWidth: CGFloat? {
        didSet {
            guard revealWidth != oldValue else { return }
            applyReveal()
        }
    }

    private func applyReveal() {
        guard let layer else { return }
        guard let width = revealWidth else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CALayer) ?? CALayer()
        // Frames set from a timer, so implicit animation would add a second,
        // slower animation on top of the one being driven — the mask would
        // always be chasing the slot instead of being it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: 0, y: 0, width: max(0, width), height: bounds.height)
        if layer.mask !== mask { layer.mask = mask }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // The mask is in the lane's own coordinates, so a strip that changed
        // height mid-transition would otherwise reveal a full-width lane through
        // a mask that is the old height.
        if revealWidth != nil { applyReveal() }
        if let edge = floatingEdge {
            // The inner edge: the one facing the strip. For a dock on the left
            // of the window that is its right-hand side, and the mirror at the
            // other end.
            let w = Theme.dockEdgeWidth
            dockEdge.frame = NSRect(
                x: edge == .left ? bounds.width - w : 0, y: 0, width: w, height: bounds.height)
        }
        applyPaneHeights()
    }

    // MARK: - how tall each pane is

    /// The panes the stack is actually showing, top to bottom.
    ///
    /// Hidden ones are excluded on purpose. A pane fading out of a stack is
    /// still an arranged subview for the length of its exit (`fadeOutPaneView`),
    /// and including it would keep its height reserved — the survivors would sit
    /// still and then jump when it finally went, which is precisely the cut that
    /// animation exists to remove.
    private var visiblePaneIds: [String] {
        stack.arrangedSubviews.filter { !$0.isHidden }.compactMap { view in
            paneViews.first { $0.value === view }?.key
        }
    }

    private func weight(of paneId: String) -> Double {
        draggedWeights?[paneId] ?? paneWeights[paneId] ?? 1
    }

    /// Resolve the weights into constraint constants and put the seams where
    /// the boundaries landed.
    ///
    /// Derived from the lane's own height rather than read back from the
    /// stack's frame: this runs inside `layout`, before the subtree has been
    /// laid out, so the stack's frame is still last pass's. The stack is pinned
    /// to the header's bottom and the lane's bottom, so its height is a fact
    /// about the lane and there is nothing to read.
    private func applyPaneHeights() {
        let ids = visiblePaneIds
        guard !ids.isEmpty else {
            for divider in dividers { divider.isHidden = true }
            for grip in grips { grip.isHidden = true }
            gripPaneIds = []
            focusOutline.isHidden = true
            return
        }

        let seams = CGFloat(ids.count - 1) * PaneSplit.seam
        let available = max(0, bounds.height - Theme.laneHeaderHeight - seams)
        let weights = ids.map(weight(of:))
        // `available` counts the finished number of seams even mid-entrance, so
        // the seam the new pane comes out of is drawn on the first frame rather
        // than arriving with it. See `PaneSplit.opening`.
        let heights: [CGFloat]
        if let opening, let index = ids.firstIndex(of: opening.paneId) {
            heights = PaneSplit.opening(
                weights: weights, arriving: index, progress: opening.progress, available: available)
        } else {
            heights = PaneSplit.heights(weights: weights, available: available)
        }

        // A pane that is not showing gets nought rather than an *inactive*
        // constraint. Activating and deactivating is a change to the constraint
        // graph, and a graph change made from inside `layout` is not guaranteed
        // to be solved in the same pass — which is exactly how ⇧⌘D put a third
        // pane in a lane that was still drawing two. A constant is solved every
        // time.
        let wanted = Dictionary(uniqueKeysWithValues: zip(ids, heights))
        for (id, constraint) in heightConstraints {
            let height = wanted[id] ?? 0
            // Half a point of hysteresis. These are set from inside `layout`,
            // which marks the view as needing layout again; without a guard
            // that is a pass every frame forever rather than one pass that
            // settles.
            if abs(constraint.constant - height) > 0.5 { constraint.constant = height }
        }

        layOutDividers(above: heights)
        layOutFocusOutline(ids: ids, heights: heights)
        layOutGrips(ids: ids, heights: heights)
    }

    /// Put a grip at the top-left of every pane's slot.
    ///
    /// Measured downward from the top of the pane area exactly as the seams and
    /// the focus mark are, so the three cannot drift apart — a handle a seam
    /// away from the pane it picks up would pick up the wrong one.
    private func layOutGrips(ids: [String], heights: [CGFloat]) {
        gripPaneIds = ids
        while grips.count < ids.count {
            let grip = PaneGripView(frame: .zero)
            let slot = grips.count
            grip.onDrag = { [weak self] point, isFinal in
                guard let self, self.gripPaneIds.indices.contains(slot) else { return }
                self.onPaneGrab?(self.gripPaneIds[slot], point, isFinal)
            }
            grip.onClick = { [weak self] in
                guard let self, self.gripPaneIds.indices.contains(slot) else { return }
                self.onFocusPane?(self.gripPaneIds[slot])
            }
            // Below the width handle for the reason the seams are: the two
            // overlap in no corner today, and the lane's edge has to keep
            // winning if they ever do.
            addSubview(grip, positioned: .below, relativeTo: resizeHandle)
            grips.append(grip)
        }

        let size = PaneGripView.size
        let top = bounds.height - Theme.laneHeaderHeight
        for (slot, grip) in grips.enumerated() {
            guard slot < ids.count else {
                grip.isHidden = true
                continue
            }
            // A lane of one pane is picked up by its header, which is that
            // pane's handle too, so its corner goes back to the terminal.
            grip.isHidden = isThumbnail || ids.count < 2
            let paneTop = top - PaneSplit.top(ofPaneAt: slot, heights: heights)
            let frame = NSRect(
                x: PaneGripView.insetX,
                y: paneTop - PaneGripView.insetY - size.height,
                width: size.width, height: size.height)
            guard grip.frame != frame else { continue }
            // No implicit animation: this is set from inside `layout`, and an
            // eased handle would trail the seam it sits under during a drag.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            grip.frame = frame
            CATransaction.commit()
            window?.invalidateCursorRects(for: grip)
            grip.pointerMayHaveLeft()
        }
    }

    /// Put the focus outline around the focused pane's slot.
    ///
    /// Every lane is handed the same id and only the lane holding that pane
    /// draws anything, which is how "which lane" stays answered in one place.
    /// There is no one-pane exception any more: the lane's border no longer
    /// means focus, so a lane of one pane that skipped the outline would show
    /// no focus at all.
    private func layOutFocusOutline(ids: [String], heights: [CGFloat]) {
        guard let paneId = focusedPaneId,
              let index = ids.firstIndex(of: paneId),
              // Measured from the same heights the seams are placed from, so
              // the outline and the seam beside it cannot drift apart.
              let frame = PaneSplit.focusOutline(ofPaneAt: index, heights: heights, laneSize: bounds.size)
        else {
            focusOutline.isHidden = true
            return
        }
        focusOutline.isHidden = false
        guard focusOutline.frame != frame else { return }
        // No implicit animation, for the reason a seam takes none: this is set
        // from inside `layout`, and an eased outline would trail every drag of
        // the seam it sits against.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusOutline.frame = frame
        CATransaction.commit()
    }

    /// Put a seam in each gap between two visible panes.
    ///
    /// Positioned by summing heights, exactly as the strip positions lanes by
    /// summing widths (ADR-0004) and for the same reason: the alternative is
    /// reading sibling frames that this pass has not set yet.
    private func layOutDividers(above heights: [CGFloat]) {
        let wanted = max(0, heights.count - 1)
        while dividers.count < wanted {
            let divider = PaneDividerView(frame: .zero)
            let index = dividers.count
            divider.onDrag = { [weak self] delta, isFinal in
                self?.seamDragged(at: index, by: delta, isFinal: isFinal)
            }
            // Below the width handle: the two overlap in the bottom-right
            // corner, and the lane's edge has to win there or a lane can be
            // made narrow but never wide again.
            addSubview(divider, positioned: .below, relativeTo: resizeHandle)
            dividers.append(divider)
        }

        var offset: CGFloat = 0
        let top = bounds.height - Theme.laneHeaderHeight
        for (index, divider) in dividers.enumerated() {
            guard index < wanted else {
                divider.isHidden = true
                continue
            }
            offset += heights[index]
            divider.isHidden = false
            divider.isOpening = index == litDivider
            // Centred on the gap and taller than it, so the grab area reaches a
            // few points into each neighbour. The seam it draws is still
            // exactly the gap.
            let frame = NSRect(
                x: 0, y: top - offset - (PaneSplit.seam + PaneSplit.grab) / 2,
                width: bounds.width, height: PaneSplit.grab)
            guard divider.frame != frame else {
                offset += PaneSplit.seam
                continue
            }
            // No implicit animation. A seam is set from `layout`, which runs
            // once per drag event; a quarter-second ease on each one would put
            // the line permanently behind the pointer that is dragging it.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            divider.frame = frame
            CATransaction.commit()
            window?.invalidateCursorRects(for: divider)
            // The seam just moved, and a seam that moves out from under the
            // pointer is not told so. See `pointerMayHaveLeft`.
            divider.pointerMayHaveLeft()
            offset += PaneSplit.seam
        }
    }

    /// The user moved a seam.
    ///
    /// The lane keeps its own answer for as long as the mouse is down and drops
    /// it the moment the ledger has one — `onPaneHeights` writes synchronously
    /// and the snapshot comes back through `apply` inside that call, so there is
    /// no frame where neither is in charge. Clearing *before* the callback is
    /// what makes a failed write snap back to the truth instead of leaving the
    /// screen showing a split nobody stored.
    private func seamDragged(at index: Int, by delta: CGFloat, isFinal: Bool) {
        // A tile's proportions are the lane's, and moving them from a thumbnail
        // would be a height write from a view that promises to write none.
        guard !isThumbnail else { return }
        let ids = visiblePaneIds
        guard ids.indices.contains(index), ids.indices.contains(index + 1) else { return }

        let seams = CGFloat(ids.count - 1) * PaneSplit.seam
        let available = max(0, bounds.height - Theme.laneHeaderHeight - seams)
        let next = PaneSplit.drag(
            weights: ids.map(weight(of:)), divider: index, delta: delta, available: available)

        let changed = [
            (paneId: ids[index], weight: next[index]),
            (paneId: ids[index + 1], weight: next[index + 1]),
        ]
        if isFinal {
            draggedWeights = nil
        } else {
            var live = draggedWeights ?? [:]
            for pair in changed { live[pair.paneId] = pair.weight }
            draggedWeights = live
        }
        needsLayout = true
        // Synchronously, so the seam is under the pointer in this event and not
        // in the next run-loop turn. A divider that trails the mouse by a frame
        // reads as the drag not having taken, which is how the lane's own width
        // handle behaved before it laid out live.
        if !isFinal { layoutSubtreeIfNeeded() }
        onPaneHeights?(changed, isFinal)
    }

    // MARK: - as a gallery tile

    /// The scale this lane is drawn at while it is a gallery tile; nil on the
    /// strip.
    ///
    /// A tile is the lane itself, shrunk, so it keeps everything that says what
    /// the lane is and loses every handle that would change it: the gallery is
    /// a view over the strip and writes nothing but the layout and focus. No
    /// width handle, no grips, no seam drags.
    ///
    /// The focus outline is the one thing drawn *thicker* in lane points, so
    /// that it lands on screen at the weight it has on the strip. Shrunk with
    /// everything else, 2 pt at a scale of 0.4 is 0.8 pt — on a 1× panel, less
    /// than a pixel, which is an outline that is there in principle.
    var thumbnailScale: CGFloat? {
        didSet {
            guard thumbnailScale != oldValue else { return }
            resizeHandle.isHidden = isThumbnail
            updateSizeSwitchVisibility()
            let scale = min(1, max(thumbnailScale ?? 1, 0.05))
            focusOutline.layer?.borderWidth = PaneFocusOutlineView.width / scale
            needsLayout = true
        }
    }

    var isThumbnail: Bool { thumbnailScale != nil }

    // MARK: - focus and flash

    /// Whether this lane holds the focused pane. It lifts the header and leaves
    /// the border alone: the accent belongs to the pane, drawn by
    /// `focusOutline`, and a lane lit around a pane that was not the one being
    /// typed into is the bug that moved it there.
    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            header.isFocused = isFocused
        }
    }

    /// PRD §7.5 — "flash the lane border 300 ms" after search-to-scroll, so the
    /// eye lands on the lane the strip just scrolled to.
    ///
    /// It settles back to the neutral hairline even on the focused lane. A
    /// flash says where to look; the outline on the pane says where keys go.
    func flash() {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "borderColor")
        // Snapshots, taken now, in this lane's appearance: an animation's
        // endpoints are fixed for its 300 ms, and the layer's own border — which
        // it settles back onto — is the one that follows a switch.
        animation.fromValue = Theme.accent.cgColor(in: effectiveAppearance)
        animation.toValue = Theme.laneBorder.cgColor(in: effectiveAppearance)
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let width = CABasicAnimation(keyPath: "borderWidth")
        width.fromValue = 3
        width.toValue = Theme.borderWidth
        width.duration = 0.3

        layer.add(animation, forKey: "flashColor")
        layer.add(width, forKey: "flashWidth")
    }
}

/// What the header's overflow menu can ask of the lane it sits on.
///
/// A protocol rather than five copied closures so the menu can tell the
/// difference between "this action is not connected" and "this action does
/// nothing", and grey the item out in the first case.
@MainActor
protocol LaneHeaderActions: AnyObject {
    var onTogglePin: (() -> Void)? { get }
    var onSetProjectTag: (() -> Void)? { get }
    var onDockLeft: (() -> Void)? { get }
    var onDockRight: (() -> Void)? { get }
    var onToggleDockMode: (() -> Void)? { get }
    var onClaimSession: (() -> Void)? { get }
    var onCloseLane: (() -> Void)? { get }
    var onSizePreset: ((LaneSizePreset) -> Void)? { get }
    var onToggleMobileLayout: (() -> Void)? { get }
    /// Whether the lane's pages are on their phone layout, or nil for a lane
    /// with no page to ask. Asked when the menu opens, like `sizePreset`,
    /// because the toggle writes no snapshot.
    var mobileLayout: (() -> Bool?)? { get }
    var onToggleBlocking: (() -> Void)? { get }
    var blocking: (() -> Bool?)? { get }
}

extension LaneView: LaneHeaderActions {}

/// The lane's top strip — and the whole of a pane's chrome.
///
/// Left to right: a status square, the kind glyph, the agent-state glyph, the
/// pin marker, the title; then right-aligned, a throughput/age badge, the
/// working directory, and the overflow menu. That is the bar's header plus the
/// kind glyph, in Max Pane's vocabulary: squares rather than dots, one accent
/// rather than a palette, and a hard rule under it rather than a rounded band.
///
/// Laid out by hand rather than with constraints, for two reasons. The
/// truncation policy — the path gives way to the title down to a floor, then
/// both truncate, and the badge leaves before either does — is not expressible
/// in compression priorities. And this row is re-laid for every visible lane on
/// every telemetry tick; at 150 lanes the constraint solver is not worth
/// inviting.
@MainActor
final class LaneHeaderView: NSView {
    private let kindGlyph = NSTextField(labelWithString: "")
    private let chip = PulseLabel(labelWithString: "")
    private let markers = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let overflow = LaneHeaderMenuButton()
    /// `s | m | xl`. Internal rather than private so tests can press it.
    let sizeSwitch = LaneSizeSwitch()

    /// The preset to light, or nil for none.
    var sizePreset: LaneSizePreset? {
        get { sizeSwitch.selected }
        set { sizeSwitch.selected = newValue }
    }

    /// False on a gallery tile. See `LaneView.updateSizeSwitchVisibility`. The
    /// menu's size items are enabled on the same condition, and are there
    /// whether or not the switch has room.
    var showsSizeSwitch = true {
        didSet {
            guard showsSizeSwitch != oldValue else { return }
            needsLayout = true
        }
    }

    /// Below this the header has no room to spare for the switch and gives it
    /// back to the title and path. Every preset is wider — `s` is ~400 pt — so
    /// it only ever goes on a lane dragged or configured narrower than those.
    static let sizeSwitchMinWidth: CGFloat = 300

    var onDoubleClick: (() -> Void)?
    /// `(where the pointer is, in window coordinates; isFinal)`. Window
    /// coordinates because the header is not always on the strip: in a gallery
    /// tile it is under a transform, and whoever decides the drop converts into
    /// whichever surface the lane is drawn on.
    var onDrag: ((NSPoint, Bool) -> Void)?

    /// How far a press has to travel before it is a drag. Without it a click
    /// that twitches a point is a drag, and a drag draws a drop indicator over
    /// the lane you only meant to click.
    static let dragThreshold: CGFloat = 4

    /// The lane, for the overflow menu's actions. Weak and read at click time:
    /// the owner connects its callbacks after the header exists, and a nil
    /// callback greys its item out instead of crashing.
    weak var actions: (any LaneHeaderActions)?

    /// What the attached session is doing, when there is one. Set on every
    /// registry tick — once a second, so "6s" can become "7s" — which is why
    /// `rebuild` compares the rendered model rather than the telemetry: the
    /// value is unchanged on most ticks but the age it prints is not.
    var telemetry: SessionTelemetry? { didSet { rebuild() } }

    /// See `LaneView.drawnDockMode`. Held rather than folded into the model
    /// because it comes from the window's arithmetic, not from the snapshot,
    /// and `rebuild` compares models to decide whether to touch the tree.
    var drawnDockMode: DockMode? {
        didSet {
            guard drawnDockMode != oldValue else { return }
            applyMarkers()
        }
    }

    private var lane: Lane?
    private var model = LaneHeaderModel()
    /// Where the press that may become a drag went down, in the window.
    private var pressedAt: NSPoint?
    private var dragging = false
    private var statusSquare = NSRect.zero

    /// JetBrains Mono is monospaced, so one measurement is the whole metric: how
    /// many characters fit in a field is width ÷ this, exactly. The path and the
    /// badge sit a point smaller than the title — they are reference material,
    /// not the headline — so they have their own cell width, and mixing the two
    /// up costs the path a character in every lane.
    private static let font = Theme.mono(11)
    private static let smallFont = Theme.mono(10)
    private static let advance: CGFloat = cellWidth(of: font)
    private static let smallAdvance: CGFloat = cellWidth(of: smallFont)

    private static func cellWidth(of font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private let leftInset: CGFloat = 8
    /// Clears the 6pt resize handle that sits on top of the lane's right edge.
    private let rightInset: CGFloat = 8
    private let gap: CGFloat = 8
    private let overflowWidth: CGFloat = 18

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            title.textColor = isFocused ? .labelColor : Theme.dimText
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerBackgroundColor = NSColor.clear

        kindGlyph.font = Theme.mono(11, weight: .medium)
        chip.alignment = .center
        chip.wantsLayer = true
        // Square, like everything else. A chip with a radius is a pill, and a
        // pill is the RelayTTY card this app deliberately is not.
        chip.layer?.cornerRadius = 0
        title.font = Self.font
        title.lineBreakMode = .byTruncatingTail
        title.textColor = Theme.dimText
        badge.font = Self.smallFont
        badge.alignment = .right
        // The path is pre-fitted by `LaneHeaderPath`, which drops whole
        // components; AppKit's own tail truncation would undo that decision.
        path.font = Self.smallFont
        path.textColor = Theme.dimText
        path.alignment = .right
        path.lineBreakMode = .byClipping
        markers.font = Self.smallFont
        markers.alignment = .center
        // Neutral, not accent. Both markers are structural — this lane is never
        // evicted, this lane is held at an edge — and neither changes from
        // minute to minute. A green mark for something that is true all day
        // would blur the greens that have to keep meaning focus and state.
        markers.textColor = .labelColor

        overflow.onPress = { [weak self] in self?.showOverflowMenu() }
        sizeSwitch.onPick = { [weak self] preset in self?.actions?.onSizePreset?(preset) }

        for v in [kindGlyph, chip, markers, title, badge, path, sizeSwitch] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        overflow.translatesAutoresizingMaskIntoConstraints = true
        addSubview(overflow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func apply(_ lane: Lane) {
        self.lane = lane
        rebuild()
    }

    // MARK: - content

    private func rebuild() {
        guard let lane else { return }
        let next = LaneHeaderModel(lane: lane, telemetry: telemetry)
        guard next != model else { return }
        // The chip and the badge change meaning in place; ease it rather than
        // cut. Not on an age tick, which changes the text and nothing else.
        if next.state != model.state || next.badgeIsThroughput != model.badgeIsThroughput {
            Motion.fade(layer)
        }
        model = next

        kindGlyph.stringValue = Theme.glyph(for: model.kind)
        // The green $ marks a live terminal and nothing else. The muted green,
        // not the accent: every terminal lane carries this glyph, so the louder
        // shade would be spent on the most routine state there is.
        kindGlyph.textColor = (model.kind == .pty && model.isLive) ? Theme.working : Theme.dimText
        applyChip()
        applyMarkers()
        title.stringValue = model.title
        badge.stringValue = model.badge
        // Throughput is the thing that is changing right now, so it gets the
        // working green; a quiet lane's age is reference material and stays dim.
        badge.textColor = model.badgeIsThroughput ? Theme.working : Theme.dimText
        toolTip = model.tooltip.isEmpty ? nil : model.tooltip

        needsLayout = true
        needsDisplay = true
    }

    private func applyMarkers() {
        let text = model.markerText(drawnMode: drawnDockMode)
        guard markers.stringValue != text else { return }
        markers.stringValue = text
        needsLayout = true
        needsDisplay = true
    }

    /// The agent-state chip: `BLOCKED`, `WORKING`, `DONE`, `EXITED`, and nothing
    /// at all for idle and unknown. RelayTTY renders nothing for those two and
    /// is right to — a chip on every header is a chip nobody reads, and this one
    /// has to survive being one of ten.
    ///
    /// **Blocked is filled and moving; focus is an outline.** Focus and BLOCKED
    /// are both green (ADR-0015), so they must differ by channel, not hue:
    /// attention is a solid block of the brightest green *inside* the header,
    /// pulsing, with a word in it; focus is a hairline *around* the pane below.
    /// A focused idle lane has no green block anywhere in its header; a blocked
    /// unfocused lane has a grey outline and a bright block. The focused header
    /// therefore gets a neutral lift rather than an accent wash — a tinted
    /// header on a focused idle lane was exactly the collision.
    private func applyChip() {
        guard let state = model.state, state.hasChip else {
            chip.isPulsing = false
            chip.layerBackgroundColor = NSColor.clear
            if model.isPrivate {
                // The one chip a web lane can wear. Grey, outlined, and a word:
                // the same shape as a state chip so it reads in the same
                // column, in the resting colour so it never competes with a
                // BLOCKED two lanes over.
                chip.stringValue = chipFits ? "PRIVATE" : "P"
                chip.font = Theme.mono(9, weight: .bold)
                chip.layerBorderColor = Theme.dimText.withAlphaComponent(0.6)
                chip.layer?.borderWidth = 1
                chip.textColor = Theme.dimText
                return
            }
            chip.stringValue = ""
            chip.layer?.borderWidth = 0
            return
        }
        let colour = Theme.agentStateColor(state)
        let blocked = state == .blocked
        chip.stringValue = chipFits ? state.chipText : state.glyph
        chip.font = chipFits ? Theme.mono(9, weight: .bold) : Theme.mono(11, weight: .bold)
        if blocked {
            // The only filled thing in the header, because it is the only thing
            // worth interrupting someone for — and filled at a glyph's width as
            // well as a word's, so under Reduce Motion, where it cannot pulse,
            // `!` is still a bright block rather than one more green character.
            chip.layerBackgroundColor = colour
            chip.layer?.borderWidth = 0
            chip.textColor = Theme.onBlocked
        } else if chipFits {
            chip.layerBackgroundColor = NSColor.clear
            chip.layerBorderColor = colour.withAlphaComponent(0.6)
            chip.layer?.borderWidth = 1
            chip.textColor = colour
        } else {
            // Too narrow for a word. The glyph keeps the colour and the meaning
            // and costs one cell.
            chip.layerBackgroundColor = NSColor.clear
            chip.layer?.borderWidth = 0
            chip.textColor = colour
        }
        chip.isPulsing = blocked
    }

    /// Whether the header's blocked mark is breathing right now, for tests.
    var isBlockedMarkPulsing: Bool { chip.isAnimatingPulse }

    /// Whether the last layout had room for words rather than a glyph. Decided
    /// in `layout`, because it depends on what the title and path need.
    private var chipFits = true

    // MARK: - layout

    override func layout() {
        super.layout()
        let advance = Self.advance
        let mid = bounds.midY

        var x = leftInset
        let square: CGFloat = 7
        statusSquare = NSRect(x: x, y: (bounds.height - square) / 2, width: square, height: square)
        x += square + 6

        let cell = ceil(advance)
        kindGlyph.frame = NSRect(x: x, y: mid - 8, width: cell + 2, height: 16)
        x += cell + 2

        let overflowX = bounds.width - rightInset - overflowWidth
        overflow.frame = NSRect(x: overflowX, y: (bounds.height - 18) / 2, width: overflowWidth, height: 18)

        var rightEdge = overflowX - 6
        // The markers sit beside the `⋯` that toggles them rather than beside
        // the status square, which is also a small green square: three squares
        // in a row on the left read as one indicator with a bug in it.
        if !markers.stringValue.isEmpty {
            // Measured rather than assumed to be one cell each: `▪` and `◀` are
            // not in JetBrains Mono, so they come from a fallback face at their
            // own widths and a fixed box clips them away to nothing.
            let markerWidth = width(of: markers.stringValue, font: Self.smallFont) + 2
            markers.frame = NSRect(x: rightEdge - markerWidth, y: mid - 8, width: markerWidth, height: 16)
            rightEdge -= markerWidth + 6
        } else {
            markers.frame = NSRect(x: rightEdge, y: mid - 8, width: 0, height: 16)
        }
        // The size switch sits outside the markers, so the markers stay beside
        // the `⋯` that toggles them, and at the same x on every lane of a width.
        let wantsSwitch = showsSizeSwitch && bounds.width >= Self.sizeSwitchMinWidth
        sizeSwitch.isHidden = !wantsSwitch
        if wantsSwitch {
            let switchWidth = sizeSwitch.fittingWidth
            sizeSwitch.frame = NSRect(
                x: rightEdge - switchWidth, y: ((bounds.height - LaneSizeSwitch.height) / 2).rounded(),
                width: switchWidth, height: LaneSizeSwitch.height)
            rightEdge -= switchWidth + 8
        }
        // The chip sits at a fixed x on every lane, so a strip of ten headers
        // has one column your eye runs along rather than ten places to look.
        let chipX = x
        var chipWidth: CGFloat = 0
        if let state = model.state, state.hasChip {
            let wordWidth = width(of: state.chipText, font: Theme.mono(9, weight: .bold)) + 10
            let glyphWidth = cell + 4
            // Words when the title and the path can still both be read beside
            // them; a coloured glyph when they cannot.
            let roomForWords = rightEdge - x - wordWidth - gap
                >= min(width(of: model.title, font: Self.font), advance * 10) + Self.smallAdvance * 12
            chipFits = roomForWords
            chipWidth = roomForWords ? wordWidth : glyphWidth
            applyChip()
            chip.frame = NSRect(x: chipX, y: mid - 7, width: chipWidth, height: 14)
            x += chipWidth + 6
        } else {
            // A lane with nothing to report gets the space back rather than a
            // placeholder that means nothing.
            chip.frame = NSRect(x: chipX, y: mid - 7, width: 0, height: 14)
        }

        let available = max(0, rightEdge - x)

        let titleWanted = width(of: model.title, font: Self.font)
        let pathWanted = width(of: LaneHeaderPath.abbreviate(model.path), font: Self.smallFont)
        let badgeWanted = model.badge.isEmpty ? 0 : width(of: model.badge, font: Self.smallFont)

        // The badge is the first thing to go: it is the only field whose
        // information is also in the sidebar, and losing it keeps the title and
        // the path — which exist nowhere else — legible for longer.
        let showBadge = badgeWanted > 0
            && available >= titleWanted + pathWanted + badgeWanted + gap * 3
        let reserved = showBadge ? badgeWanted + gap : 0
        let forTitleAndPath = max(0, available - reserved - gap)

        // The path yields to the title first, but only down to a floor of about
        // twelve characters — below that it stops being an identifier and
        // becomes decoration, and the title can start truncating instead.
        let pathFloor = min(pathWanted, Self.smallAdvance * 12)
        var pathBudget = min(pathWanted, max(forTitleAndPath - titleWanted, pathFloor))
        // ...and the title always keeps six characters, so a pathological path
        // can never erase it entirely.
        pathBudget = min(pathBudget, max(0, forTitleAndPath - advance * 6))

        let fitted = LaneHeaderPath.fit(
            model.path, maxChars: Int((pathBudget / Self.smallAdvance).rounded(.down)))
        path.stringValue = fitted
        // Dropping a whole component can leave the field wider than the string
        // that ended up in it. Hand the slack back to the title rather than
        // parking it between the badge and the path, where it reads as a column
        // that is not there.
        let pathWidth = min(pathBudget, width(of: fitted, font: Self.smallFont))
        let titleWidth = max(0, forTitleAndPath - pathWidth)

        title.frame = NSRect(x: x, y: mid - 9, width: titleWidth, height: 18)
        badge.frame = NSRect(
            x: rightEdge - pathWidth - reserved, y: mid - 8,
            width: showBadge ? badgeWanted : 0, height: 16)
        badge.isHidden = !showBadge
        path.frame = NSRect(x: rightEdge - pathWidth, y: mid - 8, width: pathWidth, height: 16)

        // The status square is drawn, not a subview, and its rect is only known
        // here. Without this a lane that lays out after its first `draw` — every
        // freshly materialised lane, as it happens — paints the square at
        // `.zero` and never repaints it, so the one indicator the header exists
        // for is simply missing.
        needsDisplay = true
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // A neutral lift, deliberately not an accent wash. The accent belongs to
        // the focused pane's outline; tinting the header green as well would
        // make a focused idle lane look like a blocked one, and blocked is the
        // only thing in this app allowed a filled green block. The lift is what
        // says *which column* now that the lane's border no longer does.
        if isFocused {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            bounds.fill()
        }

        // Liveness, as a square — the bar's green dot, in a vocabulary with no
        // round corners. Filled means running; outlined means gone, and the chip
        // beside it says how.
        //
        // The muted green, not the accent or the blocked green, and this is the
        // point: every live lane carries this mark, and a shade that appears on
        // all ten lanes cannot also mean "this one needs you". The colour is the
        // theme's `working` role rather than a new one invented here.
        if model.isLive {
            Theme.agentStateColor(.working).setFill()
            statusSquare.fill()
        } else {
            Theme.dimText.setStroke()
            let inset = statusSquare.insetBy(dx: 0.5, dy: 0.5)
            let box = NSBezierPath(rect: inset)
            box.lineWidth = 1
            box.stroke()
        }

        // A hairline under the header, full width. A rule, not a rounded band.
        (isFocused ? NSColor.labelColor.withAlphaComponent(0.35) : Theme.laneBorder).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth).fill()
    }

    // MARK: - overflow menu

    /// Right-clicking anywhere in the header opens the same menu the `⋯` does —
    /// the button is the discoverable path, the right-click is the fast one.
    override func menu(for event: NSEvent) -> NSMenu? { overflowMenu() }

    private func showOverflowMenu() {
        overflowMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: overflow.bounds.height + 2),
            in: overflow)
    }

    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Titles and keys come from `Command` so this menu cannot drift from the
        // menu bar, and so it teaches the shortcut rather than replacing it.
        add(to: menu, model.keepLive ? "Stop Keeping Loaded" : Command.toggleKeepLive.title,
            command: .toggleKeepLive, action: #selector(menuTogglePin), enabled: actions?.onTogglePin != nil)
        add(to: menu, "Set Project Tag…",
            command: nil, action: #selector(menuSetProjectTag), enabled: actions?.onSetProjectTag != nil)

        // The size presets, always: the header's switch gives way on a narrow
        // lane, and a lane is never too narrow for its menu. Ticked like the
        // docking items below, and none ticked when the lane is off all three.
        // They replaced Span Lane (2× Width), which xl covers.
        menu.addItem(.separator())
        for preset in LaneSizePreset.allCases {
            let item = add(to: menu, preset.title,
                command: preset.command, action: #selector(menuSizePreset(_:)),
                enabled: showsSizeSwitch && actions?.onSizePreset != nil,
                state: sizePreset == preset ? .on : .off)
            item.representedObject = preset.rawValue
        }
        // The fourth shape a lane can take: the site's phone layout, which is
        // what a portrait column is to a site that draws one layout per device.
        // Greyed out, not hidden, on a terminal lane — the menu keeps its
        // shape from lane to lane, and grey says why the item is not for this
        // one. Ticked from the panes, which are the only ones who know.
        let mobile = actions?.mobileLayout?()
        add(to: menu, Command.toggleMobileLayout.title,
            command: .toggleMobileLayout, action: #selector(menuToggleMobileLayout),
            enabled: mobile != nil && actions?.onToggleMobileLayout != nil,
            state: mobile == true ? .on : .off)
        // The blocker, for the site this lane's page is on. Ticked while it
        // blocks, so the common state reads as a tick and the exception as its
        // absence — the chrome bar's chip carries the exception too.
        let blocking = actions?.blocking?()
        add(to: menu, Command.toggleBlocking.title,
            command: .toggleBlocking, action: #selector(menuToggleBlocking),
            enabled: blocking != nil && actions?.onToggleBlocking != nil,
            state: blocking == true ? .on : .off)

        menu.addItem(.separator())
        // Checkmarks rather than three verbs. Docking is a toggle on the keys,
        // and a menu that said "Dock Left" then "Undock" would make the state
        // something you infer from the label instead of something you read off
        // the tick — on a lane that is already visibly at an edge.
        add(to: menu, Command.dockLaneLeft.title,
            command: .dockLaneLeft, action: #selector(menuDockLeft),
            enabled: actions?.onDockLeft != nil, state: model.dock?.side == .left ? .on : .off)
        add(to: menu, Command.dockLaneRight.title,
            command: .dockLaneRight, action: #selector(menuDockRight),
            enabled: actions?.onDockRight != nil, state: model.dock?.side == .right ? .on : .off)
        // A mode is a property of a dock, so a lane that is not docked has
        // none. Greying it out is how the menu says which of the two questions
        // this key answers — the same rule `canPerform` applies to ⌃⌘\.
        add(to: menu, Command.toggleDockMode.title,
            command: .toggleDockMode, action: #selector(menuToggleDockMode),
            enabled: model.dock != nil && actions?.onToggleDockMode != nil,
            state: model.dock?.mode == .overlay ? .on : .off)

        menu.addItem(.separator())
        add(to: menu, "Copy Working Directory",
            command: nil, action: #selector(menuCopyPath), enabled: !model.path.isEmpty)

        if model.isTerminal {
            menu.addItem(.separator())
            // ADR-0007: this reshapes the PTY for every other client attached to
            // the session, including a phone. It is last, alone, and behind a
            // confirmation, which is the whole point.
            add(to: menu, Command.claimSession.title,
                command: .claimSession, action: #selector(menuClaimSession),
                enabled: actions?.onClaimSession != nil)
        }

        menu.addItem(.separator())
        add(to: menu, Command.closeLane.title,
            command: .closeLane, action: #selector(menuCloseLane), enabled: actions?.onCloseLane != nil)
        return menu
    }

    @discardableResult
    private func add(
        to menu: NSMenu, _ title: String, command: Command?, action: Selector,
        enabled: Bool, state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        if let chord = command?.menuChord {
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.modifiers
        }
        item.target = self
        item.isEnabled = enabled
        item.state = state
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.mono(12),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ])
        return item
    }

    @objc private func menuTogglePin() { actions?.onTogglePin?() }
    @objc private func menuSetProjectTag() { actions?.onSetProjectTag?() }
    @objc private func menuSizePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = LaneSizePreset(rawValue: raw) else { return }
        actions?.onSizePreset?(preset)
    }
    @objc private func menuToggleMobileLayout() { actions?.onToggleMobileLayout?() }
    @objc private func menuToggleBlocking() { actions?.onToggleBlocking?() }
    @objc private func menuDockLeft() { actions?.onDockLeft?() }
    @objc private func menuDockRight() { actions?.onDockRight?() }
    @objc private func menuToggleDockMode() { actions?.onToggleDockMode?() }
    @objc private func menuClaimSession() { actions?.onClaimSession?() }
    @objc private func menuCloseLane() { actions?.onCloseLane?() }

    /// No callback needed: the header already holds the only untruncated copy of
    /// the path in the UI, so it may as well be the thing that hands it over.
    @objc private func menuCopyPath() {
        guard !model.path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path, forType: .string)
    }

    // MARK: - dragging

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // The `⋯` and the size switch are subviews that take their own
    // mouse-down, so a press on either never reaches these: the header is a
    // handle everywhere except over its buttons.
    override func mouseDown(with event: NSEvent) {
        dragging = false
        if event.clickCount == 2 {
            pressedAt = nil
            onDoubleClick?()
        } else {
            pressedAt = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let point = event.locationInWindow
        if !dragging {
            guard hypot(point.x - pressedAt.x, point.y - pressedAt.y) >= Self.dragThreshold else { return }
            dragging = true
            NSCursor.closedHand.set()
        }
        onDrag?(point, false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAt = nil
            dragging = false
        }
        guard dragging else { return }
        NSCursor.openHand.set()
        onDrag?(event.locationInWindow, true)
    }
}

/// The rule down an overlay dock's inner edge.
///
/// Square, full height, two points, and the same colour at both ends of the
/// window — it is the one place in the app that says "there is something behind
/// this". A rounded card with a coloured rail would say it too and would say it
/// in the vocabulary of every templated dashboard; this is a cut, which is what
/// the strip is made of everywhere else.
@MainActor
final class DockEdgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.dockEdge.setFill()
        bounds.fill()
    }

    /// The strip underneath keeps the clicks. This is decoration over the seam
    /// between two things the user might want to click, and a 2 pt strip that
    /// swallows a mouse-down is a 2 pt strip nobody can explain.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The `⋯` at the end of the header.
///
/// A borderless button rather than an image button so the glyph stays in the
/// same typeface as everything else in the row, and so hover can turn it the accent
/// without an asset.
@MainActor
final class LaneHeaderMenuButton: NSView {
    var onPress: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { onPress?() }

    override func draw(_ dirtyRect: NSRect) {
        let points: CGFloat = 15
        guard let image = IconImage.make(
            .ellipsis, points: points, colour: hovering ? Theme.accent : Theme.dimText)
        else { return }
        image.draw(in: NSRect(
            x: (bounds.width - points) / 2, y: (bounds.height - points) / 2,
            width: points, height: points))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The 6pt strip along a lane's right edge that resizes it (PRD §8).
@MainActor
final class LaneResizeHandle: NSView {
    /// `(delta in points, isFinal)`.
    var onDrag: ((Double, Bool) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        // Window coordinates, not our own: this view moves as the lane resizes,
        // so a delta measured in its local space is measured against a moving
        // origin and the drag fights itself.
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        let delta = x - lastX
        lastX = x
        guard delta != 0 else { return }
        onDrag?(Double(delta), false)
    }

    override func mouseUp(with event: NSEvent) {
        // One ledger write per drag, not one per frame.
        onDrag?(0, true)
    }
}
