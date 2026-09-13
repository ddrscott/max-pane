import Foundation
import LanedCore

/// The only thing in the app that talks to `laned-core`.
///
/// Everything durable lives in Rust (PRD §5.2: the app "owns no durable state").
/// This is the seam: views ask the store to do something, the store calls the
/// core, the core commits to SQLite and hands back a snapshot, and the store
/// publishes it for the strip to diff against what is already on screen.
///
/// Nothing here caches a mutation optimistically. If the write fails, the strip
/// on screen is still the truth, which is the whole point of committing before
/// animating.
@MainActor
public final class StripStore {
    /// The snapshot currently on screen.
    public private(set) var state: StripState

    private let core: Core
    private var observers: [UUID: (StripState) -> Void] = [:]

    /// Where the ledger lives. PRD §6.
    ///
    /// The profile decides, which is how the app gets driven — by a test, a
    /// critic, or anyone poking at it — without touching the strip someone is
    /// working in. `--profile test` moves the ledger, the socket, the config and
    /// the cookie jars together; pointing only the ledger somewhere else is
    /// still possible with `MAXPANE_LEDGER`, and is still a half-isolated
    /// instance whose CLI talks to whoever holds the default socket.
    public static var defaultLedgerPath: String { Profile.current.ledgerPath }

    /// `laneDefaultPt` is stated once, here, before anything can create a lane.
    ///
    /// The core keeps its own `LANE_DEFAULT_PT` for callers that never say — the
    /// Rust tests, the CLI — but for this app the config file is now the only
    /// answer. It used to be two answers that happened to agree: `create_lane`
    /// read the Rust constant, so editing `laneDefaultPt` in
    /// `~/.config/maxpane/config.json` changed the width of precisely nothing.
    public init(
        ledgerPath: String = StripStore.defaultLedgerPath,
        laneDefaultPt: UInt32? = nil
    ) throws {
        core = try Core.open(path: ledgerPath)
        if let laneDefaultPt { core.setDefaultLaneWidth(widthPt: laneDefaultPt) }
        state = try core.state()
    }

    // MARK: - observation

    /// Watch for snapshot changes. The closure fires on the main actor,
    /// immediately with the current state and then after every mutation.
    @discardableResult
    func observe(_ body: @escaping (StripState) -> Void) -> UUID {
        let token = UUID()
        observers[token] = body
        body(state)
        return token
    }

