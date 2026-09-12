import AppKit
import LanedCore
import WebKit

/// A web pane: one `WKWebView`, or the dimmed snapshot standing in for one that
/// has been evicted.
///
/// The lifecycle here is the whole of PRD §10.2 and §10.3 from the shell's side.
/// `laned-core` decides *what* should happen; this does it and reports back.
///
/// Three states, and the difference between the middle two is the entire memory
/// strategy:
///
/// - **parented** — in the view hierarchy, rendering.
/// - **unparented** — still alive, out of the hierarchy. WebKit stops rendering
///   an unparented view, so this costs almost nothing to undo. Re-parenting is
///   instant and the page keeps its scroll, its form state and its session.
/// - **evicted** — snapshotted and destroyed. Coming back is a reload.
@MainActor
final class WebPaneController: NSObject, PaneController {
    let paneId: String
    private let store: StripStore
    private let config: Config
    private let container = NSView()

    private var webView: WKWebView?
    private var placeholder: PlaceholderView?
    private var pane: Pane
    private var laneWidth: CGFloat
    private var isParented = false
    private var scrollObservation: Timer?
    private var titleObservation: NSKeyValueObservation?

    var view: NSView { container }

    /// `deferLoad` is PRD §13's lazy launch: on a cold start only the panes near
    /// the viewport are instantiated, and the rest wait as placeholders. M1
    /// priced a web pane at 27–95 MB and at least one OS process, so a 150-lane
    /// strip that built every one of them at launch would spend gigabytes before
    /// the window appeared.
    init(pane: Pane, lane: Lane, store: StripStore, config: Config, deferLoad: Bool = false) {
        self.paneId = pane.id
        self.pane = pane
        self.store = store
        self.config = config
        self.laneWidth = CGFloat(lane.widthPt)
        self.dataStoreId = pane.dataStoreId ?? Self.shard(for: lane.projectRoot, of: config)
        super.init()

        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.laneBackground.cgColor

        // A pane that is already evicted comes back as a placeholder, not as a
        // web view that immediately gets torn down again.
        if pane.state == .evicted || pane.kind == .placeholder {
            showPlaceholder()
        } else if deferLoad {
            isDeferred = true
            showPlaceholder()
        } else {
            buildWebView(dataStoreId: dataStoreId)
        }
    }

    /// True while this pane is waiting for its first load (PRD §13's lazy
    /// launch). Distinct from *evicted*: nothing was ever built, so there is no
    /// snapshot and nothing to restore beyond the URL.
    private(set) var isDeferred = false
    private let dataStoreId: String

    /// Build the web view a deferred pane has been waiting to get.
    func loadIfDeferred() {
        guard isDeferred else { return }
        isDeferred = false
        placeholder?.removeFromSuperview()
        placeholder = nil
        buildWebView(dataStoreId: dataStoreId)
    }

    // MARK: - PaneController

    func apply(_ pane: Pane) {
        self.pane = pane
        placeholder?.apply(pane)
        // A URL change from the ledger (not from navigation) means something
        // outside asked for a different page.
        if let url = pane.url, let webView, webView.url?.absoluteString != url,
           webView.isLoading == false, pane.state == .live {
            load(url)
        }
    }

    func takeFocus() {
        if let webView {
            container.window?.makeFirstResponder(webView)
        }
    }

    func flushState() { captureSession() }

