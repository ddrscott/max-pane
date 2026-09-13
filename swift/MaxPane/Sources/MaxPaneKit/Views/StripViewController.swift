import AppKit
import LanedCore

/// The strip: a horizontal, ordered sequence of lanes that scrolls left and
/// right and is infinite to the right (PRD §4).
///
/// This controller owns everything that is true regardless of how lanes are
/// materialised — lane lifetime, focus, reveal-and-flash, scroll persistence,
/// and relaying the eviction plan to pane controllers. *Which* lanes have views
/// right now is the one decision that differs between the strategies PRD §14
/// weighs, and it lives in exactly one place: `materializationWindow`.
///
/// Lanes have individually different widths, so there is no fixed item size to
/// hand a collection-view layout; the document view is laid out by summing
/// widths, which is O(n) over a number that is 150.
@MainActor
public final class StripViewController: NSViewController {
    private let store: StripStore
    private let config: Config

    private let scrollView = NSScrollView()
    private let content = StripContentView()

    /// Lane id → its view, for lanes that currently have one.
    private var laneViews: [String: LaneView] = [:]
    /// Views taken out of the hierarchy, kept for reuse rather than rebuilt.
    private var recycled: [LaneView] = []
    /// Who owns the live object inside each pane. Survives a lane view being
    /// recycled: unparenting a `WKWebView` is cheap, destroying it is not.
    private var paneControllers: [String: PaneController] = [:]
    /// Panes on their way out, so a second exit frame does not start a second
    /// animation on a pane that is already leaving.
    private var exiting: Set<String> = []
    /// The lanes as of the last snapshot, in order.
    ///
    /// Every transition in this file is a difference between this and the next
    /// snapshot. Nothing else in the strip knows what *changed* — `apply` is
    /// handed a whole new world each time — so without this the app can only
    /// cut.
    private var lastLanes: [Lane] = []
    /// Lanes the ledger no longer has, whose columns are still closing. They
    /// keep their slot in the layout until the collapse ends; see `laneLayout`.
    private var departingLanes: [(index: Int, lane: Lane)] = []
    /// Panes the ledger no longer has, whose views are still fading out of a
    /// stack. Reconciling ignores them until they are gone for real.
    private var departingPanes: Set<String> = []
    /// Lanes currently drawn differently from what the ledger says, because
    /// something is animating them.
    private var laneOverrides: [String: LaneOverride] = [:]
    /// How far left or right of where the flow puts it a lane is drawn, while it
    /// slides from the place it used to be. Purely visual: the flow position is
    /// always the true one, so a re-layout mid-slide cannot desync it.
    private var xOffsets: [String: CGFloat] = [:]
    /// Transitions in flight, keyed by lane id, so a lane that changes twice in
    /// a row animates once from where it currently is rather than having two
    /// timers fight over its geometry.
    private var transitions: [String: MotionTimer] = [:]
    /// A scroll the strip owes a lane whose column is still opening, carried by
    /// that lane's own transition.
    ///
    /// **Not a second animation.** `boundsOrigin` already has two owners — the
    /// snap and `reveal` — and a third writing it on its own clock is a bug
    /// wearing a fix's clothes. This is the insert's existing timer doing one
    /// more thing per frame, after the layout pass that grew the content view,
    /// which is also the only order in which the scroll is not clamped short.
    private var arrivalScroll: (laneId: String, from: CGFloat, to: CGFloat, flash: Bool)?
    private var snapDebounce: DispatchWorkItem?
    /// True while the snap animation is running, so the bounds changes it
    /// causes do not schedule another snap.
    private var isSnapping = false
    /// Programmatic scrolls run past this moment; snapping stays out of their
    /// way until then.
    private var suppressSnapUntil: CFAbsoluteTime = 0

    private var observer: UUID?
    private var scrollDebounce: DispatchWorkItem?
    private var memoryTimer: Timer?
    /// `(lane being dragged, index it would land at)` during a drag.
    private var dragPreview: (laneId: String, target: Int)?
    /// True until the strip has settled after launch. See `makeController`.
    private var isColdLaunch = true
    /// Latest session telemetry, so a lane materialised mid-stream is not blank
    /// until the next poll.
    private var laneTelemetry: [String: SessionTelemetry] = [:]
    /// The pane whose view currently holds the keyboard, so a snapshot that did
    /// not move focus does not steal it back from whatever the user clicked.
    private var focusedPaneInView: String?
    /// Swallows horizontal scrolls anywhere over the strip. See `startScrollCapture`.
    private var scrollMonitor: Any?
    /// Focuses whatever pane you click. See `startClickCapture`.
    private var clickMonitor: Any?
    /// Lanes whose arrival animation is waiting for their view to exist. See
    /// `beginArrivals`.
    private var pendingArrivals: Set<String> = []
    /// Lane widths as of the last snapshot, so a change from *any* source —
    /// drag, ⌃⌘=, span, an imported strip — reshapes the terminal.
    private var lastLaneWidths: [String: UInt32] = [:]
    /// Shown when the strip is empty, because a blank window that says nothing
    /// is indistinguishable from a broken one.
    private lazy var emptyState = EmptyStripView()
    /// How many lanes are off each end of the screen. See `StripEdges` for why
    /// the sliver alone is not enough.
    private let leadingRail = StripEdgeRail(side: .leading)
    private let trailingRail = StripEdgeRail(side: .trailing)

    // MARK: - docks

    /// The lane view held at each edge — **a sibling of the scroll view, never
    /// inside it.**
    ///
    /// This is the whole of the audio guarantee on this side of the FFI. The
    /// core promises a docked lane's panes are always `Keep`, never `Evict` and
    /// never `Unparent`; it cannot promise that `Keep` means *parented, in a
    /// window and visible*. A dock view living inside the scroll view's document
    /// view would be recycled by `updateMaterialization` the moment its ordinal
    /// scrolled out of range, or moved by the next layout pass — every test in
    /// `docking.rs` would still pass and the music would stop.
    private var dockViews: [DockSide: LaneView] = [:]
    /// What the docks are doing to the window right now, resolved once per
    /// layout. See `DockGeometry`: the ledger's widths are what the user asked
    /// for, this is what the window can afford, and the two never overwrite
    /// each other.
    private var dockLayout = DockGeometry.Layout.none
    /// A dock's width while its inner edge is being dragged, before the ledger
    /// has it. Same discipline as `laneOverrides` — draw what the pointer says,
    /// write once on the drop.
    private var dockWidthDrag: [DockSide: CGFloat] = [:]
    /// How far into the window each dock has slid, 0…1. Purely visual; the
    /// dock's place is always the resolved one, so a resize or another snapshot
    /// mid-slide re-lays it out without knocking the animation off course.
    private var dockSlide: [DockSide: CGFloat] = [:]
    /// One per edge, shown only while that dock floats. Built up front and kept
    /// — there are two of them and they are cheap, and a view created on a mode
    /// toggle is a view whose first frame lands after the toggle it is
    /// explaining.
    private let dockShadows: [DockSide: DockShadowView] = [.left: DockShadowView(), .right: DockShadowView()]

    public init(store: StripStore, config: Config) {
        self.store = store
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - view

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.stripBackground.cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        // Frame-positioned, like everything else in this file. It used to be
        // two Auto Layout constraints whose constants the docks moved, and that
        // does not work here: a constant changed from inside a layout pass —
        // which is where `relayout` runs from — schedules no further pass, and
        // the guard that skips an unchanged constant then makes the omission
        // permanent. Measured: the constraints read 578 while the scroll view's
        // frame stayed `(18, 0, 1564, 976)` through a hundred snapshots, so an
        // inset dock took its width out of nothing at all.
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = []
        scrollView.contentView.postsBoundsChangedNotifications = true
        // An overlay dock covers the last `overlayWidth` points of the clip
        // view, and without a matching content inset the document cannot be
        // scrolled far enough to bring what is under there back out — the last
        // lane of the strip would be permanently half-hidden behind the dock,
        // which is exactly the "content you cannot reach" failure `LanePeek`
        // refuses to create. AppKit is doing nothing else with these; left to
        // itself it would fit them to the title bar, which this window does not
        // have.
        scrollView.automaticallyAdjustsContentInsets = false

        view.addSubview(scrollView)
        // The rails take their width from the strip rather than floating over
        // it. An overlay would sit exactly where the sliver of the next lane
        // is — the one piece of the screen this whole piece exists to keep.
        //
        // **The docks nest inside the rails**, and that is a decision, not an
        // accident: `StripEdges.hidden` counts lanes against the strip's
        // visible window, and a rail *outside* the docks is the only place a
        // count of what an overlay is covering can be read. A rail under a dock
        // would be a number nobody can see about lanes nobody can see.
        let rail = config.stripEdgeRails ? StripEdgeRail.width : 0

        if config.stripEdgeRails {
            for railView in [leadingRail, trailingRail] {
                railView.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(railView)
                NSLayoutConstraint.activate([
                    railView.topAnchor.constraint(equalTo: view.topAnchor),
                    railView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    railView.widthAnchor.constraint(equalToConstant: StripEdgeRail.width),
                ])
            }
            NSLayoutConstraint.activate([
                leadingRail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                trailingRail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        for (side, shadow) in dockShadows {
            shadow.edge = side
            shadow.isHidden = true
            shadow.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(shadow)
        }

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // A lane is as tall as the strip, so every size change re-lays them out.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewResized),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        observer = store.observe { [weak self] state in self?.apply(state) }
        startMemorySampling()
        startScrollCapture()
        startClickCapture()
        // PRD §8: strip scroll position persists across launches.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `scrollX` is the strip's *visible* left edge, not the clip view's
            // bounds origin: an overlay dock inserts a content inset, and a
            // strip restored into a different dock arrangement from the one it
            // was saved in would otherwise come back shifted by the dock's
            // width.
            self.scrollView.contentView.scroll(
                to: NSPoint(x: self.clipOrigin(forVisible: self.store.state.scrollX), y: 0))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateMaterialization()
            // Launch is over: from here on, a new pane loads immediately.
            // Anything still deferred stays deferred until it is scrolled to.
            self.isColdLaunch = false
        }
    }

    /// The docks are frame-positioned against `view.bounds`, which Auto Layout
    /// only settles here.
    ///
    /// `clipViewResized` covers a window resize, but not the first pass after
    /// launch — the view has no size when `loadView` runs, so a dock restored
    /// from the ledger would be laid out against a zero-width window and sit
    /// there until something else moved.
    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutDocks()
    }

    /// Make a horizontal scroll move the strip, wherever the pointer happens to
    /// be.
    ///
    /// Without this the strip only scrolls when the pointer is over a gap
    /// between lanes, because a terminal view or a `WKWebView` under the cursor
    /// eats the event before the enclosing scroll view ever sees it — so the
    /// app appears to scroll only "in the margins", which is how Scott put it.
    ///
    /// The rule is by axis, not by what is underneath: a predominantly sideways
    /// gesture belongs to the strip, a vertical one belongs to whatever is under
    /// the pointer. That costs a web page its own horizontal scrolling, which is
    /// the right trade in an app whose central invariant is that lanes are
    /// portrait columns and wide content is the exception.
    private func startScrollCapture() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.view.window,
                  event.window === window,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return event }