    func stopObserving(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// Adopt a snapshot the core just produced.
    ///
    /// `revision` is compared first because spike M3 measured a 300-lane
    /// snapshot at 2.4 ms, 88% of it marshalling — re-rendering an identical
    /// strip is the one cost worth never paying.
    private func publish(_ next: StripState) {
        guard next.revision != state.revision || next.gatherFilter != state.gatherFilter else { return }
        state = next
        for body in observers.values { body(next) }
    }

    /// Pull a fresh snapshot only if the core has moved since the last one.
    /// Used by the background pollers, which mutate through cheap calls that do
    /// not return a snapshot of their own.
    func refreshIfChanged() {
        guard core.revision() != state.revision else { return }
        if let next = try? core.state() { publish(next) }
    }

    // MARK: - creation

    /// A new terminal lane (⌘T). PRD §7.1: immediately right of the focused
    /// lane, tag inherited from it and then refreshed from cwd.
    func newTerminalLane(relaySessionId: String, near laneId: String?) throws {
        publish(try core.createLane(
            placement: laneId.map { .rightOf(laneId: $0) } ?? .end,
            kind: .pty,
            relaySessionId: relaySessionId,
            url: nil,
            inheritTagFromLane: laneId))
    }

    /// A new web lane (⌘L, or a URL opened from a terminal).
    func newWebLane(url: String, near laneId: String?) throws {
        publish(try core.createLane(
            placement: laneId.map { .rightOf(laneId: $0) } ?? .end,
            kind: .web,
            relaySessionId: nil,
            url: url,
            inheritTagFromLane: laneId))
    }

    /// An attached session with no parent lane goes to the end of the strip
    /// (PRD §7.1, §7.2 — "unattributed new lanes append at the end").
    func attachSessionAtEnd(relaySessionId: String) throws {
        publish(try core.createLane(
            placement: .end, kind: .pty, relaySessionId: relaySessionId, url: nil, inheritTagFromLane: nil))
    }

    /// Split down (⌘D): another pane in the same lane's stack.
    func addPane(to laneId: String, kind: PaneKind, relaySessionId: String?, url: String?) throws {
        publish(try core.addPane(laneId: laneId, kind: kind, relaySessionId: relaySessionId, url: url))
    }

    // MARK: - removal

    func closeLane(_ laneId: String) throws { publish(try core.closeLane(laneId: laneId)) }
    func closePane(_ paneId: String) throws { publish(try core.closePane(paneId: paneId)) }

    // MARK: - ordering

    func moveLane(_ laneId: String, rightOf target: String) throws {
        publish(try core.moveLane(laneId: laneId, placement: .rightOf(laneId: target)))
    }

    func moveLane(_ laneId: String, leftOf target: String) throws {
        publish(try core.moveLane(laneId: laneId, placement: .leftOf(laneId: target)))
    }

    /// ⌘⇧← / ⌘⇧→.
    func nudgeLane(_ laneId: String, right: Bool) throws {
        publish(try core.nudgeLane(laneId: laneId, right: right))
    }

    // MARK: - attributes

    func setLaneWidth(_ laneId: String, _ widthPt: UInt32) throws {
        publish(try core.setLaneWidth(laneId: laneId, widthPt: widthPt))
    }

    /// A seam drag, committed. Only the two panes it moved.
    func setPaneHeights(_ weights: [(paneId: String, weight: Double)]) throws {
        guard !weights.isEmpty else { return }
        publish(try core.setPaneHeights(
            weights: weights.map { PaneHeight(paneId: $0.paneId, weight: $0.weight) }))
    }

    func setLaneTitle(_ laneId: String, _ title: String?) throws {
        publish(try core.setLaneTitle(laneId: laneId, title: title))
    }

    /// PRD §13 Phase 3's landscape exception. 1 or 2; the core clamps.
    func setLaneSpan(_ laneId: String, _ span: UInt32) throws {
        publish(try core.setLaneSpan(laneId: laneId, span: span))
    }

    /// Protect a lane's web panes from eviction. ⇧⌘P, formerly "Pin Lane".
    ///
    /// The word "pinned" went to docking, because that is what it means to the
    /// person using the app. This flag kept its meaning and its key and lost
    /// only the name; ADR-0010 is why it did not simply disappear into docking.
    func setKeepLive(_ laneId: String, _ keepLive: Bool) throws {
        publish(try core.setKeepLive(laneId: laneId, keepLive: keepLive))
    }

    // MARK: - docking

    /// The lanes the strip lays out: everything except what is held at an edge.
    ///
    /// **Every index the strip computes is an index into this array** — the
    /// materialisation window, the visible range, the snap targets, the edge
    /// rails' counts, and the `Viewport` handed to `planEviction`. A docked
    /// lane keeps its ordinal in `state.lanes` so that undocking returns it to
    /// the spot it left, which means `state.lanes` and the laid-out strip are
    /// not the same list any more. Indexing one with the other's numbers is the
    /// bug this property exists to make hard: at worst it evicts a pane the
    /// user is looking at.
    var stripLanes: [Lane] { state.lanes.filter { $0.dock == nil } }

    /// The lane holding an edge, if any.
    func dockedLane(_ side: DockSide) -> Lane? {
        state.lanes.first { $0.dock?.side == side }
    }

    /// Hold a lane at one edge of the window. Every pane in it comes along.
    ///
    /// `widthPt` of nil means "the width this lane already has": docking must
    /// not reflow the page, or every dock begins with the thing you docked
    /// jumping. The core clamps to the dock bounds, which are not the lane
    /// bounds — a dock is not a reading column.
    ///
    /// Docking to an edge another lane holds displaces that lane back into the
    /// strip, at the ordinal it never stopped holding.
    func dockLane(_ laneId: String, side: DockSide, mode: DockMode, widthPt: UInt32? = nil) throws {
        publish(try core.dockLane(laneId: laneId, side: side, mode: mode, widthPt: widthPt))
    }

    /// Give the edge back. The lane resumes scrolling with the strip between
    /// the same two neighbours it left. A no-op on a lane that is not docked.
    func undockLane(_ laneId: String) throws {
        publish(try core.undockLane(laneId: laneId))
    }

    func setDockMode(_ laneId: String, _ mode: DockMode) throws {
        publish(try core.setDockMode(laneId: laneId, mode: mode))
    }

    /// Persisted, and separate from the lane's own `widthPt` — dragging a dock
    /// narrow must not overwrite a strip width the user chose deliberately.
    func setDockWidth(_ laneId: String, _ widthPt: UInt32) throws {
        publish(try core.setDockWidth(laneId: laneId, widthPt: widthPt))
    }

    /// Dock a lane to `side`, or give the edge back if it is already the one
    /// this lane holds.
    ///
    /// Here rather than in either caller because there are two — ⌃⌘[ acts on
    /// the focused lane, the ⋯ menu acts on the lane under the pointer — and a
    /// toggle implemented twice is a toggle that eventually disagrees with
    /// itself about what "already docked to the other side" means.
    ///
    /// Inset is the default mode, because inset hides nothing. Overlay occludes
    /// a lane, which is precisely what the edge-peek work exists to prevent, so
    /// it stays a deliberate second keystroke.
    ///
    /// Moving a dock from one edge to the other carries its width across: the
    /// width belongs to the dock the user dragged, not to the side it was on.
    func toggleDock(_ laneId: String, side: DockSide) throws {
        guard let lane = lane(laneId) else { return }
        if lane.dock?.side == side {
            try undockLane(laneId)
        } else {
            try dockLane(laneId, side: side, mode: lane.dock?.mode ?? .inset, widthPt: lane.dock?.widthPt)
        }
    }

    /// ⌃⌘\. A no-op on a lane that is not docked — `setDockMode` throws there,
    /// on purpose, and the two callers both offer this as a toggle they have
    /// already greyed out.
    func toggleDockMode(_ laneId: String) throws {
        guard let dock = lane(laneId)?.dock else { return }
        try setDockMode(laneId, dock.mode == .inset ? .overlay : .inset)
    }

    func setManualTag(_ laneId: String, _ projectRoot: String?) throws {
        publish(try core.setManualTag(laneId: laneId, projectRoot: projectRoot))
    }

    /// Report a terminal's working directory. Cheap enough to call on every OSC 7
    /// sighting — an unchanged cwd costs 0.009 ms and returns `false`.
    /// **Never moves the lane** (PRD §7.3).
    func observeCwd(_ laneId: String, _ cwd: String) {
        guard let changed = try? core.observeCwd(laneId: laneId, cwd: cwd), changed else { return }
        refreshIfChanged()
    }

    // MARK: - pane attributes (navigation, scroll — no snapshot needed)

    func setPaneUrl(_ paneId: String, _ url: String) { try? core.setPaneUrl(paneId: paneId, url: url) }
    func setPaneScroll(_ paneId: String, _ y: Double) { try? core.setPaneScroll(paneId: paneId, scrollY: y) }
    /// How far a pane's contents are scaled. Not published as a snapshot: zoom
    /// changes what a pane draws, not the shape of the strip.
    func setPaneZoom(_ paneId: String, _ zoom: Double) { try? core.setPaneZoom(paneId: paneId, zoom: zoom) }
    func setPaneDataStore(_ paneId: String, _ id: String) { try? core.setPaneDataStore(paneId: paneId, dataStoreId: id) }

    /// A web pane's whole session — history, scroll, form state — as WebKit's
    /// own opaque blob. Deliberately not part of `Pane`: it is read once, when
    /// the view is built, and carrying it in every snapshot would copy every
    /// pane's history across the FFI on every layout change.
    func setPaneSession(_ paneId: String, _ state: Data?) {
        try? core.setPaneInteractionState(paneId: paneId, state: state)
    }

    func paneSession(_ paneId: String) -> Data? {
        try? core.paneInteractionState(paneId: paneId)
    }

    // MARK: - site permissions

    /// What the user last said about a site's camera or microphone, or nil if
    /// they have never been asked. Keyed by the cookie jar as well as the
    /// origin — see migration 0008 for why.
    func sitePermission(dataStoreId: String, origin: String, feature: SiteFeature) -> Bool? {
        (try? core.sitePermission(dataStoreId: dataStoreId, origin: origin, feature: feature)) ?? nil
    }

    func setSitePermission(dataStoreId: String, origin: String, feature: SiteFeature, allowed: Bool) {
        try? core.setSitePermission(
            dataStoreId: dataStoreId, origin: origin, feature: feature, allowed: allowed)
    }

    func forgetSitePermissions(dataStoreId: String, origin: String) {
        try? core.forgetSitePermissions(dataStoreId: dataStoreId, origin: origin)
    }

    // MARK: - recents

    /// Remember something the user launched, for the new-pane picker.
    func noteRecent(_ kind: RecentKind, _ value: String, cwd: String? = nil) {
        try? core.noteRecent(kind: kind, value: value, cwd: cwd)
    }

    /// Most recently used first.
    func recents(limit: UInt32 = 24) -> [Recent] {
        (try? core.recents(limit: limit)) ?? []
    }

    func forgetRecent(_ kind: RecentKind, _ value: String) {
        try? core.forgetRecent(kind: kind, value: value)
    }

    // MARK: - browsing history

    /// A web pane settled on a page.
    ///
    /// One call from the navigation delegate, with everything the web view
    /// already knows. `requestedUrl` is `backForwardList.currentItem?.initialURL`
    /// — the address the navigation started from, which differs from `url` only
    /// when something redirected, and is what keeps the thing the user typed
    /// findable after it does.
    ///
    /// No snapshot: a visit is not layout, so this costs a row and does not
    /// redraw the strip.
    func recordVisit(paneId: String, url: String, title: String?, requestedUrl: String? = nil) {
        try? core.recordVisit(paneId: paneId, url: url, title: title, requestedUrl: requestedUrl)
    }

    /// The page's `<title>`, which lands a beat after the navigation finishes.
    /// A correction to a visit, never another one — and a no-op for a page that
    /// was never recorded, so it is safe to call from a KVO observer that fires
    /// for things history does not keep.
    func noteVisitTitle(url: String?, title: String) {
        guard let url, !title.isEmpty else { return }
        try? core.nameVisit(url: url, title: title)
    }

    /// Best match first, or newest first for an empty query. Ranked in Rust;
    /// see `history.rs` for why the corpus does not cross the FFI per keystroke.
    func history(_ query: String, limit: UInt32 = 60) -> [HistoryEntry] {
        (try? core.history(query: query, limit: limit)) ?? []
    }

    /// How many pages are on record, for the palette's footer.
    var historyCount: UInt32 { (try? core.historyCount()) ?? 0 }

    /// How many of those a query can actually reach. Smaller than
    /// `historyCount` once the table outgrows one scan — and a footer that
    /// prints the larger number while describing the smaller search is a label
    /// that lies about its own list.
    var searchableHistoryCount: UInt32 { (try? core.historySearchableCount()) ?? 0 }

    func forgetVisit(_ url: String) { try? core.forgetVisit(url: url) }

    func clearHistory() { try? core.clearHistory() }

    // MARK: - focus and scroll

    /// Focus, without marshalling the strip. Focus does not change the shape of
    /// anything, so the caller already knows how to draw the result.
    func noteFocus(_ paneId: String) {
        try? core.noteFocus(paneId: paneId)
        // Keep the in-memory snapshot's revision in step without a full fetch.
        state = StripState(
            lanes: state.lanes, scrollX: state.scrollX, focusedPaneId: paneId,
            gatherFilter: state.gatherFilter, revision: core.revision())
        for body in observers.values { body(state) }
    }

    /// Focus *and* re-snapshot. For search-to-scroll, where focus arrived
    /// alongside a rehydrate.
    func focusPane(_ paneId: String) throws {
        publish(try core.focusPane(paneId: paneId))
    }

    /// Debounced by the caller — this is a write, and 120 Hz of writes would be
    /// absurd.
    func setScrollX(_ x: Double) { try? core.setScrollX(scrollX: x) }

    // MARK: - gather (§7.4)

    func gather(projectRoot: String) throws { publish(try core.gather(projectRoot: projectRoot)) }
    func ungather() throws { publish(try core.ungather()) }
    var isGathered: Bool { state.gatherFilter != nil }

    // MARK: - search (§7.5)

    // MARK: - export / import (§13 Phase 3)

    /// The whole strip as JSON, whatever the gather filter currently shows.
    func exportStrip() throws -> String { try core.exportStrip() }

    /// Append an exported strip to the right-hand end of this one.
    func importStrip(_ json: String) throws {
        publish(try core.importStrip(json: json))
    }

    // MARK: - pairing (§6, §13 Phase 2)

    /// Link a terminal and a web pane so each can find the other.
    ///
    /// The PRD calls this optional and never lets it affect layout — a pairing
    /// is a fact about two panes, not a container. Nothing about ordinals,
    /// gather or eviction consults it.
    func pair(pty: String, web: String) throws {
        try core.pair(ptyPaneId: pty, webPaneId: web)
        publish(try core.state())
    }

    func unpair(pty: String, web: String) throws {
        try core.unpair(ptyPaneId: pty, webPaneId: web)
        publish(try core.state())
    }

    /// Pane ids linked to `paneId`, in either direction.
    func pairs(of paneId: String) -> [String] {
        (try? core.pairsOf(paneId: paneId)) ?? []
    }

    func pushScrollback(_ paneId: String, _ lines: [String]) {
        core.pushScrollback(paneId: paneId, lines: lines)
    }

    func search(_ query: String, limit: UInt32 = 50) -> [SearchHit] {
        (try? core.search(query: query, limit: limit)) ?? []
    }

    // MARK: - eviction (§10.3)

    /// `viewport` indexes ``stripLanes``, not `state.lanes`. The core removes
    /// docked lanes the same way before indexing, so the two agree as long as
    /// the caller measured the array it laid out.
    func planEviction(viewport: Viewport, memory: MemoryReport) -> [PaneDirective] {
        (try? core.planEviction(viewport: viewport, memory: memory)) ?? []
    }

    func markEvicted(_ paneId: String, snapshotPath: String?, scrollY: Double?) throws {
        publish(try core.markEvicted(paneId: paneId, snapshotPath: snapshotPath, scrollY: scrollY))
    }

    func markLive(_ paneId: String) throws { publish(try core.markLive(paneId: paneId)) }

    // MARK: - lookups

    func lane(containing paneId: String) -> Lane? {
        state.lanes.first { $0.panes.contains { $0.id == paneId } }
    }

    func lane(_ laneId: String) -> Lane? { state.lanes.first { $0.id == laneId } }

    func pane(_ paneId: String) -> Pane? {
        state.lanes.lazy.flatMap(\.panes).first { $0.id == paneId }
    }

    /// The lane the user is in, which is where spawned things go.
    var focusedLane: Lane? { state.focusedPaneId.flatMap { lane(containing: $0) } }

    func projectRoot(of cwd: String) -> String? { core.projectRootOf(cwd: cwd) }
}