    func tearDown() {
        // Last chance: a quit tears every pane down, and a pane whose session
        // was never written comes back as a fresh page.
        captureSession()
        scrollObservation?.invalidate()
        scrollObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    func unparent() {
        guard isParented, let webView else { return }
        // Record where the page is before it stops being able to tell us.
        captureScroll()
        captureSession()
        webView.removeFromSuperview()
        isParented = false
    }

    func reparentIfNeeded() {
        guard !isParented, let webView else {
            if webView == nil && placeholder == nil { showPlaceholder() }
            return
        }
        install(webView)
    }

    func evict() {
        // Nothing was built, so there is nothing to reclaim and no snapshot to
        // take. Leaving it deferred is already the cheapest state it has.
        guard !isDeferred else { return }
        guard let webView else { return }
        captureScroll()
        let paneId = self.paneId
        let scrollY = pane.scrollY

        // Snapshot at the lane's width in points, not backing pixels: ADR-0006.
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Double(laneWidth))
        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self else { return }
            // Encoding is ~1.2 ms and eviction comes in batches, under memory
            // pressure. Off the main thread.
            if let image {
                DispatchQueue.global(qos: .utility).async {
                    let path = SnapshotStore.write(image, for: paneId)
                    DispatchQueue.main.async {
                        try? self.store.markEvicted(paneId, snapshotPath: path, scrollY: scrollY)
                        self.destroyWebView()
                    }
                }
            } else {
                // No snapshot is not a reason to keep the memory.
                try? self.store.markEvicted(paneId, snapshotPath: nil, scrollY: scrollY)
                self.destroyWebView()
            }
        }
    }

    func rehydrate() {
        if isDeferred {
            loadIfDeferred()
            return
        }
        guard webView == nil, let url = pane.url else { return }
        placeholder?.removeFromSuperview()
        placeholder = nil
        buildWebView(dataStoreId: dataStoreId)
        load(url)
        try? store.markLive(paneId)
    }

    func laneWidthChanged(to width: CGFloat) { laneWidth = width }

    /// Put the page's title on its lane. A lane with no title falls back to the
    /// URL's host, which is worse to scan a strip by.
    private func adoptTitle(_ title: String) {
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        guard store.lane(laneId)?.title != title else { return }
        try? store.setLaneTitle(laneId, title)
    }

    // MARK: - building

    private func buildWebView(dataStoreId: String) {
        let configuration = WKWebViewConfiguration()
        // No `processPool` here. PRD §9 says "one WKProcessPool for the whole
        // app (WebKit does process-per-site under it)"; spike M1 found both
        // halves untrue on macOS 26. WKProcessPool has been a deprecated no-op
        // since macOS 12, and WebKit gave exactly one WebContent process per
        // WKWebView with no site coalescing — 100 views across 20 origins
        // produced 100 processes. The right model is one web pane, one OS
        // process, and there is nothing here to configure. ADR-0003.
        configuration.websiteDataStore = DataStorePool.shared.store(dataStoreId)
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // PRD §9: default desktop UA. Portrait-width desktop reflow is the point;
        // a mobile UA would get us mobile layouts, which is not what a lane is.
        webView.autoresizingMask = [.width, .height]

        self.webView = webView
        // `webView.title` is usually still empty when `didFinish` fires — the
        // document's <title> often lands a beat later — so observe it rather
        // than sampling it once. An end-to-end run with example.com produced a
        // pane URL and no lane title, which is what this fixes.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let title = change.newValue ?? nil, !title.isEmpty else { return }
            Task { @MainActor in self?.adoptTitle(title) }
        }
        store.setPaneDataStore(paneId, dataStoreId)
        install(webView)

        // The session, if this pane has one, in place of a bare load. It
        // carries the back/forward list, the scroll offset and form state, so
        // the pane comes back as the page you left rather than as its address:
        // reloading `url` alone lands at the top with an empty history, which
        // is why a restarted strip used to feel like a different strip.
        if let session = store.paneSession(paneId) {
            webView.interactionState = session
            Log.debug("pane \(paneId) restoring a \(session.count)-byte session")
            // WebKit restores asynchronously and, for a page it cannot restore
            // (a cleared cache, a blob that predates a WebKit update), lands on
            // about:blank with no error. The URL is the fallback.
            let url = pane.url
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let webView = self.webView, let url else { return }
                let restored = webView.url?.absoluteString ?? ""
                guard restored.isEmpty || restored == "about:blank" else {
                    Log.debug("pane \(self.paneId) restored to \(restored)")
                    return
                }
                Log.warn("pane \(self.paneId) could not restore its session; reloading \(url)")
                self.load(url)
            }
        } else if let url = pane.url {
            load(url)
        }
        startScrollTracking()
    }

    private func install(_ view: NSView) {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        isParented = true
    }

    private func destroyWebView() {
        scrollObservation?.invalidate()
        scrollObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        isParented = false
        showPlaceholder()
    }

    private func showPlaceholder() {
        guard placeholder == nil else { return }
        let view = PlaceholderView(pane: pane)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        placeholder = view
    }

    private func load(_ url: String) {
        guard let webView, let parsed = URL(string: url) else { return }
        if parsed.isFileURL {
            // WebKit refuses a plain request for file://; it needs to be told
            // which directory the page may read from. Granting the file's own
            // folder is enough for a source file or an image and is a great
            // deal narrower than granting the volume.
            webView.loadFileURL(parsed, allowingReadAccessTo: parsed.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: parsed))
        }
        if let y = pane.scrollY, y > 0 {
            pendingScrollRestore = y
        }
    }

    // MARK: - scroll

    private var pendingScrollRestore: Double?
    /// What was last written, so an idle pane is not rewritten every two
    /// seconds. The blob is tens of kilobytes and the ledger is on disk.
    private var lastSavedSession: Data?

    /// Poll rather than observe: `WKWebView` gives no scroll delegate on macOS,
    /// and injecting a scroll listener into every page costs a message per frame
    /// on 130 panes. Two seconds is plenty for something only read on eviction.
    private func startScrollTracking() {
        scrollObservation?.invalidate()
        scrollObservation = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureScroll() }
        }
    }

    /// Save what the pane is doing, on the same cadence as the scroll sample.
    ///
    /// `interactionState` is a synchronous read of WebKit's own serialisation,
    /// so there is nothing to wait for and no JavaScript hop. It is skipped
    /// while a load is in flight, because a half-loaded page serialises as a
    /// half-loaded page and that is what would come back.
    private func captureSession() {
        guard let webView, webView.isLoading == false else { return }
        guard let state = webView.interactionState as? Data else { return }
        guard state != lastSavedSession else { return }
        lastSavedSession = state
        store.setPaneSession(paneId, state)
    }

    private func captureScroll() {
        captureSession()
        guard let webView, isParented else { return }
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            guard let self, let y = value as? Double else { return }
            guard abs((self.pane.scrollY ?? 0) - y) > 1 else { return }
            self.pane.scrollY = y
            self.store.setPaneScroll(self.paneId, y)
        }
    }

    /// Which data-store shard a project's panes live in.
    ///
    /// Hashed rather than assigned in order so that adding a project does not
    /// reshuffle everyone else's cookies — a project keeps its shard for the
    /// life of the ledger. See ADR-0003.
    static func shard(for projectRoot: String?, of config: Config) -> String {
        DataStorePool.shardId(for: projectRoot, count: config.dataStoreCount)
    }
}

