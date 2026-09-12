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
    /// `(lane, width)` while its right edge is being dragged. View-only.
    private var liveResize: (laneId: String, width: CGFloat)?
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
        emptyState.isHidden = !state.lanes.isEmpty
        let wanted = Set(state.lanes.map(\.id))

        // Lanes that went away take their panes with them.
        for (id, laneView) in laneViews where !wanted.contains(id) {
            retire(laneView, laneId: id, destroyPanes: true)
        }

        content.layOut(lanes: state.lanes, viewFor: { [weak self] lane in self?.laneViews[lane.id] })
        updateMaterialization()

        for lane in state.lanes {
            laneViews[lane.id]?.apply(lane)
            laneViews[lane.id]?.isFocused = state.focusedPaneId.map { id in
                lane.panes.contains { $0.id == id }
            } ?? false
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
        let visible = visibleLaneRange(in: state)
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

        for (id, laneView) in laneViews where !wanted.contains(id) {
            // Off the window: recycle the chrome, keep the panes alive.
            retire(laneView, laneId: id, destroyPanes: false)
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

        content.layOut(lanes: state.lanes, viewFor: { [weak self] lane in self?.laneViews[lane.id] })
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
                self.liveResize = nil
                try? self.store.setLaneWidth(lane.id, width)

            } else {
                // Lay out live. Without this the lane only jumps to its new
                // width on mouse-up, which reads as the drag not working at all.
                // Still no ledger write until the drop — §6 wants one commit per
                // decision, not sixty a second.
                self.liveResize = (lane.id, CGFloat(width))
                self.content.layOut(
                    lanes: self.store.state.lanes,
                    viewFor: { [weak self] l in self?.laneViews[l.id] },
                    widthOverride: self.liveResize)
            }
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

        for (position, pane) in lane.panes.enumerated() {
            let controller = paneControllers[pane.id] ?? makeController(for: pane, in: lane)
            paneControllers[pane.id] = controller
            controller.apply(pane)
            laneView.setPaneView(controller.view, for: pane.id, at: position)
        }
    }

    private func retire(_ laneView: LaneView, laneId: String, destroyPanes: Bool) {
        if destroyPanes {
            for paneId in laneView.installedPaneIds {
                paneControllers[paneId]?.tearDown()
                paneControllers[paneId] = nil
                SnapshotStore.remove(for: paneId)
            }
        }
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
            content.layOut(lanes: reordered(state.lanes, from: from, to: target),
                           viewFor: { [weak self] lane in self?.laneViews[lane.id] })
            return
        }

        dragPreview = nil
        guard target != from else {
            // Dropped where it started. Re-lay out so the preview does not stick.
            content.layOut(lanes: state.lanes, viewFor: { [weak self] lane in self?.laneViews[lane.id] })
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
        let visible = visibleLaneRange(in: state)
        if index < visible.lowerBound { return UInt32(visible.lowerBound - index) }
        if index >= visible.upperBound { return UInt32(index - visible.upperBound + 1) }
        return 0
    }

    private func visibleLaneRange(in state: StripState) -> Range<Int> {
        let origin = scrollView.contentView.bounds.origin.x
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return 0..<min(state.lanes.count, 1) }

        var x: CGFloat = 0
        var first: Int? = nil
        var last = 0
        for (i, lane) in state.lanes.enumerated() {
            let right = x + CGFloat(lane.widthPt)
            if right > origin && x < origin + width {
                if first == nil { first = i }
                last = i
            }
            x = right + Theme.borderWidth
            if x > origin + width { break }
        }
        guard let first else { return 0..<min(state.lanes.count, 1) }
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
        content.layOut(lanes: store.state.lanes, viewFor: { [weak self] lane in self?.laneViews[lane.id] })
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
    }

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
        let visible = visibleLaneRange(in: state)
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
    func layOut(
        lanes: [Lane], viewFor: (Lane) -> LaneView?,
        widthOverride: (laneId: String, width: CGFloat)? = nil
    ) {
        var x: CGFloat = 0
        // The clip view's height, not our own: our height is what we are about
        // to set, so reading it here would latch whatever it was last frame —
        // zero, on the first pass.
        let height = superview?.bounds.height ?? bounds.height
        guard height > 0 else { return }
        for lane in lanes {
            let width = (widthOverride?.laneId == lane.id ? widthOverride?.width : nil)
                ?? CGFloat(lane.widthPt)
            if let laneView = viewFor(lane) {
                laneView.frame = NSRect(x: x, y: 0, width: width, height: height)
            }
            x += width + Theme.borderWidth
        }
        totalWidth = x
        if frame.width != totalWidth || frame.height != height {
            frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)
        }
    }
}
