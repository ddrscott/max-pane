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
    private var transitions: [String: RunningAnimation] = [:]
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

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
            self.scrollView.contentView.scroll(to: NSPoint(x: self.store.state.scrollX, y: 0))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateMaterialization()
            // Launch is over: from here on, a new pane loads immediately.
            // Anything still deferred stays deferred until it is scrolled to.
            self.isColdLaunch = false
        }
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

            let clip = self.scrollView.contentView
            // Trackpads report points; a mouse wheel reports lines.
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 16
            let maxX = max(0, self.content.frame.width - clip.bounds.width)
            let next = min(max(0, clip.bounds.origin.x - step), maxX)
            clip.setBoundsOrigin(NSPoint(x: next, y: clip.bounds.origin.y))
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
        let diff = StripDiff.between(previous.map(\.id), state.lanes.map(\.id))

        // What arrived, before anything is laid out: a lane whose column is
        // about to open must never take its full slot first, not even for the
        // one frame between here and its first animation tick.
        beginArrivals(diff.inserted, in: state)

        // Lanes that went away. A lane whose column is still closing keeps its
        // view and its slot; one that is not animating goes now.
        for departure in diff.removed {
            guard let laneView = laneViews[departure.id] else { continue }
            guard let lane = previous.first(where: { $0.id == departure.id }),
                  shouldAnimate(laneAt: departure.index, in: previous)
            else {
                retire(laneView, laneId: departure.id)
                continue
            }
            beginDeparture(lane, at: departure.index, view: laneView)
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

        // Lanes that changed place. Measured in points between the two
        // snapshots rather than in indices, because that is the distance the
        // user's eye has to follow.
        beginMoves(diff.moved, from: previous, to: state.lanes)

        for lane in state.lanes {
            laneViews[lane.id]?.apply(lane)
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
    private func materializationWindow(for state: StripState) -> Range<Int> {
        let visible = visibleLaneRange(in: state.lanes)
        let slack = Int(config.releaseDistance)
        let lower = max(0, visible.lowerBound - slack)
        let upper = min(state.lanes.count, visible.upperBound + slack)
        return lower..<max(lower, upper)
    }

    private func updateMaterialization() {
        let state = store.state
        guard !state.lanes.isEmpty else { return }
        let window = materializationWindow(for: state)
        let wanted = Set(state.lanes[window].map(\.id))

        for (id, laneView) in laneViews where !wanted.contains(id) && !isDeparting(id) {
            // Off the window: recycle the chrome, keep the panes alive. A lane
            // whose column is still closing is not off the window — it is not in
            // the snapshot at all, and recycling it mid-collapse would make it
            // vanish, which is the cut this exists to remove.
            retire(laneView, laneId: id)
        }
        for lane in state.lanes[window] where laneViews[lane.id] == nil {
            materialize(lane)
        }

        // Anything deferred that has come close enough gets built now. This is
        // the other half of lazy launch: §13 defers, and scrolling to a lane is
        // what undefers it.
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
        laneView.widthBounds = config.widthRange.lowerBound...(config.laneMaxPt * max(lane.span, 1))
        laneView.onHeaderDrag = { [weak self] x, isFinal in
            self?.handleLaneDrag(laneId: lane.id, toX: x, isFinal: isFinal)
        }
        laneView.onHeaderDoubleClick = { [weak self] in
            guard let self, let root = self.store.lane(lane.id)?.projectRoot else { return }
            try? self.store.gather(projectRoot: root)
        }

        laneViews[lane.id] = laneView
        laneView.applyTelemetry(laneTelemetry)
        content.addSubview(laneView)

        // A recycled view arrives holding another lane's panes; a fresh one
        // holds none. Both are just "the stack does not match the snapshot", so
        // both go through the same reconcile — never animated, because
        // materialising is what happens when a lane scrolls *back* into range,
        // and a lane you scrolled to has not appeared, it was always there.
        reconcilePanes(of: lane, in: laneView, animated: false)
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
        guard store.state.focusedPaneId == paneId,
              let lane = store.lane(containing: paneId),
              let index = store.state.lanes.firstIndex(where: { $0.id == lane.id })
        else { return }
        // The lane to the right inherits the column the closing one is leaving,
        // so it is the one the eye is already on.
        let neighbours = [index + 1, index - 1].compactMap { i -> Lane? in
            guard i >= 0, i < store.state.lanes.count else { return nil }
            let candidate = store.state.lanes[i]
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
        guard !departingLanes.isEmpty else { return store.state.lanes }
        var lanes = store.state.lanes
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
        content.layOut(
            lanes: lanes ?? laneLayout,
            viewFor: { [weak self] lane in self?.laneViews[lane.id] },
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
    private func beginArrivals(_ laneIds: [String], in state: StripState) {
        for id in laneIds {
            guard let index = state.lanes.firstIndex(where: { $0.id == id }),
                  shouldAnimate(laneAt: index, in: state.lanes)
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
            } completion: { [weak self] in
                guard let self else { return }
                laneView.alphaValue = 1
                self.laneOverrides[id] = nil
                self.relayout()
            }
        }
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
        transitions.removeValue(forKey: laneId)?.timer?.invalidate()
        guard !Motion.isReduced, view.window != nil else {
            step(1)
            completion()
            return
        }
        transitions[laneId] = animate(duration: duration, step: step) { [weak self] in
            self?.transitions[laneId] = nil
            completion()
        }
    }

    /// Run `step` with eased progress 0…1 over `duration`, then `completion`.
    ///
    /// A timer rather than Core Animation because what is being animated is not
    /// a view property: the strip's layout is computed from lane widths, and the
    /// collapse has to run through that same layout or the lanes to the right
    /// would not move with it.
    @discardableResult
    private func animate(
        duration: TimeInterval,
        step: @escaping @MainActor (CGFloat) -> Void,
        completion: @escaping @MainActor () -> Void
    ) -> RunningAnimation {
        let start = CACurrentMediaTime()
        // Scheduled on the main run loop in `.common`, so the block is already
        // on the main thread — `assumeIsolated` states that rather than hopping
        // through a Task, which would deliver frames a run loop late and let the
        // timer fire again before the last frame drew.
        let running = RunningAnimation()
        running.timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                step(CGFloat(t))
                if t >= 1 {
                    running.timer?.invalidate()
                    completion()
                }
            }
        }
        RunLoop.main.add(running.timer!, forMode: .common)
        return running
    }

    /// Holds the timer so the block can stop the thing that is running it —
    /// the block's own `Timer` argument is not main-actor isolated.
    @MainActor
    private final class RunningAnimation {
        var timer: Timer?
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

    /// Ask every live pane to write down what it would otherwise lose.
    ///
    /// Only web panes have anything to say — their history and scroll live in
    /// WebKit until someone asks — and only the ones that were built: a pane
    /// scrolled far off the strip has no controller and nothing in flight.
    public func flushPaneState() {
        for controller in paneControllers.values { controller.flushState() }
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
            return WebPaneController(
                pane: pane, lane: lane, store: store, config: config,
                deferLoad: isColdLaunch && distanceFromViewport(laneId: lane.id) > config.rehydrateDistance)
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
        let state = store.state
        guard let target = laneIndex(atX: x, in: state),
              let from = state.lanes.firstIndex(where: { $0.id == laneId })
        else { return }

        guard isFinal else {
            // Live feedback without a write: slide the dragged lane's view to
            // where it would land.
            dragPreview = (laneId, target)
            relayout(lanes: reordered(state.lanes, from: from, to: target))
            return
        }

        dragPreview = nil
        guard target != from else {
            // Dropped where it started. Re-lay out so the preview does not stick.
            relayout()
            return
        }

        let neighbour = state.lanes[target]
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
    private func laneIndex(atX x: CGFloat, in state: StripState) -> Int? {
        guard !state.lanes.isEmpty else { return nil }
        var left: CGFloat = 0
        for (i, lane) in state.lanes.enumerated() {
            let right = left + CGFloat(lane.widthPt)
            if x < right { return i }
            left = right + Theme.borderWidth
        }
        return state.lanes.count - 1
    }

    // MARK: - geometry

    /// Indices of the lanes at least partly on screen.
    /// How many lanes `laneId` is from the visible range. 0 when on screen,
    /// `.max` when it is not on the strip at all.
    private func distanceFromViewport(laneId: String) -> UInt32 {
        let state = store.state
        guard let index = state.lanes.firstIndex(where: { $0.id == laneId }) else { return .max }
        let visible = visibleLaneRange(in: state.lanes)
        if index < visible.lowerBound { return UInt32(visible.lowerBound - index) }
        if index >= visible.upperBound { return UInt32(index - visible.upperBound + 1) }
        return 0
    }

    private func visibleLaneRange(in lanes: [Lane]) -> Range<Int> {
        let origin = scrollView.contentView.bounds.origin.x
        let width = scrollView.contentView.bounds.width
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

    private func originOfLane(_ laneId: String, in state: StripState) -> CGFloat? {
        var x: CGFloat = 0
        for lane in state.lanes {
            if lane.id == laneId { return x }
            x += CGFloat(lane.widthPt) + Theme.borderWidth
        }
        return nil
    }

    // MARK: - scrolling

    @objc private func clipViewResized() {
        relayout()
        updateMaterialization()
        // The strip got shorter or taller, so every terminal has a different
        // number of rows now. Same debounce as a width drag.
        for lane in store.state.lanes {
            for pane in lane.panes {
                (paneControllers[pane.id] as? TerminalPaneController)?
                    .laneWidthDidChange(to: CGFloat(lane.widthPt))
            }
        }
    }

    @objc private func didScroll() {
        updateMaterialization()
        // The ledger write is debounced; the strip is not.
        scrollDebounce?.cancel()
        let x = Double(scrollView.contentView.bounds.origin.x)
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
        let viewport = clip.bounds.width
        // Nothing to snap to when the whole strip fits.
        guard viewport > 0, content.frame.width > viewport else { return }

        guard let target = LaneSnap.offset(
            forCentre: clip.bounds.origin.x + viewport / 2,
            viewport: viewport,
            lanes: store.state.lanes)
        else { return }

        // Within a couple of points is centred; moving anyway would look like a
        // twitch at the end of every scroll.
        guard abs(target - clip.bounds.origin.x) > 2 else { return }

        isSnapping = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = config.snapSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
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
    public func reveal(laneId: String, flash: Bool) {
        let state = store.state
        guard let origin = originOfLane(laneId, in: state),
              let lane = state.lanes.first(where: { $0.id == laneId })
        else { return }

        let viewportWidth = scrollView.contentView.bounds.width
        let centred = origin - (viewportWidth - CGFloat(lane.widthPt)) / 2
        let maxX = max(0, content.frame.width - viewportWidth)
        let target = NSPoint(x: min(max(0, centred), maxX), y: 0)

        suppressSnapUntil = CFAbsoluteTimeGetCurrent() + 0.6
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(target)
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
        guard let currentPane = state.focusedPaneId,
              let laneIndex = state.lanes.firstIndex(where: { $0.panes.contains { $0.id == currentPane } })
        else {
            if let first = state.lanes.first?.panes.first { focus(first.id) }
            return
        }
        let lane = state.lanes[laneIndex]
        let paneIndex = lane.panes.firstIndex { $0.id == currentPane } ?? 0

        switch direction {
        case .left where laneIndex > 0:
            // Land on the pane at the same height, or the nearest one.
            let target = state.lanes[laneIndex - 1]
            focus(target.panes[min(paneIndex, target.panes.count - 1)].id)
        case .right where laneIndex + 1 < state.lanes.count:
            let target = state.lanes[laneIndex + 1]
            focus(target.panes[min(paneIndex, target.panes.count - 1)].id)
        case .up where paneIndex > 0:
            focus(lane.panes[paneIndex - 1].id)
        case .down where paneIndex + 1 < lane.panes.count:
            focus(lane.panes[paneIndex + 1].id)
        default:
            break
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
    private func ensureVisible(_ laneId: String) {
        let state = store.state
        guard let origin = originOfLane(laneId, in: state),
              let lane = state.lanes.first(where: { $0.id == laneId })
        else { return }
        let viewport = scrollView.contentView.bounds
        let right = origin + CGFloat(lane.widthPt)

        var x = viewport.origin.x
        if origin < viewport.minX { x = origin }
        else if right > viewport.maxX { x = right - viewport.width }
        guard x != viewport.origin.x else { return }

        suppressSnapUntil = CFAbsoluteTimeGetCurrent() + 0.6
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: max(0, x), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - eviction (§10.3)

    /// Ask `laned-core` what to do with every pane, then do it.
    ///
    /// The policy is in Rust so there is one place to reason about it; the two
    /// facts only the shell knows — what WebKit actually weighs, and where the
    /// viewport is — are measured here and handed over.
    private func applyEvictionPlan(for state: StripState) {
        let visible = visibleLaneRange(in: state.lanes)
        guard !state.lanes.isEmpty else { return }
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
    static func offset(forCentre centre: CGFloat, viewport: CGFloat, lanes: [Lane]) -> CGFloat? {
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
        return min(max(0, centred), max(0, x - viewport))
    }
}