// MARK: - navigation

extension WebPaneController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // PRD §9: keep pane.url and the lane title current as the user navigates.
        if let url = webView.url?.absoluteString {
            pane.url = url
            store.setPaneUrl(paneId, url)
        }
        if let title = webView.title, !title.isEmpty {
            adoptTitle(title)
        }
        if let y = pendingScrollRestore {
            pendingScrollRestore = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))")
        }
        // A navigation is exactly when the history changed, so do not wait for
        // the next sample to record it.
        captureSession()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A failed load leaves the pane where it was rather than blanking it;
        // the URL in the ledger is still the right thing to retry.
    }
}

// MARK: - popups

extension WebPaneController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // PRD §9: a popup or target=_blank becomes a new web pane right of this
        // one, not a window and not a tab. Returning nil and opening it
        // ourselves keeps the new page in the same lane ordering rules as
        // everything else.
        if let url = navigationAction.request.url?.absoluteString,
           let laneId = store.lane(containing: paneId)?.id {
            try? store.newWebLane(url: url, near: laneId)
        }
        return nil
    }
}

/// The app's single `WKProcessPool` and its handful of data stores (PRD §9).
@MainActor
final class DataStorePool {
    static let shared = DataStorePool()

    private var stores: [String: WKWebsiteDataStore] = [:]

    static let defaultShardId = "shard-0"

    /// Stable shard for a project. A project keeps its shard forever, because
    /// moving one means losing the logins in it.
    static func shardId(for projectRoot: String?, count: Int) -> String {
        guard let root = projectRoot, count > 1 else { return defaultShardId }
        // FNV-1a: stable across launches, unlike Swift's seeded `hashValue`,
        // which would reshuffle every project's cookies on every restart.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in root.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "shard-\(hash % UInt64(count))"
    }

    func store(_ id: String) -> WKWebsiteDataStore {
        if let existing = stores[id] { return existing }
        // `WKWebsiteDataStore.default()` would hand every shard the same store
        // and quietly undo the sharding. The identifier-based initialiser
        // (macOS 14+) is what actually gives separate persistent cookie jars.
        // `MAXPANE_DATA_SALT` gives a launch its own cookie jars. A throwaway
        // instance that logs into something must not write into the jar the
        // real one reads, and a UUID derived from the shard name alone would.
        let salt = ProcessInfo.processInfo.environment["MAXPANE_DATA_SALT"] ?? ""
        let store = WKWebsiteDataStore(forIdentifier: Self.uuid(for: salt + id))
        stores[id] = store
        return store
    }

    /// A stable UUID for a shard name.
    ///
    /// It must be identical on every launch — WebKit keys the on-disk store by
    /// it, so a different UUID means a new empty store and every login gone.
    /// Built deterministically from the shard name rather than generated and
    /// stored, so there is no extra file to lose.
    static func uuid(for shardId: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ("maxpane." + shardId).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // Two rounds so the high and low halves differ.
        var second = hash
        for byte in shardId.utf8.reversed() {
            second ^= UInt64(byte)
            second = second &* 0x0000_0100_0000_01b3
        }
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (8 * UInt64(i))) & 0xff)
            bytes[8 + i] = UInt8((second >> (8 * UInt64(i))) & 0xff)
        }
        // Stamp version 4 / variant RFC 4122 so it is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
