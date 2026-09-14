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
    let store: StripStore
    private let config: Config
    private let container = WebPaneContainer()

    /// Everything above the chrome: the web view, or the placeholder standing
    /// in for it. Separate from `container` so the chrome keeps its 26 pt
    /// whatever state the pane is in — an evicted pane still has an address,
    /// and that address is how you recognise it on the strip.
    /// Internal: `WebPaneAsks.swift` parents the ask sheet here.
    let contentHost = NSView()
    /// Internal: the password menu in `WebPanePasswords.swift` hangs off this
    /// row's key button, and a fill's answer is reported on its failure line.
    let chrome = WebChromeBar()
    private let findBar = WebFindBar()
    private var findBarHeight: NSLayoutConstraint!
    /// Which search the answers coming back belong to. See `countMatches`.
    private var findGeneration: UInt64 = 0

    private let completions = AddressCompletionList()
    private var completionsHeight: NSLayoutConstraint!
    let downloadBar = WebDownloadBar()
    var downloadBarHeight: NSLayoutConstraint!

    // MARK: - what the page has stopped to ask
    //
    // Internal rather than private: the five delegate methods that fill these
    // live in `WebPaneAsks.swift`, and a Swift extension cannot add stored
    // properties. Nothing outside this module touches them.

    /// The question on screen, if there is one. A subview of `contentHost`, so
    /// the strip recycling this lane's *view* cannot destroy it — a pane
    /// controller outlives lane views by design (ADR-0004) and an outstanding
    /// completion handler has to outlive them with it.
    var askSheet: WebAskSheet?
    /// Questions waiting their turn in this pane, oldest first.
    var askQueue = AskQueue<PendingAsk>()
    /// Files this pane has asked for, in the order they were started.
    var downloads: [DownloadJob] = []
    /// The last drawn download states and when — see `refreshDownloadBar` for
    /// why a progress tick does not always cost a rebuild.
    var lastDownloadStates: [DownloadJob.State] = []
    var lastDownloadDraw: CFAbsoluteTime = 0
    /// Open panels this pane has put on screen, so a pane torn down with a file
    /// picker open closes it and answers `nil` rather than leaving a panel with
    /// nothing behind it.
    var openPanels: [NSOpenPanel] = []

    /// Every address this pane passed through on the way to the one it is
    /// showing. Internal: the navigation-policy delegate lives in
    /// `WebPaneAsks.swift`, which is where a navigation is first seen.
    var trail = RedirectTrail()

    /// Internal: the delegate methods in `WebPaneAsks.swift` need it.
    var webView: WKWebView?
    private var placeholder: PlaceholderView?
    /// The panel covering a web view that has not painted yet, and the timer
    /// that lifts it if the page never arrives. See `showFirstPaintCover`.
    private var firstPaintCover: PlaceholderView?
    private var firstPaintDeadline: DispatchWorkItem?
    private var pane: Pane
    private var laneWidth: CGFloat
    private var isParented = false
    private var scrollObservation: Timer?
    private var titleObservation: NSKeyValueObservation?
    /// The "this page never gave itself a title" label, waiting to see whether
    /// a real one turns up first. See `scheduleUntitledFallback`.
    private var untitledFallback: DispatchWorkItem?
    /// `canGoBack`, `canGoForward`, `isLoading`, `estimatedProgress`, `url`.
    private var chromeObservations: [NSKeyValueObservation] = []
    private var focusToken: UUID?
    private var bookmarkToken: UUID?
    private var hoverRelay: ScriptMessageRelay?
    private var fullScreenRelay: FullScreenMessageRelay?
    private var keyWindowObserver: (any NSObjectProtocol)?

    /// True while an element of this pane's page fills the pane. See
    /// `setPaneFullscreen`.
    private(set) var isPaneFullscreen = false
    /// Which full screen change a finishing fade belongs to.
    private var fullscreenGeneration: UInt64 = 0
    /// The page ends where the bars start, or — full screen — at the pane's foot.
    private var contentAboveBars: NSLayoutConstraint!
    private var contentFillsPane: NSLayoutConstraint!

    /// Set by the strip so a lane this pane opens can be scrolled to.
    ///
    /// A lane created while its opener is off-screen is focused in the ledger
    /// and nowhere on screen — the strip only *builds* a pane's view when the
    /// lane is inside the materialisation window — so a `target=_blank` or a
    /// ⌘-click from a pane fifteen lanes back has to be brought to where it can
    /// be read. It also brings this pane back into view when a popup it opened
    /// closes and hands it the keyboard.
    ///
    /// The same closure `TerminalPaneController` uses for ⌘-click, for the same
    /// reason.
    var onRevealLane: ((String?) -> Void)?

    /// The window a popup this pane's page opens is centred over. Set by the
    /// strip, because this pane's own view may be in no window at all — its
    /// lane scrolled out of the materialisation window — and where a sign-in
    /// appears must not depend on where its opener happens to be.
    var popupParent: (() -> NSWindow?)?

    /// The popup this pane's page has open, if any. See `WebPopupDialog`.
    var popupDialog: WebPopupDialog?

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
        container.layerBackgroundColor = Theme.laneBackground
        installChrome()
        // Before any web view exists, so a deferred or evicted pane's chrome is
        // never blank — the ledger already knows the address.
        showAddress(pane.url)
        zoom = pane.zoom
        chrome.setZoom(zoom)

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
    /// Internal: the permission store is keyed by the cookie jar, so the ask
    /// handlers in `WebPaneAsks.swift` need it.
    let dataStoreId: String

    /// Build the web view a deferred pane has been waiting to get.
    func loadIfDeferred() {
        guard isDeferred else { return }
        isDeferred = false
        placeholder?.removeFromSuperview()
        placeholder = nil
        forgetFirstPaintCover()
        buildWebView(dataStoreId: dataStoreId)
    }

    // MARK: - chrome

    /// The pane's shape: content, the find bar's zero height, the download
    /// bar's zero height, then 26 pt of browser chrome pinned to the bottom.
    ///
    /// The download bar sits between the two because it is the more permanent
    /// of the pair — find is a thing you open and close in one gesture, a
    /// download outlives the page — and putting it directly above the chrome
    /// keeps the address the last line before the page in every state.
    private func installChrome() {
        for subview in [contentHost, findBar, downloadBar, chrome] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        // Starts collapsed rather than hidden: animating a constraint from 0 is
        // one code path for both directions, and a hidden view in a stack has to
        // be un-hidden before it can be measured, which costs a frame of jump.
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBar.alphaValue = 0
        downloadBarHeight = downloadBar.heightAnchor.constraint(equalToConstant: 0)
        contentAboveBars = contentHost.bottomAnchor.constraint(equalTo: findBar.topAnchor)
        contentFillsPane = contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: container.topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentAboveBars,

            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: downloadBar.topAnchor),
            findBarHeight,

            downloadBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            downloadBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            downloadBar.bottomAnchor.constraint(equalTo: chrome.topAnchor),
            downloadBarHeight,

            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        installCompletions()
        installDownloadBar()

        chrome.onBack = { [weak self] in self?.webView?.goBack() }
        chrome.onForward = { [weak self] in self?.webView?.goForward() }
        chrome.onReloadOrStop = { [weak self] in
            guard let self else { return }
            // The button and ⌘R are deliberately *not* the same action while a
            // page is in flight. The button has, at that moment, changed into a
            // stop button and says so, and clicking a thing labelled ✕ has to
            // stop; ⌘R has no label and every browser restarts the load with
            // it. They agree everywhere else, because both end up in `reload`.
            if self.webView?.isLoading == true {
                self.webView?.stopLoading()
            } else {
                self.reload(fromOrigin: false)
            }
        }
        chrome.onFind = { [weak self] in self?.toggleFind() }
        chrome.onStar = { [weak self] in self?.keepPage() }
        chrome.onKeyMenu = { [weak self] in self?.passwordMenu() }
        chrome.onZoomReset = { [weak self] in self?.setZoom(1) }
        chrome.onNavigate = { [weak self] typed in self?.navigate(typed) }
        chrome.onBackMenu = { [weak self] in self?.historyMenu(back: true) }
        chrome.onForwardMenu = { [weak self] in self?.historyMenu(back: false) }

        // Escape in the address bar has to land somewhere, and the only place
        // worth landing is the page that was under it a moment ago. Without
        // this the field gives first responder back to the *window*, which
        // looks identical and is deaf — and the ledger still says this pane has
        // the keyboard, so nothing else would ever come and claim it.
        chrome.onAddressEditingEnded = { [weak self] in
            // Before the focus hand-back, not after. `applyPendingFocus` gives
            // the keyboard to the page, and a list still on screen over a page
            // that has the keyboard is a menu nothing can dismiss.
            self?.completions.hide()
            self?.layoutCompletions()
            self?.applyPendingFocus()
        }

        findBar.onSearch = { [weak self] query, forward in self?.find(query, forward: forward) }
        findBar.onClose = { [weak self] in self?.setFindVisible(false) }

        // Focus decides the chrome's contrast, and the ledger is the only thing
        // that knows it — `takeFocus` is called but there is no matching "you
        // lost it". Every mutation republishes, and focus is a mutation.
        focusToken = store.observe { [weak self] state in
            guard let self else { return }
            self.chrome.isPaneFocused = state.focusedPaneId == self.paneId
        }

        // The star is a fact about the tree, not about this pane, and the tree
        // is edited from three places — this star, the editor it opens, and the
        // sidebar. Watching it is how the same page open in two lanes lights
        // both stars, rather than the one that was clicked.
        bookmarkToken = store.observeBookmarks { [weak self] in self?.refreshKept() }

        // The pane's own keys. They are not in `Commands.swift` because they
        // belong to whatever has the keyboard rather than to the app — and
        // because ⌘R, ⌘L and ⌘[ are already spoken for there. See the report.
        container.onKeyEquivalent = { [weak self] event in self?.handleKey(event) ?? false }
        container.onMovedToWindow = { [weak self] in
            // One turn later. `viewDidMoveToWindow` fires while AppKit is still
            // moving the hierarchy around, and a `makeFirstResponder` from
            // inside that is undone by the rest of the pass.
            Task { @MainActor in self?.applyPendingFocus() }
        }
        // A lane opened by `maxpane open` from a terminal outside the app is
        // built while the window is not key, and `makeFirstResponder` on a
        // window that is not key does not stick. The ledger already says this
        // pane is focused, so the moment the window comes forward it should be.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPendingFocus() }
        }
    }

    /// A line typed into the address field.
    private func navigate(_ typed: String) {
        guard let url = BrowserAddress.resolve(typed, searchTemplate: config.searchUrl) else { return }
        // Record it the way ⌘T records what it launched: the address bar is a
        // launcher too, and a URL typed here should come back in the picker.
        store.noteRecent(.url, url)
        // Written before anything reads it. A deferred or evicted pane rebuilds
        // from `pane.url`, so setting it first means the rebuild loads where we
        // are going — rather than loading where we were and then being
        // navigated off it, which is two page loads and a visible flash of the
        // wrong site.
        pane.url = url
        store.setPaneUrl(paneId, url)
        // A typed address lands at the top. The saved scroll belongs to the page
        // being left, and `load` would otherwise restore it onto the new one —
        // 4 000 px down someone else's document.
        pane.scrollY = 0
        store.setPaneScroll(paneId, 0)
        if isDeferred {
            loadIfDeferred()
        } else if webView == nil {
            rehydrate()
        } else {
            load(url)
        }
        showAddress(url)
        takeFocus()
    }

    /// The back/forward list, as a menu. `WKBackForwardList` is otherwise
    /// unreachable without a keyboard, and "go back four pages" is the thing a
    /// long-press exists for.
    private func historyMenu(back: Bool) -> NSMenu? {
        guard let webView else { return nil }
        let items = back
            ? webView.backForwardList.backList.reversed()
            : Array(webView.backForwardList.forwardList)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items.prefix(12) {
            let title = item.title?.isEmpty == false
                ? item.title!
                : (item.url.host ?? item.url.absoluteString)
            let entry = NSMenuItem(
                title: String(title.prefix(60)), action: #selector(goToHistoryItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.toolTip = item.url.absoluteString
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func goToHistoryItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? WKBackForwardListItem else { return }
        webView?.go(to: item)
    }

    /// Keep the chrome in step with whatever the web view is doing.
    ///
    /// KVO rather than the navigation delegate: `didFinish` fires once per
    /// document and misses everything a single-page app does with `pushState`,
    /// which on a site like Gmail is *every* navigation the user makes. An
    /// address bar that is right only on a full page load is an address bar you
    /// stop believing.
    private func observeChrome(_ webView: WKWebView) {
        chromeObservations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshChrome() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.chrome.setProgress(view.estimatedProgress) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    guard let self, let url = view.url?.absoluteString else { return }
                    self.showAddress(url)
                    // A `pushState` never reaches `didFinish`, so the ledger
                    // would keep the address the pane was opened at and a
                    // restart would land you back at the app's front door.
                    self.pane.url = url
                    self.store.setPaneUrl(self.paneId, url)
                    if let popup = self.popupDialog,
                       PopupOpener.hasLeft(openedFrom: popup.openerURL, now: url) {
                        popup.dismiss()
                    }
                }
            },
        ]
        refreshChrome()
    }

    private func refreshChrome() {
        guard let webView else {
            return chrome.setNavigation(canGoBack: false, canGoForward: false, loading: false)
        }
        chrome.setNavigation(
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            loading: webView.isLoading)
    }

    // MARK: - address completion

    /// The list, above the chrome and in front of everything else.
    ///
    /// Added after the chrome so it draws on top, and constrained to the
    /// chrome's top edge rather than put in the stack of bars: it **overlays**
    /// the page instead of pushing it. A dropdown that reflowed the document
    /// under it would relayout the page on every keystroke typed into the
    /// address bar, which is both a jump to look at and a real cost on a heavy
    /// page.
    private func installCompletions() {
        container.addSubview(completions)
        completionsHeight = completions.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            completions.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            completions.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            completions.bottomAnchor.constraint(equalTo: chrome.topAnchor),
            completionsHeight,
        ])

        chrome.onAddressQueryChanged = { [weak self] text, deleting in
            self?.updateCompletions(text, deleting: deleting)
        }
        chrome.onAddressCompletionKey = { [weak self] key in
            self?.completionKey(key) ?? false
        }
        completions.onHighlight = { [weak self] suggestion in
            self?.chrome.showHighlightedAddress(suggestion?.url)
        }
        completions.onPick = { [weak self] suggestion in
            guard let self else { return }
            self.chrome.endEditingAddress()
            self.navigate(suggestion.url)
        }
    }

    /// Ask the ledger what has been typed so far looks like.
    ///
    /// Straight across the FFI on every keystroke, with no debounce, and that is
    /// the measured choice rather than a shortcut. `history.rs` exists to make
    /// exactly this call cheap — the query goes down and at most `limit` rows
    /// come back, instead of the corpus coming up to be filtered in Swift — and
    /// a debounce on a query that already costs a couple of milliseconds buys
    /// nothing and makes the list lag the typing, which is the one thing an
    /// address bar's suggestions must never do.
    private func updateCompletions(_ text: String, deleting: Bool) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            completions.hide()
            layoutCompletions()
            return
        }
        let rows = AddressCompletion.rows(
            query: typed,
            from: store.history(typed, limit: AddressCompletion.fetch))
        completions.show(rows, query: typed)
        layoutCompletions()
        if let completion = AddressCompletion.inlineCompletion(
            for: text, suggestion: rows.first, deleting: deleting) {
            chrome.completeAddressInline(to: completion)
        }
    }

    private func layoutCompletions() {
        completionsHeight.constant = completions.isShowing ? completions.height : 0
    }

    /// ↑, ↓ and Escape, answered only while there is a list to answer for.
    ///
    /// Returning false is what keeps the field's own behaviour intact when the
    /// list is closed: ↑ is still "start of line" in a text field, and Escape is
    /// still "give the keyboard back to the page".
    private func completionKey(_ key: AddressField.CompletionKey) -> Bool {
        guard completions.isShowing else { return false }
        switch key {
        case .up:
            completions.move(-1)
        case .down:
            completions.move(1)
        case .dismiss:
            completions.hide()
            layoutCompletions()
        }
        return true
    }

    // MARK: - find in page

    private func toggleFind() {
        // A find bar opening under a page that is filling the pane would be a
        // field nobody can see.
        leavePaneFullscreen()
        setFindVisible(findBarHeight.constant == 0)
    }

    private func setFindVisible(_ visible: Bool) {
        guard (findBarHeight.constant > 0) != visible else {
            if visible { findBar.takeFocus() }
            return
        }
        if visible { findBar.takeFocus() } else { takeFocus() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            findBarHeight.animator().constant = visible ? WebFindBar.height : 0
            findBar.animator().alphaValue = visible ? 1 : 0
        }
        if !visible {
            // Leaving the highlight up after the bar has gone is how you end up
            // with a yellow word you cannot get rid of.
            webView?.find("", configuration: WKFindConfiguration()) { _ in }
            // And a count still walking the page belongs to a bar that is no
            // longer on screen. Retiring the generation is what stops it
            // reporting into the next search.
            findGeneration &+= 1
        }
    }

    private func find(_ query: String, forward: Bool) {
        guard let webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        // Case-insensitive, which is what every browser's find bar does and what
        // `WKFindConfiguration` does *not* default to.
        configuration.caseSensitive = false
        findGeneration &+= 1
        let generation = findGeneration
        webView.find(query, configuration: configuration) { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.findGeneration else { return }
                self.findBar.report(found: result.matchFound)
                guard result.matchFound else { return }
                self.countMatches(query, generation: generation)
            }
        }
    }

    /// Put a number next to the highlight WebKit just made.
    ///
    /// Runs only after `matchFound` — see `FindCount` for why WebKit stays the
    /// authority on whether there is a match and this only ever supplies the
    /// count — and only after the selection exists, because the index is read
    /// off that selection rather than off a keypress counter.
    ///
    /// `.defaultClient`, not the page's world. Counting in the page's own world
    /// would let a page decide what its find bar says by redefining
    /// `String.prototype.indexOf`, and this is a readout the user is entitled to
    /// trust against the page. It also keeps the walk away from anything the
    /// page has monkey-patched, which is the more common reason it would
    /// silently return the wrong number.
    ///
    /// The generation check is not belt and braces. Find runs on every
    /// keystroke, so a slow walk on a large document is routinely still in
    /// flight when the next character arrives — and a count for `ma` landing
    /// under a query that now reads `maxp` is precisely the disagreement between
    /// the number and the highlight that this whole piece exists to avoid.
    private func countMatches(_ query: String, generation: UInt64) {
        guard let webView else { return }
        webView.evaluateJavaScript(
            FindCount.javaScript(for: query), in: nil, in: .defaultClient
        ) { [weak self] outcome in
            Task { @MainActor in
                guard let self, generation == self.findGeneration else { return }
                guard case let .success(value) = outcome else { return }
                self.findBar.report(found: true, tally: FindCount.tally(from: value))
            }
        }
    }

    // MARK: - keys

    /// ⌘F, ⌘← and ⌘→ for the pane that has the keyboard.
    ///
    /// Deliberately the only three. ⌘R goes through `Commands.swift` and
    /// `reload(fromOrigin:)` instead, because it now means reload for *every*
    /// pane and belongs in the one file that is the whole truth about the
    /// keyboard. ⌘L goes the same way now, as `.editAddress`, and it had to:
    /// `Command.claims` only rescues a chord `Commands.swift` declares, so a
    /// ⌘L answered here and nowhere else would still have been swallowed by the
    /// focused web view before the window ever looked at the responder chain.
    /// ⌘[ / ⌘] stay out because they already mean focus left/right; claiming
    /// them from a pane would make one shortcut mean two things depending on
    /// what is focused, which is what that file exists to prevent.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard store.state.focusedPaneId == paneId else { return false }
        // A text field owns its own keyboard. ⌘← in a field is "start of line".
        guard !chrome.isEditingAddress else { return false }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
              let key = event.charactersIgnoringModifiers
        else { return false }

        switch key {
        case "f":
            toggleFind()
            return true
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            guard webView?.canGoBack == true else { return false }
            webView?.goBack()
            return true
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            guard webView?.canGoForward == true else { return false }
            webView?.goForward()
            return true
        default:
            return false
        }
    }

    // MARK: - reload

    /// ⌘R, ⇧⌘R, and the ⟳ button, all through here so they cannot drift apart.
    ///
    /// Three cases, because a "reload" in this app can arrive at a pane that has
    /// nothing loaded. A deferred pane has never built its web view, an evicted
    /// one has had it destroyed, and `WKWebView.reload()` on a view with no
    /// current item is a silent no-op — which is exactly the shape of bug that
    /// makes a key feel broken. In both of those the ledger's URL is the thing
    /// to load, and loading it is what the user meant.
    func reload(fromOrigin: Bool) {
        if isDeferred { return loadIfDeferred() }
        guard let webView else {
            rehydrate()
            return
        }
        guard webView.url != nil else {
            if let url = pane.url { load(url) }
            return
        }
        // `reloadFromOrigin` is ⇧⌘R: revalidate everything rather than trusting
        // the cache. The distinction earns its key on exactly the pages where a
        // plain reload is useless — a dev server behind a service worker, a
        // dashboard that caches its own bundle.
        _ = fromOrigin ? webView.reloadFromOrigin() : webView.reload()
    }

    /// ⌘L. Unconditional, including on a pane that is deferred or evicted: the
    /// chrome bar is showing the ledger's URL either way, and "copy the address
    /// of that lane" is a fair thing to want from a page that has not been
    /// built yet. Nothing here loads anything — editing an address and
    /// committing one are separate, and only the second navigates.
    func editAddress() {
        // ⌘L on a full screen video is asking for the address, and the address
        // is in the bar the video is covering.
        leavePaneFullscreen()
        chrome.beginEditingAddress()
    }

    // MARK: - bookmarks

    /// The address this pane is actually showing.
    ///
    /// `webView.url` first: during a load and after anything a single-page app
    /// does, the ledger's copy is a page behind, and a star that is right about
    /// the page you were on a second ago is a star that is wrong.
    private var currentAddress: String? {
        let live = webView?.url?.absoluteString
        return (live?.isEmpty == false) ? live : pane.url
    }

    /// ⌘D, and the star. Keep the page if it is not kept, then open the editor
    /// on it either way — see `BookmarkEditor` for why the keeping does not
    /// wait for the panel.
    func keepPage() {
        guard let url = currentAddress, !url.isEmpty else { return }
        // The editor hangs off the star, which is in the bar.
        leavePaneFullscreen()
        let title = webView?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? store.lane(containing: paneId)?.title
            ?? ""
        let existing = store.bookmarks(forURL: url).first
        guard let kept = existing
            ?? (try? store.addBookmark(parent: nil, url: url, title: title))
        else { return }
        BookmarkEditor.show(over: chrome.starAnchor, store: store, bookmark: kept) {
            [weak self] in self?.refreshKept()
        }
        refreshKept()
    }

    /// The address, and the star that goes with it. One call, because they
    /// are one fact and the four places that set the address had all forgotten
    /// the second half at least once while this was being written.
    private func showAddress(_ url: String?) {
        chrome.setURL(url)
        refreshKept()
    }

    private func refreshKept() {
        guard let url = currentAddress, !url.isEmpty else { return chrome.setKept(false) }
        chrome.setKept(!store.bookmarks(forURL: url).isEmpty)
        refreshSavedPassword()
    }

    // MARK: - zoom

    /// ⌘= / ⌘- / ⌘0 on a page.
    ///
    /// `pageZoom` rather than injecting a CSS transform: it is WebKit's own
    /// zoom, so media queries, fixed elements and the scroll offset all behave
    /// the way they do in a browser. A transform would scale the rendered page
    /// and leave the layout at the lane's width, which is the opposite of what
    /// a narrow column needs — the point of zooming out in a 420 pt lane is to
    /// get a *wider* layout.
    private(set) var zoom: Double = 1

    func setZoom(_ next: Double) {
        let ladder = PaneZoom.ladder
        zoom = min(max(next, ladder.first!), ladder.last!)
        webView?.pageZoom = CGFloat(zoom)
        chrome.setZoom(zoom)
        store.setPaneZoom(paneId, zoom)
    }

    // MARK: - size presets

    /// A size preset's page zoom, from where it was to where it is going.
    ///
    /// Stepped with the lane's width rather than set at either end: at `s` the
    /// width and the zoom shrink in the same proportion, so moving both together
    /// keeps the page's `innerWidth` — its layout — still for the whole ease, and
    /// the page simply gets smaller. Setting the zoom first would lay the page out
    /// at 1.7× its width for a fifth of a second; setting it last would lay it
    /// out at 60%.
    private var sizeTransition: (from: Double, to: Double)?

    /// The ledger already holds `target`; this only moves the page there.
    func beginSizeTransition(toZoom target: Double) {
        let ladder = PaneZoom.ladder
        let next = min(max(target, ladder.first!), ladder.last!)
        sizeTransition = (webView.map { Double($0.pageZoom) } ?? zoom, next)
        zoom = next
    }

    /// One frame: `progress` is already eased.
    func stepSizeTransition(_ progress: CGFloat) {
        guard let move = sizeTransition else { return }
        webView?.pageZoom = CGFloat(move.from + (move.to - move.from) * Double(progress))
    }

    func endSizeTransition() {
        guard sizeTransition != nil else { return }
        sizeTransition = nil
        webView?.pageZoom = CGFloat(zoom)
        chrome.setZoom(zoom)
    }

    // MARK: - full screen

    /// A page's full screen element fills the pane, and the bars make way.
    ///
    /// The owner's decision (`docs/work/web-fullscreen-in-pane.md`): the pane's
    /// whole web area, never the lane, the strip or the display. The element is
    /// sized by `PaneFullscreen`'s script inside the page; all this does is give
    /// the page the 26 pt the chrome bar was holding — plus the find and
    /// download bars, when they are open — and fade the bars away over it.
    ///
    /// The page's size changes at once and only the bars move, in both
    /// directions. Growing the web view a frame at a time would reflow a video
    /// player a dozen times to arrive where one reflow puts it; a bar fading
    /// out over a page that is already its final size is the same picture
    /// without that cost. Faded rather than slid: the container does not clip,
    /// and a bar sliding down would draw across the pane below it in a split.
    func setPaneFullscreen(_ on: Bool) {
        guard on != isPaneFullscreen else { return }
        isPaneFullscreen = on
        fullscreenGeneration &+= 1
        let generation = fullscreenGeneration
        Log.debug("pane \(paneId) full screen \(on ? "fills the pane" : "ended")")

        if on, chrome.isEditingAddress { chrome.endEditingAddress() }
        completions.hide()
        layoutCompletions()
        NSLayoutConstraint.deactivate([on ? contentAboveBars : contentFillsPane])
        NSLayoutConstraint.activate([on ? contentFillsPane : contentAboveBars])
        // Now, not at the next display pass: the page is already laying its
        // element out against the viewport, and should get the final one.
        container.layoutSubtreeIfNeeded()

        let bars: [NSView] = [chrome, findBar, downloadBar]
        let findOpen = findBarHeight.constant > 0
        func alpha(_ bar: NSView) -> CGFloat { on ? 0 : (bar === findBar && !findOpen ? 0 : 1) }
        if !on { bars.forEach { $0.isHidden = false } }
        let settle = { [weak self] in
            guard let self, generation == self.fullscreenGeneration, on else { return }
            // Hidden once invisible, so nothing under the video takes a click.
            bars.forEach { $0.isHidden = true }
        }
        guard !Motion.isReduced, container.window != nil else {
            bars.forEach { $0.alphaValue = alpha($0) }
            return settle()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pane
            context.timingFunction = Motion.easeOutTiming
            for bar in bars { bar.animator().alphaValue = alpha(bar) }
        } completionHandler: {
            settle()
        }
    }

    /// Put the bars back and tell the page, for a pane key that needs the bar.
    private func leavePaneFullscreen() {
        guard isPaneFullscreen else { return }
        webView?.evaluateJavaScript(PaneFullscreen.exitScript)
        setPaneFullscreen(false)
    }

    /// `{active}` from `PaneFullscreen`'s script.
    ///
    /// Only a top frame's, and only from a view this pane knows: an embedded
    /// frame reaches here through its parents' scripts, never on its own. A
    /// popup's page shares this pane's content controller — WebKit copies it
    /// into the configuration a popup is built from — so its message arrives
    /// here too, and belongs to its dialog rather than to this pane's bar.
    private func fullScreenMessage(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let active = PaneFullscreen.isActive(message.body) else { return }
        if let webView, message.webView === webView { return setPaneFullscreen(active) }
        var dialog = popupDialog
        while let open = dialog {
            if message.webView === open.webView { return open.pageIsFullscreen = active }
            dialog = open.child
        }
    }

    // MARK: - PaneController

    func apply(_ pane: Pane) {
        self.pane = pane
        placeholder?.apply(pane)
        // Only while there is no web view to ask. A live pane's address comes
        // from `webView.url`, which is ahead of the ledger during a load and
        // during anything a single-page app does.
        if webView == nil { showAddress(pane.url) }
        // A URL change from the ledger (not from navigation) means something
        // outside asked for a different page.
        if let url = pane.url, let webView, webView.url?.absoluteString != url,
           webView.isLoading == false, pane.state == .live {
            load(url)
        }
    }

    func takeFocus() { applyPendingFocus() }

    /// Put the keyboard in the page, and keep putting it there.
    ///
    /// `takeFocus` is called once, when the ledger's focus moves. But the strip
    /// *reparents* a pane's view as it materialises, recycles and reconciles
    /// lanes, and a view that moves between superviews hands first-responder
    /// status back to the window on the way. A one-shot `makeFirstResponder`
    /// therefore leaves a freshly-opened lane focused according to the ledger
    /// and deaf in fact — ⌘A ⌘C in it does nothing until you click something.
    /// (The same bug, and the same fix, as `TerminalPaneController`.)
    ///
    /// So the *ledger* is the want, re-asserted whenever the view lands in a
    /// window, and the two guards are what stop a re-assert from becoming a
    /// focus thief:
    ///
    /// - the ledger still names this pane, so two panes reparenting in one pass
    ///   cannot fight over the keyboard;
    /// - nothing else is already typing. The strip's click monitor focuses a
    ///   pane on *any* left click inside it, including a click on this pane's
    ///   own address field, and it runs before the click is delivered — without
    ///   this guard the page would take the keyboard back a moment before the
    ///   field asked for it, and typing an address by mouse would be impossible.
    private func applyPendingFocus() {
        guard store.state.focusedPaneId == paneId else { return }
        // "Something else is typing" means *this pane's* own two fields, and
        // only those. An earlier version bailed on any `NSTextView` being first
        // responder, which looks like the same rule and is not: the window
        // always has a field editor somewhere — the sidebar's filter owns one
        // from launch — so the guard fired every time and a lane opened by
        // `maxpane open` came up deaf. Measured: `fr=<NSTextView>` on every
        // attempt, ⌘A ⌘C in the new lane left the clipboard untouched.
        guard !chrome.isEditingAddress, !findBar.isEditing else { return }
        // A sheet is the third thing in this pane that owns the keyboard, and
        // the only one the *page* did not start. Without this the next
        // reconcile hands first responder back to the document and Esc goes to
        // the page instead of dismissing the question in front of it — the page
        // taking back the keyboard from the dialog it raised.
        if let askSheet {
            askSheet.takeFocus()
            return
        }
        guard let webView, let window = container.window, window.isKeyWindow else { return }
        if let current = window.firstResponder as? NSView,
           current === webView || current.isDescendant(of: webView) { return }
        window.makeFirstResponder(webView)
    }

    func flushState() { captureSession() }

    func tearDown() {
        // Last chance: a quit tears every pane down, and a pane whose session
        // was never written comes back as a fresh page.
        captureSession()
        // Before anything else is released. Every outstanding ask holds a
        // WebKit completion handler, and a pane that goes away without calling
        // them leaves a web view that will never run JavaScript again — the
        // hang this piece's whole `OneShotReply` discipline exists for. A
        // closing pane is exactly when it is easiest to forget.
        drainAsks()
        cancelDownloads()
        // A popup belongs to the page that opened it, and that page is going
        // away. There is nothing to give the keyboard back to.
        popupDialog?.dismiss(returningFocus: false)
        scrollObservation?.invalidate()
        scrollObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        // It would fire against a pane with no web view and re-title the lane
        // from a page that is no longer loaded.
        untitledFallback?.cancel()
        untitledFallback = nil
        chromeObservations = []
        focusToken.map(store.stopObserving)
        focusToken = nil
        bookmarkToken.map(store.stopObservingBookmarks)
        bookmarkToken = nil
        keyWindowObserver.map(NotificationCenter.default.removeObserver)
        keyWindowObserver = nil
        webView.map(LinkHoverProbe.remove(from:))
        hoverRelay = nil
        webView.map(PaneFullscreen.remove(from:))
        fullScreenRelay = nil
        setPaneFullscreen(false)
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
        // The pointer cannot still be on a link in a pane that is leaving the
        // hierarchy, and the page will never send the `mouseout` that would say
        // so — the listener goes away with the view.
        chrome.setHoveredLink(nil)
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
        // A page that has stopped to ask a person something is not idle memory.
        // Evicting it would answer its own question with "cancel" — and the
        // eviction plan is recomputed on every scroll settle, so the pane would
        // come back, reload, and ask again. The status bar is already saying
        // this lane is waiting; reclaiming it from underneath that is the one
        // case where the memory policy and the user disagree.
        guard !isAsking else { return }
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
        // A real title beat the fallback to it. Cancelling here rather than at
        // each call site catches the one that matters — the `<title>` landing a
        // beat after `didFinish`, which is the common case, not the edge.
        untitledFallback?.cancel()
        untitledFallback = nil
        // Before the guards below, which return early once the lane already
        // carries the title and would otherwise swallow it on the way past.
        store.noteVisitTitle(url: webView?.url?.absoluteString, title: title)
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        guard store.lane(laneId)?.title != title else { return }
        Log.debug("pane \(paneId) title → \(title)")
        try? store.setLaneTitle(laneId, title)
    }

    /// Label a lane whose page never gave itself a `<title>`.
    ///
    /// `adoptTitle` is only ever called with a non-empty title, so an untitled
    /// page left the lane carrying the *previous* page's — five navigations
    /// through pages with no `<title>` and the header still read
    /// `Computer program – Wikipedia`. On a strip whose lanes hold dev servers,
    /// raw JSON and text files, the header is the only thing being scanned
    /// across six columns, and it was lying.
    ///
    /// Delayed rather than immediate, and the delay is the whole design.
    /// `didFinish` is the document being done, not its `<title>` having landed
    /// — that routinely arrives a beat later, which is why `titleObservation`
    /// exists at all. Labelling on the spot would put the bare host on every
    /// titled page for a blink on the way past, twenty times an hour. Nothing
    /// waits on this that is not already wrong: the header is showing the old
    /// page's title until it fires.
    private func scheduleUntitledFallback(url: String?) {
        untitledFallback?.cancel()
        untitledFallback = nil
        guard let url, !url.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let view = self.webView else { return }
            // Both checks, and both have bitten: a title that arrived in the
            // gap, and a *second* navigation that finished in it — which would
            // otherwise stamp the lane with the address it has already left.
            guard (view.title ?? "").isEmpty, view.url?.absoluteString == url else { return }
            self.adoptTitle(BrowserAddress.laneLabel(for: url))
        }
        untitledFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
        // PRD §9: desktop UA. Portrait-width desktop reflow is the point; a
        // mobile UA would get us mobile layouts, which is not what a lane is.
        // What WebKit sends unaided is not a desktop browser's string at all,
        // though — see `BrowserUserAgent` for the measurement and the choice.
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        // Off by default, which is why every video site said this browser could
        // not do full screen. On, it is the native path `PaneFullscreen` keeps
        // for ⇧ and a second request; the first request fills the pane. A
        // popup's configuration is copied from this one and inherits it.
        configuration.preferences.isElementFullscreenEnabled = true

        // `ChromeWebView`, for the context menu's nouns and nothing else. See
        // `WebContextMenu` for why the subclass is safe on a popup too.
        let webView = ChromeWebView(frame: container.bounds, configuration: configuration)
        wire(webView)
        // A panel over the top until the page has something to show. The colour
        // `wire` sets fixes the flash of *white*; it cannot fix the flash of
        // *nothing*, and a lane that arrives already saying which host it is
        // going to is what makes the arrival animation worth watching.
        showFirstPaintCover()

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

    /// Everything a web view needs to be this pane's.
    private func wire(_ webView: WKWebView) {
        // Before anything is parented or loaded: a `WKWebView` with no document
        // paints its own background, and that background is white. On a dark
        // strip every arriving web lane therefore strobed — measured at a mean
        // luminance of 253 against a strip of 16, for 65–100 ms on a fast page
        // and 550 ms on a slow one. Brighter and longer than the entrance
        // animation it steps on, and twice over if you open two lanes.
        //
        // `underPageBackgroundColor` is the public lever for it; the private
        // `drawsBackground`/`_backgroundColor` pair is the usual answer and is
        // not worth the risk. It is never reset to the page's own colour: a
        // gutter in the lane's ground is what the rest of the window already
        // looks like.
        //
        // Set again on every appearance change, and resolved first: WebKit
        // copies the colour it is handed, so a dynamic `NSColor` given once
        // would keep a light lane's gutter dark. The page itself needs nothing
        // from us — `prefers-color-scheme` follows the web view's own
        // appearance, live, `matchMedia` listeners included (`AppearanceTests`).
        webView.onAppearanceChange { view in
            (view as? WKWebView)?.underPageBackgroundColor =
                NSColor(cgColor: Theme.laneBackground.cgColor(in: view.effectiveAppearance))
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]

        self.webView = webView
        webView.pageZoom = CGFloat(zoom)
        // Weak, and that matters: `WKUserContentController` holds its message
        // handlers for the life of the configuration, which this pane owns.
        let relay = ScriptMessageRelay { [weak self] body in
            self?.chrome.setHoveredLink(body as? String)
        }
        hoverRelay = relay
        LinkHoverProbe.install(on: webView, handler: relay)
        let fullScreen = FullScreenMessageRelay { [weak self] message in self?.fullScreenMessage(message) }
        fullScreenRelay = fullScreen
        PaneFullscreen.install(on: webView, handler: fullScreen)
        observeChrome(webView)
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
    }

    /// Constraints rather than an autoresizing mask, and that is not a taste
    /// call. `contentHost` is laid out by Auto Layout, so its bounds are still
    /// zero when a pane is built; a springs-and-struts child pinned to a
    /// zero-size parent resizes *proportionally* from nothing and ends up a
    /// fraction of the lane's width. The symptom is a page that renders in the
    /// left two-thirds of the column with dead background beside it.
    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        isParented = true
        // The view just moved into a hierarchy, which is exactly when AppKit
        // takes first-responder status away from it.
        applyPendingFocus()
    }

    private func destroyWebView() {
        // The page being destroyed is still a page that asked. Its completion
        // handlers are about to belong to nothing, and the sheet in front of it
        // would be a question about a document that no longer exists.
        drainAsks()
        // Its popup's `window.opener` is about to be nothing, and a sign-in
        // that cannot report back is not worth leaving on screen.
        popupDialog?.dismiss(returningFocus: false)
        scrollObservation?.invalidate()
        scrollObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        untitledFallback?.cancel()
        untitledFallback = nil
        chromeObservations = []
        webView.map(LinkHoverProbe.remove(from:))
        hoverRelay = nil
        webView.map(PaneFullscreen.remove(from:))
        fullScreenRelay = nil
        // The snapshot standing in for the page has an address to show.
        setPaneFullscreen(false)
        chrome.setHoveredLink(nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        isParented = false
        // After the view is gone, so the arrows go grey rather than keep
        // promising a back list that no longer exists.
        refreshChrome()
        // A pane evicted before it ever painted still has its cover up, and that
        // panel is exactly what an evicted pane shows anyway — so it stays, and
        // stops being the load's to remove.
        forgetFirstPaintCover()
        showPlaceholder()
    }

    /// The dark panel a fresh web pane shows until its page has painted.
    ///
    /// It is a `PlaceholderView` with no snapshot — the dimmed panel with the
    /// host on it that an evicted pane already falls back to — because a pane
    /// that has not loaded yet and a pane whose picture is missing are the same
    /// situation and should not be two different rectangles.
    ///
    /// It is removed a beat after `didFinish` rather than at `didCommit`:
    /// commit is the response arriving, which is before the first paint, so
    /// lifting the cover there would put the white back. The cost is that a page
    /// which never finishes keeps its cover, so `firstPaintDeadline` lifts it
    /// anyway — a cover that outstays a slow page would hide a page that is
    /// already readable, which is worse than the flash.
    private func showFirstPaintCover() {
        guard placeholder == nil else { return }
        showPlaceholder()
        firstPaintCover = placeholder
        firstPaintDeadline = DispatchWorkItem { [weak self] in self?.hideFirstPaintCover() }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.firstPaintGraceSeconds, execute: firstPaintDeadline!)
    }

    /// How long a cover may wait for a page that is not coming.
    ///
    /// Long enough for a page on a bad connection to get its first bytes out,
    /// short enough that a lane is never a dark panel you have to wonder about.
    private static let firstPaintGraceSeconds: TimeInterval = 2.5

    /// Let go of the cover without taking it off screen.
    ///
    /// For the two moments when the panel on screen stops being a *cover* and
    /// becomes something else's: an evicted pane, where the same view is now the
    /// snapshot placeholder, and a deferred pane being built, where it has
    /// already been removed by hand. Either way the deadline must not fire and
    /// pull a view that is no longer this one's to pull.
    private func forgetFirstPaintCover() {
        firstPaintDeadline?.cancel()
        firstPaintDeadline = nil
        firstPaintCover = nil
    }

    private func hideFirstPaintCover() {
        guard let cover = firstPaintCover else { return forgetFirstPaintCover() }
        forgetFirstPaintCover()
        // Only the cover goes. `placeholder` is also what an *evicted* pane
        // shows, and clearing the field blind would leak that view the next time
        // one was built.
        if placeholder === cover { placeholder = nil }
        guard !Motion.isReduced else { return cover.removeFromSuperview() }
        NSAnimationContext.runAnimationGroup { context in
            // The page underneath is already painted, so this is a cross-fade
            // between two finished pictures rather than a reveal. Short: the
            // pane has nothing left to say.
            context.duration = Motion.pane
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cover.animator().alphaValue = 0
        } completionHandler: {
            cover.removeFromSuperview()
        }
    }

    private func showPlaceholder() {
        guard placeholder == nil else { return }
        let view = PlaceholderView(pane: pane)
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        placeholder = view
    }

    private func load(_ url: String) {
        guard let webView, let parsed = URL(string: url) else { return }
        // Before the request: a load this pane asked for is never a redirect,
        // and `.other` alone cannot tell the two apart — an address typed into
        // the chrome bar arrives with the same navigation type a
        // `location.replace` does.
        trail.paneWillLoad()
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
    /// A new document replaced the one that was full screen — a link, a reload,
    /// back — and the new one has not asked for anything. `pushState` never
    /// commits, so a single-page player changing its URL keeps its full screen.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        setPaneFullscreen(false)
    }

    /// The page's process died, and the full screen element with it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        setPaneFullscreen(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // PRD §9: keep pane.url and the lane title current as the user navigates.
        if let url = webView.url?.absoluteString {
            pane.url = url
            store.setPaneUrl(paneId, url)
            // Every hop, not `backForwardList.currentItem?.initialURL`: that
            // holds one address and a chain is a list, and a client-side
            // redirect has already overwritten it by the time we are asked.
            // See `RedirectTrail`.
            store.recordVisit(
                paneId: paneId, url: url, title: webView.title,
                redirectChain: trail.didFinish(at: url, now: CFAbsoluteTimeGetCurrent()))
        }
        if let title = webView.title, !title.isEmpty {
            adoptTitle(title)
        } else {
            scheduleUntitledFallback(url: webView.url?.absoluteString)
        }
        if let y = pendingScrollRestore {
            pendingScrollRestore = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))")
        }
        // A navigation is exactly when the history changed, so do not wait for
        // the next sample to record it.
        captureSession()
        // One turn of the run loop after the load finished. `didFinish` is the
        // document being done, not the compositor having drawn it, and lifting
        // the cover in the same turn puts one frame of unpainted view back on
        // screen — which is the whole thing this is here to prevent.
        DispatchQueue.main.async { [weak self] in self?.hideFirstPaintCover() }
    }

    /// The server answered a 3xx. The address we were pointed at a moment ago
    /// is a real hop the user could search for later, and until now a two-hop
    /// chain lost its middle.
    func webView(_ webView: WKWebView,
                 didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        trail.serverRedirect(to: webView.url?.absoluteString)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        trail.didFail()
        // A failed load leaves the pane where it was rather than blanking it;
        // the URL in the ledger is still the right thing to retry. The cover
        // goes, though: WebKit's own error page is the only thing that can say
        // what went wrong, and a dark panel over it would hide it until the
        // grace period ran out.
        hideFirstPaintCover()
        report(error)
    }

    /// A load that had already committed and then came apart.
    ///
    /// Rarer than the provisional case and it was not handled at all, which
    /// made it the one failure with *no* path to the chrome — the document is
    /// on screen and half-built, and the hairline would have parked wherever
    /// the bytes stopped.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        trail.didFail()
        hideFirstPaintCover()
        report(error)
    }

    /// Put a failed navigation where the person who typed it can see it.
    ///
    /// Without this the whole event was invisible: `didFailProvisionalNavigation`
    /// had an empty body, so typing an address that does not resolve left the
    /// page unchanged and snapped the URL bar back — indistinguishable from the
    /// app having ignored the keystroke.
    private func report(_ error: Error) {
        let error = error as NSError
        let failing = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        guard let text = BrowserAddress.failure(
            domain: error.domain, code: error.code, failingURL: failing)
        else {
            // A cancel or a download. Nothing to say, but the hairline still
            // has to come down — `estimatedProgress` stops where it stopped.
            chrome.setProgress(0)
            return
        }
        Log.debug("pane \(paneId) navigation failed: \(error.domain) \(error.code) — \(text)")
        chrome.showFailure(text)
    }
}