            // Only over the strip — the sidebar scrolls itself.
            let inStrip = self.view.convert(event.locationInWindow, from: nil)
            guard self.view.bounds.contains(inStrip) else { return event }
            // ...and not over a dock. A docked lane does not scroll with the
            // strip, so a sideways gesture on top of one moving the strip
            // behind it would be the one thing docking exists to stop.
            guard !self.isOverADock(event.locationInWindow) else { return event }

            let clip = self.scrollView.contentView
            // Trackpads report points; a mouse wheel reports lines.
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 16
            let strip = self.viewport
            let maxX = max(0, self.content.frame.width - strip.width)
            let next = min(max(0, strip.offset - step), maxX)
            clip.setBoundsOrigin(
                NSPoint(x: self.clipOrigin(forVisible: next), y: clip.bounds.origin.y))
            self.scrollView.reflectScrolledClipView(clip)
            return nil
        }
    }

    /// Clicking a pane focuses it.
    ///
    /// A terminal view and a `WKWebView` both consume mouse events for their own
    /// purposes, so neither tells us it was clicked. This watches the event on
    /// its way down and moves focus without consuming it — the click still
    /// places a cursor, starts a selection, or presses a button as it should.
    private func startClickCapture() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            let inStrip = self.view.convert(event.locationInWindow, from: nil)
            guard self.view.bounds.contains(inStrip) else { return event }
            if let paneId = self.pane(at: event.locationInWindow) {
                self.focus(paneId)
            }
            return event
        }
    }

    /// Which pane is under a point in window coordinates.
    private func pane(at windowPoint: NSPoint) -> String? {
        for (laneId, laneView) in laneViews {
            let local = laneView.convert(windowPoint, from: nil)
            guard laneView.bounds.contains(local) else { continue }
            guard let lane = store.lane(laneId) else { return nil }
            // A lane can hold a stack, so find the pane whose view owns the point.
            for pane in lane.panes {
                if let view = laneView.paneView(for: pane.id),
                   view.bounds.contains(view.convert(windowPoint, from: nil)) {
                    return pane.id
                }
            }
            // The header or a gap: focus the lane's first pane.
            return lane.panes.first?.id
        }
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The timer is not touched here: `deinit` is nonisolated and `Timer` is
        // not Sendable. It holds only a weak reference to self, so it stops
        // doing anything the moment this controller is gone, and the window
        // controller outlives it anyway.
    }

    /// Sample WebKit's footprint on a fixed cadence.
    ///
    /// Scroll alone is not enough. The eviction policy needs three *consecutive*
    /// over-budget readings before the soft mark acts — spike M1 watched the
    /// same 100 panes swing 57% in three and a half minutes with nobody
    /// touching anything — and a user reading one lane produces no scroll events
    /// at all while memory climbs behind them.
    private func startMemorySampling() {
        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(
            withTimeInterval: config.memorySampleSeconds, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyEvictionPlan(for: self.store.state)
            }
        }
    }

    // MARK: - applying a snapshot

    /// Diff the new snapshot against what is on screen and touch only the
    /// difference. Called after every mutation, so it must not rebuild the world.
    private func apply(_ state: StripState) {
        let previous = lastLanes
        lastLanes = state.lanes
        let previousStrip = previous.filter { $0.dock == nil }
        let strip = state.lanes.filter { $0.dock == nil }
        // **The diff is over the lanes the strip lays out, not over the
        // snapshot.** A docked lane keeps its ordinal and stays in
        // `state.lanes`, so a diff taken there would see docking as nothing at
        // all — the column would simply cease to exist between two frames, with
        // the lanes to its right teleporting left to cover the hole.
        //
        // Diffing the laid-out strip instead makes docking a departure and
        // undocking an arrival, which is both true and exactly the motion they
        // want: the column closes where it stood while the dock slides in at
        // the wall, and the reverse. The one thing that must differ from a real
        // departure is that the view survives it, which is `beginDockDeparture`.
        let diff = StripDiff.between(previousStrip.map(\.id), strip.map(\.id))

        // What arrived, before anything is laid out: a lane whose column is
        // about to open must never take its full slot first, not even for the
        // one frame between here and its first animation tick.
        beginArrivals(diff.inserted, in: strip)

        // Lanes that left the row. A lane whose column is still closing keeps
        // its view and its slot; one that is not animating goes now.
        for departure in diff.removed {
            let docked = state.lanes.first { $0.id == departure.id }?.dock != nil
            guard let laneView = laneViews[departure.id] else { continue }
            guard let lane = previousStrip.first(where: { $0.id == departure.id }),
                  shouldAnimate(laneAt: departure.index, in: previousStrip)
            else {
                // A lane that went to an edge still exists and is about to be
                // parented at the wall. Retiring it here would clear its pane
                // views — the exact unparenting the dock is meant to prevent.
                if !docked { retire(laneView, laneId: departure.id) }
                continue
            }
            if docked {
                beginDockDeparture(lane, at: departure.index)
            } else {
                beginDeparture(lane, at: departure.index, view: laneView)
            }
        }

        // After the departures are registered: the last lane on the strip is
        // still closing for another fifth of a second, and "nothing here yet"
        // printed across a column that is visibly leaving says two things at
        // once.
        emptyState.isHidden = !state.lanes.isEmpty || !departingLanes.isEmpty

        relayout()
        updateMaterialization()
        // Materialization is what gives an arriving lane its view, so its
        // column can only start opening once that has run.
        runPendingArrivals()
        // And only once it has started can the strip hand it a scroll to carry.
        revealArrival(diff.inserted, in: strip)

        // Lanes that changed place. Measured in points between the two
        // snapshots rather than in indices, because that is the distance the
        // user's eye has to follow.
        beginMoves(diff.moved, from: previousStrip, to: strip)

        for lane in state.lanes {
            laneViews[lane.id]?.apply(lane)
            if let laneView = laneViews[lane.id] { applyHandleBounds(laneView, lane: lane) }
            laneViews[lane.id]?.isFocused = state.focusedPaneId.map { id in
                lane.panes.contains { $0.id == id }
            } ?? false
            // The fix for ⇧⌘D. `materialize` installs a lane's panes when the
            // lane view is *built*; nothing used to install one into a lane that
            // was already on screen, so a split created a real pane and a real
            // session that never rendered — and closing one pane of a stack left
            // its view behind for the same reason.
            if let laneView = laneViews[lane.id] {
                reconcilePanes(of: lane, in: laneView, animated: !isColdLaunch)
            }
        }

        // A lane that changed width owes its terminal a new shape, whatever
        // changed it. Hooking the drag handle alone missed ⌃⌘=, span and import,
        // which is how a keyboard-resized lane kept wrapping at its old column
        // count.
        for lane in state.lanes {
            defer { lastLaneWidths[lane.id] = lane.widthPt }
            guard let previous = lastLaneWidths[lane.id], previous != lane.widthPt else { continue }
            for pane in lane.panes {
                (paneControllers[pane.id] as? TerminalPaneController)?
                    .laneWidthDidChange(to: CGFloat(lane.widthPt))
            }
        }

        // Give the keyboard to a pane the ledger says is focused but which does
        // not have it yet. Without this a lane created by `maxpane run` — or by
        // ⌘T, or by the shim — comes up drawn, attached and completely deaf:
        // the ledger records the focus, no view ever takes first responder, and
        // every keystroke goes nowhere with no indication why.
        if let wanted = state.focusedPaneId, wanted != focusedPaneInView,
           let controller = paneControllers[wanted] {
            focusedPaneInView = wanted
            controller.takeFocus()
            // Focus that arrived from somewhere other than a click — ⌥⌘] going
            // into a dock and back out, ⌘P, the sidebar — owes the user a look
            // at where it went. `ensureVisible` moves the strip as little as it
            // can and not at all for a lane already whole on screen, so this is
            // free in the common case and is the whole answer in the case the
            // contract names: leaving a dock has to land somewhere visible.
            if let laneId = store.lane(containing: wanted)?.id { ensureVisible(laneId) }
        }

        reapPaneControllers(state)
    }

    // MARK: - reconciling a lane's panes

    /// Make one lane's stack match the snapshot, touching only what differs.
    ///
    /// The single installer: `materialize` calls it for a lane that has just
    /// been built, and `apply` calls it for every lane on screen after every
    /// mutation. Both go through `PaneStackPlan`, so a lane built from scratch
    /// and a lane that gained a pane end up in provably the same state — the
    /// thing that was not true when `setPaneView` had exactly one caller.
    private func reconcilePanes(of lane: Lane, in laneView: LaneView, animated: Bool) {
        let wanted = lane.panes.map(\.id)

        // Panes the snapshot has dropped. Started first and separately, because
        // an animated exit *keeps its slot* — the plan below then has to be
        // computed against a stack that still contains it.
        for id in laneView.arrangedPaneIds
        where !wanted.contains(id) && !departingPanes.contains(id) {
            beginPaneDeparture(id, in: laneView, animated: animated)
        }

        let installed = laneView.arrangedPaneIds
        let held = PaneStackPlan.holding(departingPanes, wanted: wanted, installed: installed)
        for step in PaneStackPlan.steps(installed: installed, wanted: held) {
            switch step {
            case .remove(let id):
                // Only reached when a departure was taken instantly — the
                // animated path has already held the slot.
                laneView.setPaneView(nil, for: id, at: 0)

            case .insert(let id, let index):
                guard let pane = lane.panes.first(where: { $0.id == id }) else { continue }
                let controller = paneControllers[id] ?? makeController(for: pane, in: lane)
                paneControllers[id] = controller
                controller.apply(pane)
                laneView.setPaneView(controller.view, for: id, at: index)
                if animated && !Motion.isReduced {
                    laneView.animatePaneViewIn(for: id, duration: Motion.pane)
                }

            case .move(let id, let index):
                laneView.movePaneView(for: id, to: index)
            }
        }
    }

    /// A pane leaving a stack while its lane stays.
    private func beginPaneDeparture(_ paneId: String, in laneView: LaneView, animated: Bool) {
        guard animated, !Motion.isReduced else { return }
        departingPanes.insert(paneId)
        laneView.fadeOutPaneView(for: paneId, duration: Motion.pane) { [weak self] in
            guard let self else { return }
            laneView.setPaneView(nil, for: paneId, at: 0)
            self.departingPanes.remove(paneId)
            self.reapPaneControllers(self.store.state)
        }
    }

    /// Let go of every pane controller nothing is using any more.
    ///
    /// The only place a controller dies. Lane views are recycled constantly and
    /// a controller deliberately outlives them (ADR-0004), so "this lane has no
    /// view" is never the question — "the ledger has no such pane, and nothing
    /// on screen is still showing it" is.
    private func reapPaneControllers(_ state: StripState) {
        var live = Set(state.lanes.flatMap(\.panes).map(\.id))
        for ghost in departingLanes { live.formUnion(ghost.lane.panes.map(\.id)) }
        live.formUnion(departingPanes)

        for (paneId, controller) in paneControllers where !live.contains(paneId) {
            controller.tearDown()
            paneControllers[paneId] = nil
            SnapshotStore.remove(for: paneId)
            if focusedPaneInView == paneId { focusedPaneInView = nil }
        }
    }

    // MARK: - materialization

    /// Which lanes get views right now.
    ///
    /// **This is the §14 decision, in one place** ([ADR-0004](../../../../docs/decisions/0004-strip-view-strategy.md)).
    /// Spike M4 measured all 150 lanes parented at **16.16% dropped frames**,
    /// and this recycling window at **0.00%**, with a peak of 13 live views and
    /// half the memory. Virtualization is required, not optional.
    ///
    /// A lane outside this window has its view recycled; its *pane controllers*
    /// survive, because a `WKWebView` is expensive to build and cheap to
    /// unparent (PRD §10.2).
    ///
    /// The window is deliberately wider than the viewport, by exactly
    /// `RELEASE_DISTANCE`. Sharing that constant is not laziness — it makes one
    /// invariant true: **a lane has a view for exactly as long as its web panes
    /// are meant to be parented.** Beyond it, both go at once, and there is no
    /// band where the strip holds chrome for panes that have already been let
    /// go, or vice versa.
    ///
    /// It also means a normal scroll never waits for a lane to be built: M4
    /// measured 0.00% dropped frames with this slack and a peak of 13 live lane
    /// views out of 150.
    /// The lanes worth having chrome for, as indices into `stripLanes`.
    ///
    /// Docked lanes are deliberately not in this arithmetic at all. The window
    /// is about lanes scrolling in and out of view, and a docked lane does
    /// neither — it is materialised because it is docked and retired when it
    /// undocks, which is `updateDocks`'s business, not this one's.
    private func materializationWindow(in lanes: [Lane]) -> Range<Int> {
        let visible = visibleLaneRange(in: lanes)
        let slack = Int(config.releaseDistance)
        let lower = max(0, visible.lowerBound - slack)
        let upper = min(lanes.count, visible.upperBound + slack)
        return lower..<max(lower, upper)
    }

    private func updateMaterialization() {
        let state = store.state
        // Docks first, and before the rails: they decide the strip's visible
        // window, and both the rails' counts and the materialisation window are
        // measured against it.
        updateDocks(state)
        updateEdgeRails()

        let strip = store.stripLanes
        let window = materializationWindow(in: strip)
        let wanted = Set(strip[window].map(\.id))

        for (id, laneView) in laneViews
        where !wanted.contains(id) && !isDeparting(id) && !isDocked(id) {
            // Off the window: recycle the chrome, keep the panes alive. A lane
            // whose column is still closing is not off the window — it is not in
            // the snapshot at all, and recycling it mid-collapse would make it
            // vanish, which is the cut this exists to remove. A docked lane is
            // not off the window either: it is on screen at the edge, and
            // recycling it is how the acceptance test fails silently.
            retire(laneView, laneId: id)
        }
        for lane in strip[window] where laneViews[lane.id] == nil {
            materialize(lane)
        }

        // Anything deferred that has come close enough gets built now. This is
        // the other half of lazy launch: §13 defers, and scrolling to a lane is
        // what undefers it. A docked lane reports distance 0, so a page docked
        // before it ever loaded loads here.
        for lane in state.lanes where distanceFromViewport(laneId: lane.id) <= config.rehydrateDistance {
            for pane in lane.panes {
                (paneControllers[pane.id] as? WebPaneController)?.loadIfDeferred()
            }
        }

        relayout()
        applyEvictionPlan(for: state)
    }

    private func materialize(_ lane: Lane) {
        Log.debug("materialize lane \(lane.id) with \(lane.panes.count) pane(s)")
        let laneView = makeLaneView(for: lane)
        laneViews[lane.id] = laneView
        content.addSubview(laneView)

        // A recycled view arrives holding another lane's panes; a fresh one
        // holds none. Both are just "the stack does not match the snapshot", so
        // both go through the same reconcile — never animated, because
        // materialising is what happens when a lane scrolls *back* into range,
        // and a lane you scrolled to has not appeared, it was always there.
        reconcilePanes(of: lane, in: laneView, animated: false)
    }

    /// Build or recycle a lane's chrome and wire up everything it can ask of
    /// the strip.
    ///
    /// Deliberately does not parent it and does not install its panes: the strip
    /// and the docks disagree about where a lane view goes and about nothing
    /// else, and a lane that is docked has to be built by exactly the same code
    /// as a lane that is not, or "a docked lane is still a lane" stops being
    /// true one callback at a time.
    private func makeLaneView(for lane: Lane) -> LaneView {
        let laneView: LaneView
        if let reused = recycled.popLast() {
            reused.apply(lane)
            laneView = reused
        } else {
            laneView = LaneView(lane: lane, widthBounds: config.widthRange)
        }
        laneView.laneId = lane.id
        laneView.onResize = { [weak self] width, isFinal in
            guard let self else { return }
            // The same gesture on a different number. A docked lane's inner
            // edge drags the *dock's* width, which is durable and separate, so
            // undocking gives the lane back at the width it had in the strip.
            if let side = self.store.lane(lane.id)?.dock?.side {
                if isFinal {
                    self.dockWidthDrag[side] = nil
                    try? self.store.setDockWidth(lane.id, width)
                } else {
                    self.dockWidthDrag[side] = CGFloat(width)
                    self.relayout()
                }
                return
            }
            if isFinal {
                self.laneOverrides[lane.id] = nil
                try? self.store.setLaneWidth(lane.id, width)

            } else {
                // Lay out live. Without this the lane only jumps to its new
                // width on mouse-up, which reads as the drag not working at all.
                // Still no ledger write until the drop — §6 wants one commit per
                // decision, not sixty a second.
                self.laneOverrides[lane.id] = LaneOverride(slot: CGFloat(width), masked: false)
                self.relayout()
            }
        }
        laneView.onPaneHeights = { [weak self] weights, isFinal in
            guard let self else { return }
            // The lane has already redrawn itself; the strip's only job here is
            // the two things that must not happen sixty times a second. One
            // ledger write per decision, as PRD §6 wants — and one word to the
            // far end of each terminal, for the reason in
            // `TerminalPaneController.beginLiveResize`.
            let terminals = weights.compactMap {
                self.paneControllers[$0.paneId] as? TerminalPaneController
            }
            guard isFinal else {
                for terminal in terminals { terminal.beginLiveResize() }
                return
            }
            try? self.store.setPaneHeights(weights)
            for terminal in terminals { terminal.endLiveResize() }
        }
        applyHandleBounds(laneView, lane: lane)
        laneView.onHeaderDrag = { [weak self] x, isFinal in
            self?.handleLaneDrag(laneId: lane.id, toX: x, isFinal: isFinal)
        }
        laneView.onHeaderDoubleClick = { [weak self] in
            guard let self, let root = self.store.lane(lane.id)?.projectRoot else { return }
            try? self.store.gather(projectRoot: root)
        }
        // The ⋯ menu's docking items. They act on the lane under the pointer
        // rather than the focused one, which is the whole reason the menu
        // exists beside the keys — and they go through the same toggle the
        // keys do, so the two cannot come to disagree about what pressing it
        // twice means.
        laneView.onDockLeft = { [weak self] in
            try? self?.store.toggleDock(lane.id, side: .left)
        }
        laneView.onDockRight = { [weak self] in
            try? self?.store.toggleDock(lane.id, side: .right)
        }
        laneView.onToggleDockMode = { [weak self] in
            try? self?.store.toggleDockMode(lane.id)
        }
        // The rest of the menu, which has been greyed out since the header was
        // written because nothing ever connected it. Adding three live items
        // beside five dead ones would have made the menu look broken in a way
        // it did not before, and each of these is one call to a command that
        // already exists. "Set Project Tag…" is the one left out: it needs a
        // dialog, and a dialog is a design decision, not a wire.
        laneView.onTogglePin = { [weak self] in
            guard let self, let lane = self.store.lane(lane.id) else { return }
            try? self.store.setKeepLive(lane.id, !lane.keepLive)
        }
        laneView.onToggleSpan = { [weak self] in
            guard let self, let lane = self.store.lane(lane.id) else { return }
            try? self.store.setLaneSpan(lane.id, lane.span == 1 ? 2 : 1)
        }
        laneView.onCloseLane = { [weak self] in
            try? self?.store.closeLane(lane.id)
        }
        laneView.applyTelemetry(laneTelemetry)
        return laneView
    }

    /// What the width handle is allowed to drag this lane to.
    ///
    /// A dock is not a reading column: `laneMinPt`'s 420 is 80 monospace
    /// columns plus chrome (spike M2), which is the wrong floor for a music
    /// player parked at the edge. The dock bounds are the core's, mirrored in
    /// `DockGeometry`.
    private func applyHandleBounds(_ laneView: LaneView, lane: Lane) {
        laneView.widthBounds = lane.dock == nil
            ? config.widthRange.lowerBound...(config.laneMaxPt * max(lane.span, 1))
            : UInt32(DockGeometry.minPt)...UInt32(DockGeometry.maxPt)
    }

    // MARK: - docks

    private func isDocked(_ laneId: String) -> Bool {
        dockViews.contains { $0.value.laneId == laneId }
    }

    /// Whether a point in window coordinates is over a dock.
    private func isOverADock(_ windowPoint: NSPoint) -> Bool {
        dockViews.values.contains { $0.bounds.contains($0.convert(windowPoint, from: nil)) }
    }

    /// Give each edge the lane the snapshot says holds it.
    ///
    /// A lane view moves between `content` and `view` rather than being rebuilt
    /// at either end. `addSubview` on a view that already has a superview *in
    /// the same window* re-parents it without the window ever going nil, so the
    /// `WKWebView` inside never sees `IsInWindow` clear — which is the
    /// difference between docking a music page and reloading it.
    private func updateDocks(_ state: StripState) {
        for side in [DockSide.left, .right] {
            let lane = state.lanes.first { $0.dock?.side == side }
            guard let lane else {
                releaseDock(side)
                continue
            }
            if dockViews[side]?.laneId != lane.id {
                // A different lane took this edge — the incumbent has been
                // displaced back into the strip and wants its column.
                releaseDock(side)
                let laneView = laneViews[lane.id] ?? makeLaneView(for: lane)
                let isNew = laneViews[lane.id] == nil
                laneViews[lane.id] = laneView
                dockViews[side] = laneView
                // Above the scroll view. An inset dock does not overlap it, but
                // an overlay must, and one rule is easier to keep than two.
                view.addSubview(laneView, positioned: .above, relativeTo: nil)
                if isNew { reconcilePanes(of: lane, in: laneView, animated: false) }
                beginDockEntrance(side, laneId: lane.id)
            }
            applyHandleBounds(dockViews[side]!, lane: lane)
        }
    }

    /// Hand an edge back: the view returns to the strip's document, where the
    /// next materialisation pass will keep it or recycle it like any other.
    private func releaseDock(_ side: DockSide) {
        guard let laneView = dockViews.removeValue(forKey: side) else { return }
        transitions.removeValue(forKey: laneView.laneId)?.cancel()
        dockSlide[side] = nil
        dockWidthDrag[side] = nil
        laneView.floatingEdge = nil
        laneView.drawnDockMode = nil
        laneView.resizeEdge = .trailing
        laneView.alphaValue = 1
        content.addSubview(laneView)
    }

    /// The dock slides in from the edge it is going to hold.
    ///
    /// The lane's column is collapsing in the strip at the same time (see
    /// `beginDockDeparture`), so the two halves of the move are on screen
    /// together: something left the row, something arrived at the wall. A cut
    /// here is the *"user loses spatial recognition"* case in its most literal
    /// form — a lane that was in front of you is suddenly somewhere else.
    private func beginDockEntrance(_ side: DockSide, laneId: String) {
        guard !isColdLaunch else { return }
        dockSlide[side] = 0
        layoutDocks()
        startTransition(lane: laneId, duration: Motion.lane) { [weak self] t in
            guard let self else { return }
            self.dockSlide[side] = Motion.easeOut(t)
            self.layoutDocks()
        } completion: { [weak self] in
            self?.dockSlide[side] = nil
            self?.layoutDocks()
        }
    }

    /// Resolve what the docks take and put them there.
    ///
    /// Runs from `relayout`, so every caller that lays the strip out — a
    /// snapshot, a scroll, a resize, an animation frame — gets the docks with
    /// it and there is no second clock writing the same geometry.
    private func layoutDocks() {
        let rail = config.stripEdgeRails ? StripEdgeRail.width : 0
        let available = max(0, view.bounds.width - rail * 2)

        func requested(_ side: DockSide) -> Dock? {
            guard var dock = store.dockedLane(side)?.dock else { return nil }
            if let dragged = dockWidthDrag[side] { dock.widthPt = UInt32(max(0, dragged)) }
            return dock
        }

        dockLayout = DockGeometry.resolve(
            left: requested(.left), right: requested(.right),
            viewport: available, laneMinPt: CGFloat(config.laneMinPt))

        // Inset takes its room out of the clip view itself, so every existing
        // reader of `contentView.bounds` is correct with no edit — contract
        // position 1, followed. Overlay takes nothing and gets a content inset
        // instead, so the strip can still be scrolled out from under it.
        let strip = NSRect(
            x: rail + dockLayout.insetLeft, y: 0,
            width: max(0, view.bounds.width - rail * 2 - dockLayout.insetLeft - dockLayout.insetRight),
            height: view.bounds.height)
        if scrollView.frame != strip { scrollView.frame = strip }
        let insets = NSEdgeInsets(
            top: 0, left: dockLayout.overlayLeft, bottom: 0, right: dockLayout.overlayRight)
        if scrollView.contentInsets.left != insets.left
            || scrollView.contentInsets.right != insets.right {
            scrollView.contentInsets = insets
        }

        for side in [DockSide.left, .right] {
            guard let laneView = dockViews[side] else {
                dockShadows[side]?.isHidden = true
                continue
            }
            guard let placement = side == .left ? dockLayout.left : dockLayout.right else { continue }
            laneView.floatingEdge = placement.mode == .overlay ? side : nil
            laneView.drawnDockMode = placement.mode
            // The inner edge is the grabbable one at both ends: a dock's outer
            // edge is against the wall and has nothing to give.
            laneView.resizeEdge = side == .left ? .trailing : .leading

            let slide = dockSlide[side] ?? 1
            let offScreen = (1 - slide) * placement.width
            let x = side == .left
                ? rail - offScreen
                : view.bounds.width - rail - placement.width + offScreen
            let frame = NSRect(x: x, y: 0, width: placement.width, height: view.bounds.height)
            if laneView.frame != frame { laneView.frame = frame }
            if laneView.alphaValue != slide { laneView.alphaValue = slide }

            // The cast shadow travels with the dock's inner edge, so a dock
            // sliding in at launch does not leave a gradient sitting on the
            // strip ahead of it.
            guard let shadow = dockShadows[side] else { continue }
            shadow.isHidden = placement.mode != .overlay
            guard !shadow.isHidden else { continue }
            let shadowFrame = NSRect(
                x: side == .left ? frame.maxX : frame.minX - DockShadowView.width,
                y: 0, width: DockShadowView.width, height: view.bounds.height)
            if shadow.frame != shadowFrame { shadow.frame = shadowFrame }
            if shadow.alphaValue != slide { shadow.alphaValue = slide }
            // Z-order needs no maintenance here: the shadows were added after
            // the scroll view they fall on and before any dock, and a dock is
            // parented with `.above` whenever it takes an edge. Re-ordering
            // subviews from a layout pass that runs on every animation frame
            // would be sixty tree mutations a second to say the same thing.
        }
    }

    // MARK: - a session that ended

    /// The shell in this pane exited, so the pane goes.
    ///
    /// A terminal whose process is gone is a rectangle of dead text taking a
    /// column: you close it by hand every single time, which is a chore the app
    /// can do for you. It animates out rather than blinking away — the lane
    /// beside it is about to move, and a strip where columns teleport is a strip
    /// you lose your place in.
    ///
    /// The beat before it starts is deliberate. An exit is often the last line
    /// of output, and a pane that vanishes the instant a command finishes takes
    /// the answer with it.
    private func paneDidExit(_ paneId: String) {
        guard exiting.insert(paneId).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitHold) { [weak self] in
            self?.closeExitedPane(paneId)
        }
    }

    /// How long a finished pane stays legible before it starts to go.
    private static let exitHold: TimeInterval = 0.45

    /// Commit the close and let the strip's own transitions show it.
    ///
    /// This used to run the collapse itself and write to the ledger afterwards.
    /// It no longer needs to: a pane leaving the snapshot is now animated
    /// wherever it comes from, so an exited session and a ⌘W go out by exactly
    /// the same path and look the same doing it — and the write comes first
    /// again, which is what the README's "commit the mutation before animating
    /// it" asks for.
    private func closeExitedPane(_ paneId: String) {
        // Gone already — closed by hand during the hold, or the lane went with
        // a sibling.
        guard store.lane(containing: paneId) != nil else {
            exiting.remove(paneId)
            return
        }
        exiting.remove(paneId)
        focusNeighbourIfNeeded(closing: paneId)
        try? store.closePane(paneId)
    }

    /// Keep the keyboard somewhere real when the focused pane is the one going.
    private func focusNeighbourIfNeeded(closing paneId: String) {
        // `stripLanes`, because "the lane beside it" is a fact about the row.
        // A docked lane is beside nothing — it is at the wall — and handing the
        // keyboard to it when a terminal three columns away exits would move
        // focus across the window for no reason the user can see.
        let lanes = store.stripLanes
        guard store.state.focusedPaneId == paneId,
              let lane = store.lane(containing: paneId),
              let index = lanes.firstIndex(where: { $0.id == lane.id })
        else { return }
        // The lane to the right inherits the column the closing one is leaving,
        // so it is the one the eye is already on.
        let neighbours = [index + 1, index - 1].compactMap { i -> Lane? in
            guard i >= 0, i < lanes.count else { return nil }
            let candidate = lanes[i]
            return candidate.id == lane.id ? nil : candidate
        }
        guard let next = neighbours.first, let pane = next.panes.first else { return }
        try? store.focusPane(pane.id)
    }

    // MARK: - lane transitions

    /// The lanes the strip draws: the ledger's, plus any whose column is still
    /// closing.
    ///
    /// A lane that has left the ledger has to keep a slot until its collapse
    /// finishes, or the lanes to its right teleport left the instant the write
    /// commits — which is the exact thing the collapse exists to prevent.
    private var laneLayout: [Lane] {
        guard !departingLanes.isEmpty else { return store.stripLanes }
        var lanes = store.stripLanes
        for ghost in departingLanes.sorted(by: { $0.index < $1.index }) {
            lanes.insert(ghost.lane, at: min(ghost.index, lanes.count))
        }
        return lanes
    }

    private func isDeparting(_ laneId: String) -> Bool {
        departingLanes.contains { $0.lane.id == laneId }
    }

    /// Position every lane. The one place that lays the strip out, so every
    /// caller gets the ghosts and the in-flight offsets for free.
    private func relayout(lanes: [Lane]? = nil) {
        // Before the strip: an inset dock changes how wide the clip view is,
        // and a layout pass that ran first would be measured against the old
        // one for exactly one frame — which is the frame the eye catches.
        layoutDocks()
        content.layOut(
            lanes: lanes ?? laneLayout,
            // A docked lane's view answers to `layoutDocks`, not to the row. It
            // still appears in `laneLayout` while its column is collapsing —
            // that ghost slot is what stops the strip teleporting shut — but
            // the view it belongs to is already at the wall.
            viewFor: { [weak self] lane in
                guard let self, !self.isDocked(lane.id) else { return nil }
                return self.laneViews[lane.id]
            },
            overrides: laneOverrides,
            xOffsets: xOffsets)
    }

    /// Whether a change at this index is worth animating.
    ///
    /// Motion off screen is not subtle, it is invisible — and worse than
    /// invisible: a lane growing open to the left of the viewport pushes
    /// everything the user is reading sideways for a fifth of a second, to
    /// narrate something they cannot see. On screen or one lane past the edge
    /// (where the eye is already heading, because that is where ⌘T puts things)
    /// gets the motion; everything else is instant and correct.
    private func shouldAnimate(laneAt index: Int, in lanes: [Lane]) -> Bool {
        guard !isColdLaunch, !Motion.isReduced, view.window != nil else { return false }
        let visible = visibleLaneRange(in: lanes)
        return index >= visible.lowerBound - 1 && index <= visible.upperBound
    }

    /// A lane that has just joined the strip: its column opens at the place it
    /// will live, pushing its neighbours aside, and the lane fades up inside it.
    ///
    /// The inverse of the collapse, deliberately — arrival and departure are the
    /// same event seen from opposite ends, and giving them different shapes
    /// would make the strip harder to read, not more interesting.
    ///
    /// The width override is set *here*, before the caller's first layout, and
    /// the timer starts later: the view does not exist until materialization has
    /// run, and a single frame at full width before the animation begins is the
    /// cut this is replacing.
    private func beginArrivals(_ laneIds: [String], in lanes: [Lane]) {
        for id in laneIds {
            guard let index = lanes.firstIndex(where: { $0.id == id }),
                  shouldAnimate(laneAt: index, in: lanes)
            else { continue }
            laneOverrides[id] = LaneOverride(slot: 0, masked: true)
            pendingArrivals.insert(id)
        }
    }

    private func runPendingArrivals() {
        let arrivals = pendingArrivals
        pendingArrivals.removeAll()
        for id in arrivals {
            guard let laneView = laneViews[id], let lane = store.lane(id) else {
                laneOverrides[id] = nil
                continue
            }
            let full = CGFloat(lane.widthPt)
            laneView.alphaValue = 0
            startTransition(lane: id, duration: Motion.lane) { [weak self] t in
                guard let self else { return }
                let eased = Motion.easeOut(t)
                laneView.alphaValue = eased
                self.laneOverrides[id] = LaneOverride(slot: full * eased, masked: true)
                self.relayout()
                // After the layout that grew the content view, never before:
                // the clip view clamps to the document's width, and asking it
                // to scroll into a column that has not been laid out yet is the
                // whole of the bug this carries the scroll to avoid.
                self.stepArrivalScroll(id, eased: eased)
            } completion: { [weak self] in
                guard let self else { return }
                laneView.alphaValue = 1
                self.laneOverrides[id] = nil
                self.relayout()
                self.finishArrivalScroll(id)
            }
        }
    }

    /// A lane that arrived holding the focus is a lane the app moved you to, so
    /// the strip owes you a look at where it went.
    ///
    /// Nothing did this before. ⌘O put a lane beside the focused one and
    /// scrolled nowhere at all; in a 1600 pt window the third and fourth lanes
    /// arrived with no pixel on screen changing except the footer's count. The
    /// rule is stated in terms of focus rather than of "the last lane" because
    /// focus is the thing the mutation already decided: a lane the ledger
    /// focused is a lane the user is meant to be looking at, whichever door it
    /// came in by — ⌘O, the shim, an adopted popup, an imported strip.
    private func revealArrival(_ inserted: [String], in lanes: [Lane]) {
        guard !isColdLaunch, !inserted.isEmpty,
              let focused = store.state.focusedPaneId else { return }
        guard let laneId = inserted.first(where: { id in
            lanes.first { $0.id == id }?.panes.contains { $0.id == focused } ?? false
        }) else { return }
        // A lane that will be whole on screen once its column has opened needs
        // no scroll at all: the column opening in place is the entire story, and
        // recentring on it would shove three other lanes off the screen to
        // narrate something already in front of you. `minimal` is asked against
        // the ledger's widths, so it answers about the *finished* column rather
        // than the zero-width slot it currently occupies.
        let window = viewport
        if StripReveal.minimal(
            from: window.offset, to: laneId,
            lanes: lanes, viewport: window.width) == window.offset { return }
        reveal(laneId: laneId, flash: false)
    }

    /// One frame of a scroll being carried by an arriving lane's transition.
    private func stepArrivalScroll(_ laneId: String, eased: CGFloat) {
        guard let scroll = arrivalScroll, scroll.laneId == laneId else { return }
        let clip = scrollView.contentView
        let visible = scroll.from + (scroll.to - scroll.from) * eased
        clip.setBoundsOrigin(
            NSPoint(x: clipOrigin(forVisible: visible), y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func finishArrivalScroll(_ laneId: String) {
        guard let scroll = arrivalScroll, scroll.laneId == laneId else { return }
        arrivalScroll = nil
        // Land on the number rather than on the last eased sample: the column's
        // final layout ran a line above this, so the target is reachable now
        // whether or not it was on the frame before.
        let clip = scrollView.contentView
        clip.setBoundsOrigin(
            NSPoint(x: clipOrigin(forVisible: scroll.to), y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        updateMaterialization()
        if scroll.flash { laneViews[laneId]?.flash() }
    }

    /// A lane that has left the ledger: its column closes where it stood, and
    /// the strip to its right slides over the gap so you can see what took its
    /// place.
    private func beginDeparture(_ lane: Lane, at index: Int, view laneView: LaneView) {
        departingLanes.append((index, lane))
        let full = CGFloat(lane.widthPt)
        // The first frame, now: a transition's first tick is a run loop away,
        // and the strip must never paint the end state before the motion that
        // explains it. This one is already correct at full width — but saying so
        // costs nothing and stops the next person wondering.
        laneOverrides[lane.id] = LaneOverride(slot: full, masked: true)
        startTransition(lane: lane.id, duration: Motion.lane) { [weak self] t in
            guard let self else { return }
            let eased = Motion.easeOut(t)
            laneView.alphaValue = 1 - eased
            self.laneOverrides[lane.id] = LaneOverride(slot: max(0, full * (1 - eased)), masked: true)
            self.relayout()
        } completion: { [weak self] in
            guard let self else { return }
            self.laneOverrides[lane.id] = nil
            self.departingLanes.removeAll { $0.lane.id == lane.id }
            laneView.alphaValue = 1
            self.retire(laneView, laneId: lane.id)
            self.reapPaneControllers(self.store.state)
            self.emptyState.isHidden =
                !self.store.state.lanes.isEmpty || !self.departingLanes.isEmpty
            self.relayout()
            self.updateMaterialization()
        }
    }

    /// A lane that left the row for an edge: its column closes where it stood,
    /// exactly as a departure does, and the strip slides over the gap.
    ///
    /// The one difference from `beginDeparture` is the whole point of it — no
    /// view is touched and nothing is retired. The lane view is already on its
    /// way to the wall (`updateDocks` re-parents it in the same pass), so this
    /// only holds the *slot* open long enough to close it. Retiring here would
    /// call `clearPaneViews`, which unparents the `WKWebView` the dock exists to
    /// keep parented.
    private func beginDockDeparture(_ lane: Lane, at index: Int) {
        departingLanes.append((index, lane))
        let full = CGFloat(lane.widthPt)
        laneOverrides[lane.id] = LaneOverride(slot: full, masked: true)
        // Keyed by a name of its own, because the lane's own key is already
        // carrying the dock's slide-in and the two run at once — one closing a
        // column, one arriving at the wall.
        startTransition(lane: "dock-exit:\(lane.id)", duration: Motion.lane) { [weak self] t in
            guard let self else { return }
            self.laneOverrides[lane.id] = LaneOverride(
                slot: max(0, full * (1 - Motion.easeOut(t))), masked: true)
            self.relayout()
        } completion: { [weak self] in
            guard let self else { return }
            self.laneOverrides[lane.id] = nil
            self.departingLanes.removeAll { $0.lane.id == lane.id }
            self.relayout()
            self.updateMaterialization()
        }
    }

    /// A lane that changed place (⇧⌘← / ⇧⌘→, or a drop): it starts drawn where
    /// it used to be and slides to where it now is, so the swap is something you
    /// watched rather than something you have to reconstruct.
    ///
    /// The offset is visual only — the flow already has the lane at its new
    /// position — so a scroll, a telemetry tick or another mutation during the
    /// slide re-lays the strip out without knocking the animation off course.
    private func beginMoves(_ laneIds: [String], from before: [Lane], to after: [Lane]) {
        guard !laneIds.isEmpty, !isColdLaunch, !Motion.isReduced, view.window != nil else { return }
        let was = StripGeometry.origins(of: before)
        let now = StripGeometry.origins(of: after)
        var slides: [(id: String, delta: CGFloat)] = []
        for id in laneIds {
            guard laneViews[id] != nil, let from = was[id], let to = now[id] else { continue }
            let delta = from - to
            guard abs(delta) > 1 else { continue }
            xOffsets[id] = delta
            slides.append((id, delta))
        }
        // Draw them back where they were *before* the first tick. A transition's
        // first frame is a run loop away, and without this the strip paints the
        // lanes already swapped for the three frames before the slide starts —
        // which is the teleport this is here to remove, with a slide after it.
        guard !slides.isEmpty else { return }
        relayout()

        for (id, delta) in slides {
            startTransition(lane: id, duration: Motion.lane) { [weak self] t in
                guard let self else { return }
                self.xOffsets[id] = delta * (1 - Motion.easeOut(t))
                self.relayout()
            } completion: { [weak self] in
                guard let self else { return }
                self.xOffsets[id] = nil
                self.relayout()
            }
        }
    }

    /// Start a transition on one lane, replacing whatever that lane was already
    /// doing.
    ///
    /// Keyed by lane rather than by kind so the second of two quick changes
    /// takes over from the first instead of both writing the same geometry every
    /// frame. Each transition owns both of the lane's overrides for its
    /// duration, so the one it is not animating is cleared rather than left at
    /// whatever the last one got to.
    ///
    /// With Reduce Motion on — or with the window gone, where there is nothing
    /// to see and a timer would just keep the controller alive — this runs the
    /// last frame and the completion immediately. Same end state, no middle.
    private func startTransition(
        lane laneId: String,
        duration: TimeInterval,
        step: @escaping @MainActor (CGFloat) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        transitions.removeValue(forKey: laneId)?.cancel()
        guard !Motion.isReduced, view.window != nil else {
            step(1)
            completion()
            return
        }
        transitions[laneId] = Motion.run(duration: duration, step: step) { [weak self] in
            self?.transitions[laneId] = nil
            completion()
        }
    }

    /// ⌘= / ⌘- / ⌘0 on whatever has the keyboard.
    ///
    /// The pane decides what scaling means for it — a terminal re-derives its
    /// grid from a bigger font, a page takes a page zoom — so this only walks
    /// the ladder and hands over the result.
    public func zoomFocusedPane(_ command: Command) {
        guard let paneId = store.state.focusedPaneId,
              let controller = paneControllers[paneId]
        else { return }
        switch command {
        case .zoomReset:
            controller.setZoom(1)
        case .zoomIn, .zoomOut:
            controller.setZoom(
                PaneZoom.next(from: controller.zoom, up: command == .zoomIn))
        default:
            break
        }
    }

    /// ⌘R / ⇧⌘R on whatever has the keyboard. What reloading means is the
    /// pane's business — a page refetches, and a terminal has nothing to
    /// refetch and says so rather than quietly running something.
    public func reloadFocusedPane(fromOrigin: Bool) {
        guard let paneId = store.state.focusedPaneId else { return }
        paneControllers[paneId]?.reload(fromOrigin: fromOrigin)
    }

    /// Ask every live pane to write down what it would otherwise lose.
    ///
    /// Only web panes have anything to say — their history and scroll live in
    /// WebKit until someone asks — and only the ones that were built: a pane
    /// scrolled far off the strip has no controller and nothing in flight.
    public func flushPaneState() {
        for controller in paneControllers.values { controller.flushState() }
    }

    /// Scroll to the next lane whose page has stopped to ask something.
    ///
    /// This is the only thing that moves the viewport for a dialog, and it
    /// moves it because a person clicked. `WebAskCenter` deliberately never
    /// scrolls on its own — a background page that can pull the strip to itself
    /// is the modal-sheet freeze wearing different clothes.
    ///
    /// It also *materialises* the lane on the way, which is the half that is
    /// easy to miss: a pane far enough off the strip has no view, so its sheet
    /// has nowhere to be drawn until `reveal` brings the lane back into the
    /// materialisation window. The sheet survives that, because it is a subview
    /// of the pane's own container and lane views are recycled around it.
    @discardableResult
    public func revealNextAsking() -> Bool {
        guard let paneId = WebAskCenter.shared.next(),
              let laneId = store.lane(containing: paneId)?.id
        else { return false }
        reveal(laneId: laneId, flash: true)
        try? store.focusPane(paneId)
        return true
    }

    /// Take a lane's chrome out of the strip.
    ///
    /// Never touches pane controllers. A retired lane is usually one that has
    /// merely scrolled out of the materialization window and will be back, and
    /// its `WKWebView` is cheap to unparent and ruinous to rebuild (PRD §10.2).
    /// Whether a pane is *gone* is a question about the ledger, not about this
    /// view, and `reapPaneControllers` is the one place that asks it.
    private func retire(_ laneView: LaneView, laneId: String) {
        laneView.clearPaneViews()
        laneView.removeFromSuperview()
        laneViews[laneId] = nil
        // A handful of spare chrome views is plenty; the rest can go.
        if recycled.count < 8 { recycled.append(laneView) }
    }

    private func makeController(for pane: Pane, in lane: Lane) -> PaneController {
        switch pane.kind {
        case .pty:
            let controller = TerminalPaneController(pane: pane, store: store, config: config)
            // A pty pane without a session id is a lane whose session could not
            // be started. It keeps its ordinal and its tag and shows why
            // (PRD §11, §15.8); it just has nothing to attach to.
            controller.onRevealLane = { [weak self] laneId in
                guard let self, let laneId else { return }
                self.reveal(laneId: laneId, flash: true)
            }
            controller.onSessionExit = { [weak self] _ in
                self?.paneDidExit(pane.id)
            }
            if let sessionId = pane.relaySessionId {
                controller.attach(RelayAttachmentAdapter(sessionId: sessionId))
            } else {
                Log.warn("pty pane \(pane.id) has no relay session")
            }
            return controller
        case .web, .placeholder:
            // PRD §13: on a cold launch only panes near the viewport are
            // instantiated. Everything else waits as a placeholder until it is
            // scrolled to — which, at M1's 27–95 MB a pane, is the difference
            // between a 150-lane strip opening and a 150-lane strip thrashing.
            //
            // **A docked lane is never deferred.** `distanceFromViewport`
            // already answers 0 for one, which is the general fix; this says it
            // a second time at the one call site where getting it wrong is
            // silent and survives every test. The failure it prevents: a music
            // lane docked at ordinal 0, a strip restored scrolled to lane 40, a
            // page that never loads, and an acceptance test that fails on the
            // first launch after a restart in exactly the case the feature
            // exists for.
            let controller = WebPaneController(
                pane: pane, lane: lane, store: store, config: config,
                deferLoad: lane.dock == nil && isColdLaunch
                    && distanceFromViewport(laneId: lane.id) > config.rehydrateDistance)
            // A popup that opens while its opener is scrolled off the strip is
            // created, focused in the ledger, and never brought on screen —
            // which is fine for a machine-to-machine round trip and useless for
            // a sign-in form you have to type into.
            controller.onRevealLane = { [weak self] laneId in
                guard let self, let laneId else { return }
                self.reveal(laneId: laneId, flash: true)
            }
            return controller
        }
    }

    // MARK: - drag reorder (§7.2)

    /// Drag a lane to a new place in the strip.
    ///
    /// Only the drop writes. PRD §6 wants every layout mutation committed before
    /// the UI animates it, and a drag produces a mutation per frame — committing
    /// each would be sixty synchronous SQLite writes a second to describe one
    /// decision the user has not finished making yet.
    ///
    /// **The system never reorders** (§7.2). This runs only from the user's own
    /// gesture, and it is the only thing besides ⌘⇧←/→ that writes an ordinal.
    private func handleLaneDrag(laneId: String, toX x: CGFloat, isFinal: Bool) {
        // A dock's header is not a handle for reordering: it holds an edge, and
        // the ordinal it is keeping is the one it will go back to.
        let lanes = store.stripLanes
        guard store.lane(laneId)?.dock == nil,
              let target = laneIndex(atX: x, in: lanes),
              let from = lanes.firstIndex(where: { $0.id == laneId })
        else { return }

        guard isFinal else {
            // Live feedback without a write: slide the dragged lane's view to
            // where it would land.
            dragPreview = (laneId, target)
            relayout(lanes: reordered(lanes, from: from, to: target))
            return
        }

        dragPreview = nil
        guard target != from else {
            // Dropped where it started. Re-lay out so the preview does not stick.
            relayout()
            return
        }

        let neighbour = lanes[target]
        do {
            if target > from {
                try store.moveLane(laneId, rightOf: neighbour.id)
            } else {
                try store.moveLane(laneId, leftOf: neighbour.id)
            }
        } catch {
            Log.warn("could not move lane \(laneId): \(error)")
        }
    }

    /// `lanes` with the lane at `from` moved to `to`. Preview only — the ledger
    /// is what decides the real order.
    private func reordered(_ lanes: [Lane], from: Int, to: Int) -> [Lane] {
        guard from != to, lanes.indices.contains(from), lanes.indices.contains(to) else { return lanes }
        var copy = lanes
        let moved = copy.remove(at: from)
        copy.insert(moved, at: to)
        return copy
    }

    /// Which lane sits under a point in the strip's coordinate space.
    private func laneIndex(atX x: CGFloat, in lanes: [Lane]) -> Int? {
        guard !lanes.isEmpty else { return nil }
        var left: CGFloat = 0
        for (i, lane) in lanes.enumerated() {
            let right = left + CGFloat(lane.widthPt)
            if x < right { return i }
            left = right + Theme.borderWidth
        }
        return lanes.count - 1
    }

    // MARK: - geometry

    /// The strip's visible window, in the document's own coordinates.
    ///
    /// **The only place a dock is subtracted from anything.** An inset dock is
    /// already gone from `clip.bounds.width` — the clip view was made genuinely
    /// narrower — and an overlay is taken off here, because the strip keeps its
    /// room and loses only the view of it. Everything downstream takes an offset
    /// and a width: `LaneSnap`, `LanePeek`, `StripEdges`, `StripReveal`, the
    /// materialisation window and the eviction `Viewport` need to know nothing
    /// about docks, and cannot be the call site that forgot.
    private var viewport: (offset: CGFloat, width: CGFloat) {
        let clip = scrollView.contentView
        return DockGeometry.visible(
            clipOffset: clip.bounds.origin.x, clipWidth: clip.bounds.width, layout: dockLayout)
    }

    /// Where the clip view has to sit for the strip's visible window to start
    /// at `x`. The inverse of `viewport.offset`, and the only other place the
    /// overlay inset appears.
    private func clipOrigin(forVisible x: CGFloat) -> CGFloat { x - dockLayout.overlayLeft }

    /// How many lanes `laneId` is from the visible range. 0 when on screen,
    /// `.max` when it is not on the strip at all.
    ///
    /// A docked lane is 0 wherever its ordinal sits. It is on screen; "how far
    /// has it scrolled" is not a question that applies to it, and answering it
    /// with an index is how a music lane docked at ordinal 0 measures forty
    /// lanes away while the strip is scrolled to lane 40 — and gets deferred,
    /// unparented, and finally silenced.
    private func distanceFromViewport(laneId: String) -> UInt32 {
        guard store.lane(laneId)?.dock == nil else { return 0 }
        let lanes = store.stripLanes
        guard let index = lanes.firstIndex(where: { $0.id == laneId }) else { return .max }
        let visible = visibleLaneRange(in: lanes)
        if index < visible.lowerBound { return UInt32(visible.lowerBound - index) }
        if index >= visible.upperBound { return UInt32(index - visible.upperBound + 1) }
        return 0
    }

    /// Indices of the lanes at least partly on screen.
    ///
    /// `lanes` is always `stripLanes`. Every index this returns is an index into
    /// the array the strip actually laid out, which is the invariant the whole
    /// eviction guarantee rests on — see `StripStore.stripLanes`.
    private func visibleLaneRange(in lanes: [Lane]) -> Range<Int> {
        let window = viewport
        let origin = window.offset
        let width = window.width
        guard width > 0 else { return 0..<min(lanes.count, 1) }

        var x: CGFloat = 0
        var first: Int? = nil
        var last = 0
        for (i, lane) in lanes.enumerated() {
            let right = x + CGFloat(lane.widthPt)
            if right > origin && x < origin + width {
                if first == nil { first = i }
                last = i
            }
            x = right + Theme.borderWidth
            if x > origin + width { break }
        }
        guard let first else { return 0..<min(lanes.count, 1) }
        return first..<(last + 1)
    }

    // MARK: - scrolling

    @objc private func clipViewResized() {
        relayout()
        updateMaterialization()
        // A resize is the one event that can *create* the alignment this piece
        // exists to break: the lanes did not move, the window did, and a width
        // that now fits a whole number of them leaves the strip resting flush
        // with nothing peeking in from either side. Re-settling is the same
        // debounced snap a scroll gets, which is also what keeps it out of the
        // way of a live drag of the window's edge — it fires when the drag
        // pauses, not sixty times a second during it.
        scheduleSnap()
        // The strip got shorter or taller, so every terminal has a different
        // number of rows now. Same debounce as a width drag.
        for lane in store.state.lanes {
            for pane in lane.panes {
                (paneControllers[pane.id] as? TerminalPaneController)?
                    .laneWidthDidChange(to: CGFloat(lane.widthPt))
            }
        }
    }

    /// Tell the rails how much is off each end.
    ///
    /// Called from everything that can change the answer — a scroll, a resize, a
    /// lane arriving or leaving — rather than from a timer, because the count is
    /// only ever wrong for as long as it is stale, and the whole point of it is
    /// that it can be trusted at a glance. It is a filter over ≤150 slots, which
    /// is nothing beside the layout pass that provoked it.
    private func updateEdgeRails() {
        guard config.stripEdgeRails else { return }
        // The strip's *visible* window, which is why an overlay dock counts as
        // an edge here without `StripEdges` knowing docks exist. A lane hidden
        // under an overlay is hidden — saying otherwise is precisely the
        // "I can't tell if there are more panes to the right or left" failure
        // the rails were built for, re-introduced by the newer feature.
        let window = viewport
        let hidden = StripEdges.hidden(
            lanes: laneLayout, offset: window.offset, viewport: window.width)
        leadingRail.update(hidden: hidden.left)
        trailingRail.update(hidden: hidden.right)
    }

    @objc private func didScroll() {
        updateMaterialization()
        // The ledger write is debounced; the strip is not.
        scrollDebounce?.cancel()
        let x = Double(viewport.offset)
        let work = DispatchWorkItem { [weak self] in self?.store.setScrollX(x) }
        scrollDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        scheduleSnap()
    }

    // MARK: - snapping

    /// Settle the scroll with a lane centred, once the gesture stops.
    ///
    /// A strip is a row of columns and a scroll that stops between two of them
    /// leaves both half-readable, so you nudge it by hand — every time. The
    /// delay is what makes this feel like settling rather than fighting: it has
    /// to be longer than the gap between momentum events, or the strip would
    /// pull against a gesture that is still going.
    private func scheduleSnap() {
        guard config.snapToLanes, !isSnapping else { return }
        // A scroll the app asked for has already decided where to stop.
        // `reveal` centres deliberately, and `ensureVisible` deliberately does
        // not — arrow-key focus moves the strip as little as it can, and a snap
        // chasing it would undo exactly that.
        guard CFAbsoluteTimeGetCurrent() > suppressSnapUntil else { return }
        snapDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapToNearestLane() }
        snapDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func snapToNearestLane() {
        guard config.snapToLanes, !isSnapping else { return }
        let clip = scrollView.contentView
        let window = viewport
        // Nothing to snap to when the whole strip fits.
        guard window.width > 0, content.frame.width > window.width else { return }

        guard let target = LaneSnap.offset(
            forCentre: window.offset + window.width / 2,
            viewport: window.width,
            lanes: store.stripLanes,
            minPeek: CGFloat(config.lanePeekPt))
        else { return }

        // Within a couple of points is centred; moving anyway would look like a
        // twitch at the end of every scroll.
        guard abs(target - window.offset) > 2 else { return }

        isSnapping = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.snapSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(
                NSPoint(x: self.clipOrigin(forVisible: target), y: clip.bounds.origin.y))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isSnapping = false
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateMaterialization()
        }
    }

    // The arithmetic lives in `LaneSnap`, below: it needs no view and no
    // store, and clamping is worth testing on its own.

    /// Centre a lane and optionally flash its border — PRD §7.5's
    /// search-to-scroll, and what the sidebar does on click.
    ///
    /// The target comes from `StripReveal`, off the ledger's lanes, and not from
    /// `content.frame.width`: see that type for why a view's width is the wrong
    /// ruler at exactly the moment this matters most.
    public func reveal(laneId: String, flash: Bool) {
        // A docked lane is already on screen and cannot be scrolled to. ⌘P and
        // the sidebar still land on it, so the flash is the whole of the answer
        // — and without this they would silently do nothing at all.
        if store.lane(laneId)?.dock != nil {
            if flash { laneViews[laneId]?.flash() }
            return
        }
        guard let target = StripReveal.centred(
            on: laneId,
            lanes: store.stripLanes,
            viewport: viewport.width,
            // The same peek the snap takes. ⌘P lands you somewhere you have
            // never been, which is the moment "is there more that way" matters
            // most, and a reveal that centres perfectly onto a clean edge
            // answers it wrongly.
            peek: CGFloat(config.lanePeekPt))
        else { return }
        scroll(to: target, revealing: laneId, flash: flash)
    }

    /// Move the strip to `target`, by whichever clock is already running.
    ///
    /// Three cases, and only the first is new. A lane whose column is *still
    /// opening* hands its scroll to that column's transition, so the arrival and
    /// the scroll are one movement rather than a sideways jolt with no cause on
    /// screen — and, less prettily, so that the scroll is not clamped by a
    /// document view that has not finished growing. Reduce Motion goes straight
    /// to the answer. Everything else takes the same 0.22 s ease-out every other
    /// transition in the strip takes; it used to take 0.25, for no reason anyone
    /// wrote down, which is a quarter of a frame's worth of disagreement between
    /// a lane opening and the strip moving to show it.
    private func scroll(to target: CGFloat, revealing laneId: String, flash: Bool) {
        let clip = scrollView.contentView
        // `target` came from `StripReveal`, which works in the strip's visible
        // window. Everything below is in that space and converts once, at the
        // line that actually moves the clip view.
        let from = viewport.offset
        // Reaching past the end of the column's own animation. Set only when the
        // strip is actually going somewhere: a reveal that turns out to be a
        // no-op has decided nothing, and muting the snap for half a second on
        // the strength of it would leave a scroll the user made unsettled.
        func holdOffTheSnap() {
            suppressSnapUntil = CFAbsoluteTimeGetCurrent() + Motion.lane + 0.4
        }

        if transitions[laneId] != nil, laneOverrides[laneId]?.masked == true {
            arrivalScroll = (laneId, from, target, flash)
            holdOffTheSnap()
            return
        }

        guard abs(target - from) > 0.5 else {
            if flash { laneViews[laneId]?.flash() }
            return
        }
        holdOffTheSnap()
        guard !Motion.isReduced, view.window != nil else {
            clip.setBoundsOrigin(
                NSPoint(x: clipOrigin(forVisible: target), y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
            updateMaterialization()
            if flash { laneViews[laneId]?.flash() }
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.lane
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(
                NSPoint(x: self.clipOrigin(forVisible: target), y: clip.bounds.origin.y))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateMaterialization()
            if flash { self.laneViews[laneId]?.flash() }
        }
    }

    // MARK: - focus

    public enum FocusDirection { case left, right, up, down }

    public func moveFocus(_ direction: FocusDirection) {
        let state = store.state
        // ⌘[ / ⌘] walk the strip only. The owner asked for that directly, and
        // it is right for a reason worth keeping: those keys scroll the strip,
        // and a docked lane does not scroll — landing on one would be a
        // keypress with no motion and a focus ring that jumped across the
        // window and back. ⌥⌘[ / ⌥⌘] are the way into a dock and back out.
        let lanes = store.stripLanes
        guard let currentPane = state.focusedPaneId else {
            if let first = lanes.first?.panes.first { focus(first.id) }
            return
        }
        if let dock = store.lane(containing: currentPane), dock.dock != nil {
            moveFocusInsideDock(dock, from: currentPane, direction: direction, strip: lanes)
            return
        }
        guard let laneIndex = lanes.firstIndex(
            where: { $0.panes.contains { $0.id == currentPane } })
        else {
            if let first = lanes.first?.panes.first { focus(first.id) }
            return
        }
        let lane = lanes[laneIndex]
        let paneIndex = lane.panes.firstIndex { $0.id == currentPane } ?? 0

        switch direction {
        case .left where laneIndex > 0:
            // Land on the pane at the same height, or the nearest one.
            let target = lanes[laneIndex - 1]
            focus(target.panes[min(paneIndex, target.panes.count - 1)].id)
        case .right where laneIndex + 1 < lanes.count:
            let target = lanes[laneIndex + 1]
            focus(target.panes[min(paneIndex, target.panes.count - 1)].id)
        case .up where paneIndex > 0:
            focus(lane.panes[paneIndex - 1].id)
        case .down where paneIndex + 1 < lane.panes.count:
            focus(lane.panes[paneIndex + 1].id)
        default:
            break
        }
    }

    /// The arrow keys with focus inside a dock.
    ///
    /// **⇧⌘[ / ⇧⌘] work unchanged**, because a docked lane is still a lane: it
    /// can hold a stack, ⇧⌘D splits it, and the keys that walk that stack must
    /// keep working at the wall or docking would quietly take a feature away
    /// from whatever lane it was used on. The end of the stack is the end of
    /// it — no wrapping out into the strip, which would be a keypress that
    /// sometimes moves one pane and sometimes jumps across the window.
    ///
    /// ⌘[ / ⌘] go back to the strip instead of doing nothing, and land on the
    /// lane focused most recently — the one you were last working in, and
    /// therefore almost certainly still on screen. Never the first lane of the
    /// strip: on a strip of forty that is a jump to somewhere the user has not
    /// been in an hour. ⌥⌘[ / ⌥⌘] remain the deliberate way out.
    private func moveFocusInsideDock(
        _ lane: Lane, from paneId: String, direction: FocusDirection, strip: [Lane]
    ) {
        let index = lane.panes.firstIndex { $0.id == paneId } ?? 0
        switch direction {
        case .up where index > 0:
            focus(lane.panes[index - 1].id)
        case .down where index + 1 < lane.panes.count:
            focus(lane.panes[index + 1].id)
        case .up, .down:
            break
        case .left, .right:
            guard let back = strip.max(by: { $0.lastFocusAt < $1.lastFocusAt })?.panes.first
            else { return }
            focus(back.id)
        }
    }

    private func focus(_ paneId: String) {
        store.noteFocus(paneId)
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        paneControllers[paneId]?.takeFocus()
        ensureVisible(laneId)
    }

    /// Scroll only far enough to bring a lane fully on screen. Unlike `reveal`,
    /// this does not recentre — arrow-key focus that jumps the strip around is
    /// disorienting.
    ///
    /// No peek here either, for the same reason: this moves the strip as little
    /// as it can, and shaving 28 pt off the lane the user just focused to prove
    /// that another one exists is worse than the ambiguity it fixes. The snap
    /// that follows the next scroll picks it up.
    private func ensureVisible(_ laneId: String) {
        // Focusing a dock moves nothing: it is already at the wall, and
        // scrolling the strip to "reach" it would move every lane the user was
        // reading for no reason they could see.
        guard store.lane(laneId)?.dock == nil else { return }
        let window = viewport
        guard let target = StripReveal.minimal(
            from: window.offset, to: laneId,
            lanes: store.stripLanes, viewport: window.width)
        else { return }
        scroll(to: target, revealing: laneId, flash: false)
    }

    // MARK: - eviction (§10.3)

    /// Ask `laned-core` what to do with every pane, then do it.
    ///
    /// The policy is in Rust so there is one place to reason about it; the two
    /// facts only the shell knows — what WebKit actually weighs, and where the
    /// viewport is — are measured here and handed over.
    private func applyEvictionPlan(for state: StripState) {
        guard !state.lanes.isEmpty else { return }
        // Indices into the array the strip actually laid out. `eviction::plan`
        // removes docked lanes the same way before it indexes, so the two agree
        // by construction — send indices into `state.lanes` instead and the
        // core plans against a strip shifted by one per docked lane, and evicts
        // the pane the user is looking at.
        let visible = visibleLaneRange(in: store.stripLanes)
        let viewport = Viewport(
            firstVisible: UInt32(visible.lowerBound),
            lastVisible: UInt32(max(visible.lowerBound, visible.upperBound - 1)))
        let memory = MemoryReport(
            webContentRssBytes: WebProcessMemory.currentBytes(),
            softBudgetBytes: config.webMemorySoftBytes,
            hardBudgetBytes: config.webMemoryHardBytes,
            targetBytes: config.webMemoryTargetBytes,
            // Attributing a WebKit process to a pane needs
            // `_webProcessIdentifier`, which is private API this app does not
            // use. The policy falls back to distance and recency when this is
            // empty, which is the ordering the PRD specifies anyway. ADR-0003.
            paneFootprints: [])

        for directive in store.planEviction(viewport: viewport, memory: memory) {
            guard let controller = paneControllers[directive.paneId] else { continue }
            switch directive.action {
            case .keep:
                controller.reparentIfNeeded()
            case .unparent:
                controller.unparent()
            case .evict:
                controller.evict()
            case .rehydrate:
                controller.rehydrate()
            }
        }
    }

    // MARK: - lookups used by the window controller

    /// ADR-0007 §5's escape hatch, routed to the pane that owns the session.
    public func claimSession(paneId: String) {
        (paneControllers[paneId] as? TerminalPaneController)?.claimSessionAtLaneWidth()
    }

    /// A pty pane's current working directory, for spawning a sibling in the
    /// right place (PRD §7.1).
    public func cwd(ofPane paneId: String) -> String? {
        (paneControllers[paneId] as? TerminalPaneController)?.currentCwd
    }

    /// Which lane holds the terminal attached to `sessionId`, for the
    /// `maxpane-open` shim.
    public func lane(forRelaySession sessionId: String) -> String? {
        store.state.lanes.first { $0.panes.contains { $0.relaySessionId == sessionId } }?.id
    }

    /// RelayTTY's session directory changed.
    ///
    /// A session that has gone leaves its lane exactly where it is (PRD §11:
    /// "the lane and ordinal are unaffected"); the pane says so instead. A
    /// session that has come back is reattached.
    public func sessionsChanged(_ telemetry: [String: SessionTelemetry]) {
        let live = Set(telemetry.values.filter(\.isRunning).map(\.sessionId))
        laneTelemetry = telemetry
        for (_, laneView) in laneViews {
            laneView.applyTelemetry(telemetry)
        }
        for (paneId, controller) in paneControllers {
            guard let terminal = controller as? TerminalPaneController,
                  let sessionId = store.pane(paneId)?.relaySessionId
            else { continue }
            terminal.sessionAvailabilityChanged(live.contains(sessionId))
        }
    }
}

/// The strip's document view. Lanes are positioned by summing widths, because
/// they do not all have the same one.
@MainActor
final class StripContentView: NSView {
    private var totalWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    /// Position every materialised lane and size the document view to the whole
    /// strip, including the lanes that have no view right now — otherwise the
    /// scroller would only span what happens to be built.
    /// `overrides` and `xOffsets` are what animation looks like from here: a
    /// lane whose slot in the row is narrower than the ledger says because its
    /// column is opening or closing, and a lane drawn beside its slot because it
    /// is still sliding into it. Both are transient and neither is ever written
    /// anywhere — the snapshot stays the only truth about how wide a lane is and
    /// where it sits.
    func layOut(
        lanes: [Lane], viewFor: (Lane) -> LaneView?,
        overrides: [String: LaneOverride] = [:],
        xOffsets: [String: CGFloat] = [:]
    ) {
        var x: CGFloat = 0
        // The clip view's height, not our own: our height is what we are about
        // to set, so reading it here would latch whatever it was last frame —
        // zero, on the first pass.
        let height = superview?.bounds.height ?? bounds.height
        guard height > 0 else { return }
        for lane in lanes {
            let override = overrides[lane.id]
            let slot = override?.slot ?? CGFloat(lane.widthPt)
            // A masked lane keeps its real width — only its slot is narrow —
            // so the pane inside it is never resized by a transition.
            let drawn = (override?.masked ?? false) ? CGFloat(lane.widthPt) : slot
            if let laneView = viewFor(lane) {
                laneView.frame = NSRect(
                    x: x + (xOffsets[lane.id] ?? 0), y: 0, width: drawn, height: height)
                // After the frame: the mask is in the lane's own coordinates.
                laneView.revealWidth = (override?.masked ?? false) ? slot : nil
            }
            x += slot + Theme.borderWidth
        }
        totalWidth = x
        if frame.width != totalWidth || frame.height != height {
            frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)
        }
    }
}


/// Where a horizontal scroll should come to rest.
///
/// Separated from the view because it is all arithmetic, and because clamping
/// is where an off-by-a-lane hides: the first and last lanes cannot be centred,
/// and pretending otherwise scrolls past the end of the strip.
enum LaneSnap {
    /// The scroll offset that centres whichever lane is nearest `centre`, or
    /// nil when there are no lanes.
    ///
    /// `minPeek` is the second half of the rule, and it runs *after* the
    /// centring rather than instead of it: centre the lane, then — only if that
    /// leaves the screen flush with a lane boundary while the strip continues
    /// past it — slide by up to `minPeek` so a sliver of the next lane shows.
    /// `LanePeek` argues the case; the bound is that no snap ever lands more
    /// than `minPeek` from centred.
    static func offset(
        forCentre centre: CGFloat, viewport: CGFloat, lanes: [Lane], minPeek: CGFloat = 0
    ) -> CGFloat? {
        var x: CGFloat = 0
        var best: (distance: CGFloat, origin: CGFloat, width: CGFloat)?
        for lane in lanes {
            let width = CGFloat(lane.widthPt)
            let distance = abs((x + width / 2) - centre)
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (distance, x, width)
            }
            x += width + Theme.borderWidth
        }
        guard let best else { return nil }

        let centred = best.origin - (viewport - best.width) / 2
        let clamped = min(max(0, centred), max(0, x - viewport))
        return LanePeek.adjust(
            offset: clamped, viewport: viewport, lanes: lanes, minimum: minPeek)
    }
}