// MARK: - popups

extension WebPaneController: WKUIDelegate {
    /// PRD §9, as the sign-in bug amended it: a `target=_blank` becomes a new
    /// web lane right of this one, and a page's `window.open` conversation
    /// becomes a dialog over the window — never a lane, never a ledger row.
    /// Which is which is `PopupPolicy`; why a dialog is `WebPopupDialog`.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let intent = PopupIntent(navigationAction, windowFeatures)
        let disposition = PopupPolicy.disposition(for: intent)
        let url = navigationAction.request.url?.absoluteString
        Log.debug("""
            pane \(paneId) window.open \(url ?? "about:blank") \
            type=\(navigationAction.navigationType.rawValue) \
            scripted=\(intent.isScripted) geometry=\(intent.specifiesGeometry) \
            chromeless=\(intent.suppressesChrome) → \(disposition)
            """)

        switch disposition {
        case .lane:
            // A destination, not a conversation: open it ourselves so it lands
            // in the strip under the same ordering rules as everything else.
            if let url { openLane(url) }
            return nil
        case .popup:
            // WebKit wants the finished view back from this call, built from
            // *its* configuration — that configuration is the opener
            // relationship. The dialog builds it, and is on screen, before this
            // returns.
            let dialog = WebPopupDialog.show(
                replacing: popupDialog, configuration: configuration, features: windowFeatures,
                pane: self, parent: nil, openerURL: webView.url?.absoluteString,
                over: popupParent?() ?? container.window)
            popupDialog = dialog
            return dialog.webView
        }
    }

    /// A page to read, from this pane's page or from a popup over it: a new web
    /// lane right of this one, revealed.
    func openLane(_ url: String) {
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        let before = paneIds()
        do {
            try store.newWebLane(url: url, near: laneId)
        } catch {
            Log.warn("pane \(paneId) could not open a lane for \(url): \(error)")
            return
        }
        revealLane(holding: paneIds().subtracting(before).first)
    }

    /// A popup this pane opened has gone. The keyboard comes home — focused in
    /// the ledger, the lane brought on screen if it was not, the page first
    /// responder — unless another popup has already taken its place.
    func popupDidClose(_ dialog: WebPopupDialog, returningFocus: Bool) {
        if popupDialog === dialog { popupDialog = nil }
        guard returningFocus, popupDialog == nil else { return }
        try? store.focusPane(paneId)
        if container.window == nil || container.visibleRect.isEmpty {
            revealLane(holding: paneId)
        }
        (container.window ?? popupParent?())?.makeKey()
        takeFocus()
    }

    private func revealLane(holding paneId: String?) {
        guard let paneId, let laneId = store.lane(containing: paneId)?.id else { return }
        onRevealLane?(laneId)
    }

    /// `window.close()` from this pane's own page. A popup's is its dialog's.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        Log.debug("pane \(paneId) closed itself")
        // WebKit is still on the stack and this tears its view down. One turn
        // later is soon enough and is not inside the callback that asked.
        Task { @MainActor [store, paneId] in
            try? store.closePane(paneId)
        }
    }

    private func paneIds() -> Set<String> {
        Set(store.state.lanes.lazy.flatMap(\.panes).map(\.id))
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
        // The profile gives a launch its own cookie jars. A throwaway instance
        // that logs into something must not write into the jar the real one
        // reads, and a UUID derived from the shard name alone would. The
        // default profile's salt is empty on purpose — see `Profile.dataSalt`.
        let salt = Profile.current.dataSalt
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

/// The web pane's outermost view, and the only reason it is not a plain
/// `NSView`.
///
/// A pane needs three key equivalents of its own (⌘F, ⌘←, ⌘→) and they cannot go
/// through `Commands.swift`, because they belong to whichever pane has the
/// keyboard rather than to the app. `performKeyEquivalent` is the only hook
/// AppKit offers for that: the window walks the view tree with it *before* the
/// main menu sees the event, so a pane's key can win over a global one without
/// the global one having to know.
///
/// Subviews get first refusal, so the find field's own ⌘A and the address
/// field's ⌘C still work.
@MainActor
final class WebPaneContainer: NSView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// The strip recycles lane views, so a pane's container lands in a window
    /// more than once in its life — and every one of those landings costs it
    /// first-responder status.
    var onMovedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMovedToWindow?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Before the subviews, because one of them is the `WKWebView` and
        // "subviews get first refusal" was written for the two text fields.
        // A focused web view claims *every* ⌘-chord here and forwards it to the
        // page, and this walk beats the main menu — so ⌘O reached Gmail instead
        // of opening the picker, and a page that calls `preventDefault` keeps it
        // for good. Returning false sends it on to the menu, which is where an
        // app key belongs; the fields keep ⌘A and ⌘C because neither is in
        // `Commands.swift`, and ⌘F stays a pane key for the same reason.
        if Command.claims(event) { return false }
        if super.performKeyEquivalent(with: event) { return true }
        return onKeyEquivalent?(event) ?? false
    }
}
