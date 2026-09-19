import AppKit
import LanedCore
import UniformTypeIdentifiers

/// The one window. PRD §3 rules out multi-window and multi-display for v1, and
/// §5.2 wants it fullscreen with the menu bar auto-hidden.
@MainActor
public final class StripWindowController: NSWindowController, CommandHandling {
    private let store: StripStore
    private let config: Config
    private let split = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let strip: StripViewController
    /// The row above the strip, level with the sidebar's header. See `StripToolbar`.
    private let stripToolbar = StripToolbar()
    private var palette: SearchPaletteController?
    /// Held while it is on screen, like `palette` — for the same reason: the
    /// table's data source is weak.
    private var omni: OmniPicker?
    private var openServer: OpenServer?
    private var alternateMonitor: Any?
    private var memoryDashboard: MemoryDashboard?
    private var helpPanel: HelpPanel?
    private var settingsWindow: SettingsWindow?
    /// `config.toml`, open for ⌘,. Set by the app delegate, which owns it
    /// because it also applies `theme` from it. Setting it opens the server
    /// book, which is what makes `[[servers]]` apply live from then on.
    public var configStore: ConfigStore? {
        didSet {
            guard let configStore, serverBook == nil else { return }
            let book = RelayServerBook(
                servers: servers, registry: sessions, store: configStore,
                pollInterval: config.sessionPollSeconds)
            book.onServerChanged = { [weak self] name in self?.strip.reattachPanes(onServer: name) }
            serverBook = book
            // `sidebar_collapse_hides_lanes` applies as the file is saved:
            // off, every hidden lane is back; on, the folds take effect.
            configObserver = NotificationCenter.default.addObserver(
                forName: ConfigStore.didChange, object: configStore, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.refreshHidden() }
            }
        }
    }
    /// Every add, remove, enable, rename and pasted token for a remote
    /// server goes through this (ADR-0021), from Settings, the CLI and a
    /// hand edit of the file alike.
    public private(set) var serverBook: RelayServerBook?
    /// Held for the life of the window, like `splitResizeObserver`.
    private var configObserver: Any?
    /// Held only so a second ⌥⌘Y raises the wizard already on screen instead of
    /// stacking another one over it; the wizard keeps itself alive otherwise.
    private var importWizard: ImportHistoryWizard?
    private var passwordsWizard: ImportPasswordsWizard?
    /// Held for the same reason as the wizard, and with more cause: this one is
    /// expected to stay open beside the strip while the reader works.
    private var historyWindow: HistoryWindow?
    private let statusBar = StatusBar()
    private var statusTimer: Timer?
    /// Our subscription to `WebAskCenter`, so the bright count appears the
    /// instant a page asks rather than on the next status tick.
    private var askToken: UUID?
    /// The strip's distance from the top of its half of the split. Non-zero
    /// only when the sidebar is collapsed and the window is not fullscreen —
    /// the one arrangement where the traffic lights land on a lane header.
    private var stripTop: NSLayoutConstraint!
    /// Held, and removed nowhere — same as `alternateMonitor`. There is one
    /// window and it lives as long as the process, so there is nothing for a
    /// `deinit` to clean up before exit; Swift 6 will not compile one that tries
    /// anyway, because a nonisolated `deinit` cannot touch main-actor state.
    private var splitResizeObserver: Any?
    /// Every session Relay knows about, attached or not. The sidebar, the
    /// picker and the status bar all read this one registry so they cannot
    /// disagree about how many sessions exist.
    public let sessions: SessionRegistry
    /// The remote servers this launch knows (ADR-0020). Empty when
    /// `config.toml` names none, and then nothing about the local path is
    /// different from before servers existed.
    let servers: RelayServers

    public init(store: StripStore, config: Config) {
        self.store = store
        self.config = config
        self.servers = RelayServers(config: config)
        self.sessions = SessionRegistry(
            pollInterval: config.sessionPollSeconds,
            remotes: servers.sources(pollInterval: config.sessionPollSeconds))
        self.sidebar = SidebarViewController(store: store)
        self.strip = StripViewController(store: store, config: config, servers: servers)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // Two identical windows is how several agents drove the wrong instance
        // in one afternoon. The title carries it for Mission Control and the
        // window list, where a title is all there is; the footer carries it on
        // screen, where the title bar is hidden.
        window.title = Profile.current.isDefault ? "Max Pane" : "Max Pane — \(Profile.current.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The strip is the interface; the menu bar is an interruption.
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        super.init(window: window)

        // Before any view reads the store: which lanes a folded sidebar group
        // hides is a question about sessions and a setting, and both live on
        // this side (ADR-0024). Counted once now, so the first strip drawn
        // agrees with a setting that was changed while the app was shut.
        store.hidingInputs = { [weak self] in
            guard let self else { return StripStore.HidingInputs() }
            return StripStore.HidingInputs(
                enabled: (self.configStore?.config ?? self.config).sidebarCollapseHidesLanes,
                telemetry: self.sessions.sessions,
                hasServers: !self.sessions.serverStates.isEmpty)
        }
        store.refreshHidden()

        stripToolbar.onLayout = { [weak self] gallery in
            self?.strip.setLayout(gallery ? .gallery : .lanes)
        }
        stripToolbar.onFind = { [weak self] in self?.perform(.search) }
        strip.onLayoutChange = { [weak self] layout in
            self?.stripToolbar.setLayout(isGallery: layout == .gallery)
        }

        // Deliberately not `NSSplitViewItem(sidebarWithViewController:)`. That
        // gives the item `.sidebar` behaviour, and the system collapses a
        // sidebar on its own when it decides space is tight — which on a strip
        // that is *meant* to be wider than the window means the session list
        // vanishes while you are working and you did not ask it to. A plain
        // item collapses only when told.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        // 260, not 220. A session row carries a title, a state chip, a
        // throughput reading and an age; at 220 the title — the only part that
        // tells two sessions apart — is the one that truncates.
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        // Remember where the user drags the divider.
        split.splitView.autosaveName = "MaxPaneStripSplit"
        split.addSplitViewItem(sidebarItem)
        // The strip, with its toolbar above and the footer under it. The footer
        // was chosen over a toolbar because chrome across the top eats the lane
        // headers' room; the toolbar came back when the owner asked for the
        // switch and ⌘P level with the sidebar's header, and it costs the strip
        // exactly the height the sidebar's header already costs the sidebar.
        let stripSide = NSViewController()
        stripSide.view = NSView()
        // The strip's own ground, because with the sidebar collapsed this view
        // shows through above the strip as the band the traffic lights sit in.
        // Left unpainted that band is the window's grey, which reads as a title
        // bar — the thing this window does not have.
        stripSide.view.wantsLayer = true
        stripSide.view.layerBackgroundColor = Theme.stripBackground
        strip.view.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        stripSide.addChild(strip)
        stripSide.view.addSubview(stripToolbar)
        stripSide.view.addSubview(strip.view)
        stripSide.view.addSubview(statusBar)
        stripToolbar.translatesAutoresizingMaskIntoConstraints = false
        // The toolbar hangs from the top and the strip from the toolbar, so the
        // one constant `updateTitlebarAvoidance` moves takes both down together.
        stripTop = stripToolbar.topAnchor.constraint(equalTo: stripSide.view.topAnchor)
        NSLayoutConstraint.activate([
            stripTop,
            stripToolbar.leadingAnchor.constraint(equalTo: stripSide.view.leadingAnchor),
            stripToolbar.trailingAnchor.constraint(equalTo: stripSide.view.trailingAnchor),
            stripToolbar.heightAnchor.constraint(equalToConstant: StripToolbar.height),
            strip.view.topAnchor.constraint(equalTo: stripToolbar.bottomAnchor),
            strip.view.leadingAnchor.constraint(equalTo: stripSide.view.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: stripSide.view.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: stripSide.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: stripSide.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: stripSide.view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height),
        ])
        split.addSplitViewItem(NSSplitViewItem(viewController: stripSide))
        window.contentViewController = split

        // Setting `contentViewController` makes AppKit resize the window to the
        // content's *fitting* size. An empty strip has no intrinsic width, so
        // that collapses the window to the sidebar's minimum thickness — a
        // 228×50 sliver. Restore a real size and floor it, after the assignment.
        window.setContentSize(NSSize(width: 1600, height: 1000))
        // Open the sidebar at a width a session row actually fits in. Only on a
        // first run — afterwards the autosave above wins.
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MaxPaneStripSplit") == nil {
            split.splitView.setPosition(290, ofDividerAt: 0)
        }
        window.minSize = NSSize(width: 720, height: 400)
        window.center()

        statusBar.onToggleSidebar = { [weak self] in self?.perform(.toggleSidebar) }
        sidebar.registry = sessions
        sidebar.onSelect = { [weak self] laneId, paneId in
            guard let self else { return }
            self.bringBack(laneId: laneId)
            _ = self.strip.select(laneId: laneId, paneId: paneId)
        }
        // In the gallery a double click expands that lane's tile in place. On
        // the strip it is the same select a second click always ran.
        sidebar.onOpen = { [weak self] laneId, paneId in
            guard let self else { return }
            self.bringBack(laneId: laneId)
            self.strip.openLane(laneId: laneId, paneId: paneId)
        }
        sidebar.onNewSession = { [weak self] in self?.perform(.openAnything) }
        sidebar.onAttach = { [weak self] key in self?.attach(key) }
        // A server's header in the sidebar is the state of that server, and
        // the place to do something about it is Settings › Servers.
        sidebar.onOpenServer = { [weak self] name in self?.showSettings(server: name) }
        // Through `launch`, so a kept page lands exactly where a ⌘O page lands:
        // a new lane, immediately right of the one you are in.
        sidebar.onOpenBookmark = { [weak self] url in
            guard let self else { return }
            self.launch(.open(url), near: self.store.focusedLane)
        }
        // The window's own delegate, for the two fullscreen transitions. Nothing
        // else wants it, and `NSWindowController` would take it anyway.
        window.delegate = self
        // Not just the ⌘B command: the divider can be dragged all the way left,
        // which collapses the sidebar without any command running. Observing the
        // split view catches both, and the drag in progress as well.
        splitResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split.splitView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTitlebarAvoidance() }
            }
        startSideChannels()
        installAlternateShortcuts()
        updateTitlebarAvoidance()
    }

    /// Move whatever is under the close/minimise/zoom buttons out from under
    /// them — the sidebar's `+ NEW` row, or the first lane's header when the
    /// sidebar is collapsed and the strip is the leftmost thing.
    ///
    /// Both containers are asked every time rather than one being chosen here:
    /// the answer is a function of where each one starts, so a sidebar that has
    /// been dragged narrower than the buttons gets the inset on its own without
    /// this having to know that could happen.
    private func updateTitlebarAvoidance() {
        guard let window, stripTop != nil else { return }
        let band = TitlebarAvoidance.band(of: window)
        let buttonsEnd = TitlebarAvoidance.buttonsEnd(of: window)
        // One inset for both columns. The strip used to run to the top whenever
        // the sidebar held the corner; now its toolbar has to sit level with the
        // sidebar's header, so it drops by exactly what the header drops by —
        // windowed that is the title bar's band, in full screen nothing.
        let inset = TitlebarAvoidance.inset(band: band, buttonsEndAt: buttonsEnd, contentStartsAt: 0)
        sidebar.titlebarInset = inset
        if stripTop.constant != inset { stripTop.constant = inset }
        stripToolbar.setLayout(isGallery: strip.isGallery)
    }

    /// Every key the menu cannot carry.
    ///
    /// Two kinds land here. A menu item holds exactly one key equivalent, and
    /// ⌘O and ⌘T are one thought — so the second is matched here, ahead
    /// of the responder chain. And a chord with no ⌘ in it cannot be a key
    /// equivalent at all without being taken from every text field in the
    /// window, which is why Esc spent so long declared and unlistened-for:
    /// `.ungather` named it, the menu skipped it, and nothing else ever looked.
    ///
    /// Both come from `Keymap.active`, so a chord chosen in the config file is
    /// matched exactly like a default one.
    private func installAlternateShortcuts() {
        alternateMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            // A palette on screen owns the keyboard; ⌘T while typing a command
            // into the picker must not open a second picker.
            guard NSApp.keyWindow === self.window else { return event }
            let typed = KeyChord(key: event.charactersIgnoringModifiers ?? "",
                                 modifiers: event.modifierFlags)
            for command in Command.allCases {
                // The first chord is the menu's, and AppKit has already had it.
                // Matching it again here would run the command twice.
                let mine = command.chords
                let extras = command.menuChord == nil ? mine : Array(mine.dropFirst())
                guard extras.contains(typed) else { continue }
                // A chord with no ⌘ is one a text field may legitimately want —
                // Esc closes the find bar and cancels an address edit long
                // before it has any business leaving gather view — and
                // `canPerform` is what stops a key firing when its command has
                // nothing to do.
                if !typed.modifiers.contains(.command) {
                    // In the gallery the focused tile gets every key without a
                    // ⌘ — Esc and Return above all, because answering a prompt
                    // from its thumbnail is the point of the gallery. Leaving
                    // gather view is still in the menu.
                    guard !self.strip.isGallery else { continue }
                    guard !self.isEditingText, self.canPerform(command) else { continue }
                }
                self.perform(command)
                return nil
            }
            return event
        }
    }

    /// Whether the keyboard is in a text field rather than in the strip.
    ///
    /// The field editor is the first responder while any `NSTextField` in the
    /// window is being typed into, so this catches the address bar, the find
    /// field and the search palette's field with one question.
    private var isEditingText: Bool {
        let responder = window?.firstResponder
        return responder is NSText || responder is NSTextView
    }

    /// The two things that talk to the world outside the window: the shim's
    /// socket, and RelayTTY's session directory.
    private func startSideChannels() {
        // Snapshots outlive the panes that made them when the app is killed;
        // sweep the ones with no pane before anything can read a stale path.
        let live = Set(store.state.lanes.flatMap(\.panes).map(\.id))
        SnapshotStore.sweep(keeping: live)

        do {
            openServer = try OpenServer { [weak self] request in
                MainActor.assumeIsolated {
                    self?.handle(request) ?? .refused("max pane is shutting down")
                }
            }
        } catch {
            // Not fatal. Without it, URLs from terminals go to the default
            // browser — the same thing that happens when the app is not running.
            FileHandle.standardError.write(Data("maxpane: open socket unavailable: \(error)\n".utf8))
        }

        store.observe { [weak self] state in
            guard let self else { return }
            self.syncAttachedSessions()
            self.refreshStatus()
            // Focusing a session's pane is what clears its DONE — a click, the
            // sidebar, ⌘P or the keyboard, they all land here.
            if let paneId = state.focusedPaneId,
               let key = self.store.pane(paneId)?.sessionKey {
                self.sessions.acknowledge(key)
            }
        }
        strip.onLaneLostWire = { [weak self] server in self?.sessions.laneLostWire(server: server) }
        sessions.doneHold = config.doneHoldSeconds
        sessions.onStateChange = { [weak self] telemetry, _, to in
            self?.alert(telemetry, became: to)
        }
        sessions.observe { [weak self] telemetry in
            guard let self else { return }
            // First: a session that moved directory may have moved group, and
            // the strip below should be told about sessions on the lanes it
            // is about to have.
            self.store.refreshHidden()
            self.strip.sessionsChanged(telemetry, servers: self.sessions.serverStates)
            self.sidebar.sessionsChanged(telemetry)
            self.refreshStatus()
        }
        statusBar.onClickSessions = { [weak self] in self?.perform(.openSessions) }
        statusBar.onClickMemory = { [weak self] in self?.perform(.showMemory) }
        // ASKING first, as the bar reads; then the agents that are BLOCKED.
        statusBar.onClickAsking = { [weak self] in
            guard let self, !self.strip.revealNextAsking() else { return }
            self.revealNextBlocked()
        }
        // Pushed rather than polled. The status timer would pick this up within
        // a second or two, and a second or two is exactly how long a page that
        // has stopped dead looks broken for — the whole reason this signal
        // exists is that the lane asking may be nowhere on screen.
        askToken = WebAskCenter.shared.observe { [weak self] in self?.refreshStatus() }
        // WebKit's footprint is sampled, not pushed, so the footer needs its own
        // slow tick to stay honest about it.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    /// A request from the `maxpane` CLI.
    ///
    /// This is the whole scriptable surface, and it is also how the app gets
    /// tested: driving AppKit from outside needs accessibility permission, and a
    /// socket does not.
    private func handle(_ request: OpenServer.Request) -> OpenServer.Reply {
        switch request {
        case .open(let url, let sessionId, _):
            return openFromCLI(url: url, sessionId: sessionId)
        case .run(let command, let args, let sessionId, let cwd):
            return runFromCLI(command: command, args: args, sessionId: sessionId, cwd: cwd)
        case .list:
            return OpenServer.Reply(ok: true, lanes: describeStrip())
        case .runOn(let server, let command, let args):
            return runOnServerFromCLI(server: server, command: command, args: args)
        case .listSessions:
            return OpenServer.Reply(ok: true, lanes: describeSessions())
        case .attach(let server, let id):
            return attachFromCLI(SessionKey(server: server, id: id))
        case .addServer(let name, let url):
            return addServer(name: name, startupURL: url)
        case .listServers:
            return OpenServer.Reply(ok: true, lanes: describeServers())
        }
    }

    /// `maxpane server add NAME URL`. The URL is the one the server printed at
    /// startup, token and all: the same door Settings › Servers uses
    /// (`RelayServerBook.add`) — the token goes to the Keychain against the
    /// server's host, the name and base URL go to `config.toml` as a
    /// `[[servers]]` table, and the server's sessions appear in the sidebar
    /// as soon as it answers. Nothing here prints or logs the token.
    private func addServer(name: String, startupURL: String) -> OpenServer.Reply {
        guard let serverBook else { return .refused("the config file is not open") }
        // The same name again is a new token for that server — what a
        // restarted server needs, and the only way to give it one from a
        // shell with nobody at the screen. `pasteToken` refuses a line for
        // another host, so a name cannot be pointed somewhere else this way.
        if serverBook.entries.contains(where: { $0.name == name }) {
            if let why = serverBook.pasteToken(name, pasted: startupURL) { return .refused(why) }
            return OpenServer.Reply(ok: true, lanes: "\(name)\ttoken replaced in the Keychain; connecting\n")
        }
        switch serverBook.add(pasted: startupURL, name: name) {
        case .failure(let why):
            return .refused(why.text)
        case .success(let entry):
            let token = RelayServerTokens.parse(startupURL)?.token == nil
                ? "no token in that URL — paste the server's Auth URL in Settings › Servers"
                : "token stored in the Keychain"
            return OpenServer.Reply(ok: true, lanes: "\(entry.name)\t\(entry.url)\t\(token); connecting\n")
        }
    }

    /// One line per configured server: name, URL, and how it is doing.
    /// `maxpane sessions`. One line per session, tab-separated: where it is,
    /// its state, whether a lane holds it, its directory, its title. Local
    /// sessions first, then each server's, the order the sidebar uses.
    private func describeSessions() -> String {
        sessions.sessions.values
            .sorted { $0.key < $1.key }
            .map { t in
                let lane = store.lane(holdingSession: t.key) != nil ? "lane" : "-"
                // A session on a server that is not answering is `offline`,
                // never the `idle` it last was: nobody can vouch for it.
                let state = t.isOffline ? "offline" : (t.isRunning ? "\(t.state)" : "exited")
                return "\(t.key)\t\(state)\t\(lane)\t\(t.cwd)\t\(t.title)\n"
            }.joined()
    }

    /// `maxpane attach [SERVER:]ID`. The sidebar's and ⌘O's own `attach`, with
    /// the one check they do not need: a row there exists because the registry
    /// has the session, and a typed id may name nothing.
    private func attachFromCLI(_ key: SessionKey) -> OpenServer.Reply {
        guard let telemetry = sessions.telemetry(for: key) else {
            if let server = key.server, serverBook?.entries.contains(where: { $0.name == server }) != true {
                return .refused("\(server): not a configured server (maxpane server ls)")
            }
            return .refused("\(key): no such session (maxpane sessions)")
        }
        guard telemetry.isRunning else { return .refused("\(key): that session has exited") }
        attach(key)
        guard store.lane(holdingSession: key) != nil else {
            return .refused("\(key): could not be attached")
        }
        return OpenServer.Reply(ok: true, session: key.description)
    }

    /// `maxpane run @SERVER COMMAND…`. The CLI is handed argv, as `run` is, so
    /// it goes to the spawner as a program and its arguments; the spawner sends
    /// the no-exec wrapper either way (ADR-0022). The server answers after this
    /// socket has, so the reply is that the asking has started, and a failure
    /// is the alert a failed ⌘T beside a remote lane shows.
    private func runOnServerFromCLI(server: String, command: String, args: [String]) -> OpenServer.Reply {
        let place = SpawnPlace(server: server, cwd: nil)
        let near = store.focusedLane?.id
        do {
            let size = newSessionSize()
            try spawner(at: place).spawn(
                cwd: nil, command: command.isEmpty ? nil : command, args: args,
                cols: size.cols, rows: size.rows
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let session):
                    do {
                        try self.store.newTerminalLane(session: session.key, near: near)
                        if let laneId = self.store.lane(holdingSession: session.key)?.id {
                            self.strip.reveal(laneId: laneId, flash: true)
                        }
                    } catch {
                        self.showError(error)
                    }
                case .failure(let error):
                    self.showError(error)
                }
            }
            return OpenServer.Reply(ok: true, lanes: "\(server)\tstarting; the lane arrives when the server answers (maxpane ls)\n")
        } catch {
            return .refused(Self.describe(error))
        }
    }

    private func describeServers() -> String {
        guard let serverBook else { return "" }
        return serverBook.entries.map { entry in
            let status = serverBook.status(of: entry)
            var state = status.word
            if status.kind == .connected { state += " · \(status.sessions) session\(status.sessions == 1 ? "" : "s")" }
            if let detail = status.detail { state += " — \(detail)" }
            return "\(entry.name)\t\(entry.url)\t\(state)\n"
        }.joined()
    }

    /// PRD §7.1. The web lane goes immediately right of the terminal that asked,
    /// tagged with that terminal's project. A URL from somewhere that is not a
    /// lane — a plain shell, a cron job — goes to the end of the strip rather
    /// than being refused.
    /// A URL from outside the app — the system handing over a link because Max
    /// Pane is the default browser. Deliberately the same path as the shim's
    /// `maxpane open`, so a link from Mail and a link from a terminal cannot
    /// drift apart in where they land or what they remember.
    public func openFromOutside(_ url: String) {
        _ = openFromCLI(url: url, sessionId: "")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFromCLI(url: String, sessionId: String) -> OpenServer.Reply {
        let near = sessionId.isEmpty ? nil : strip.lane(forRelaySession: sessionId)
        do {
            try store.newWebLane(url: url, near: near)
            // Everything deliberately launched joins the picker's memory,
            // whichever door it came in by — the shim's whole point is that
            // `open` from a terminal is the same act as ⌘T.
            store.noteRecent(.url, url)
            if let laneId = store.state.lanes.last?.id, near == nil {
                strip.reveal(laneId: laneId, flash: true)
            }
            return .handled
        } catch {
            return .refused(Self.describe(error))
        }
    }

    /// `maxpane run htop` — a new terminal lane running `htop`.
    ///
    /// The session is started here rather than by the CLI so it inherits the
    /// app's environment, including `BROWSER` pointing back at the shim.
    private func runFromCLI(command: String, args: [String], sessionId: String, cwd: String)
        -> OpenServer.Reply
    {
        let near = sessionId.isEmpty ? store.focusedLane?.id : strip.lane(forRelaySession: sessionId)
        // The caller's own cwd, when it gave one, beats the focused pane's.
        let workingDirectory = cwd.isEmpty
            ? (store.state.focusedPaneId.flatMap { strip.cwd(ofPane: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.path)
            : cwd
        do {
            let size = newSessionSize()
            let session = try LocalSpawner(config: config).spawn(
                cwd: workingDirectory,
                command: command.isEmpty ? nil : command,
                args: args,
                cols: size.cols, rows: size.rows)
            try store.newTerminalLane(relaySessionId: session, near: near)
            if !command.isEmpty {
                store.noteRecent(
                    .command, ([command] + args).joined(separator: " "), cwd: workingDirectory)
            }
            if let laneId = store.state.lanes.last?.id {
                strip.reveal(laneId: laneId, flash: true)
            }
            return OpenServer.Reply(ok: true, session: session)
        } catch {
            return .refused(Self.describe(error))
        }
    }

    /// One line per lane, tab-separated, so `maxpane ls` pipes.
    ///
    /// A docked lane is listed — it is on screen, and leaving it out would make
    /// `ls` a worse answer to "what is running" than looking at the window —
    /// but it has no strip position, so it prints `◀` or `▶` where the others
    /// print a number. Numbering it would be the same lie the layout is told not
    /// to tell: `state.lanes` holds the docked lane at the ordinal it returns
    /// to, and that is not where anything is on screen.
    private func describeStrip() -> String {
        let state = store.state
        guard !state.lanes.isEmpty else { return "(no lanes)\n" }
        var position = 0
        return state.lanes.map { lane in
            let index: String
            switch lane.dock?.side {
            case .left: index = "◀"
            case .right: index = "▶"
            case nil:
                index = String(position)
                position += 1
            }
            let kinds = lane.panes.map { pane -> String in
                switch pane.kind {
                // `pty:yorkshire:0368d543` for a session on a server: the one
                // mark, and what `maxpane attach` takes back.
                case .pty: return pane.sessionKey.map { "pty:\($0)" } ?? "pty"
                case .web: return "web"
                case .placeholder: return "web(evicted)"
                }
            }.joined(separator: ",")
            let focused = lane.panes.contains { $0.id == state.focusedPaneId } ? "*" : " "
            let tag = lane.projectRoot.map { ($0 as NSString).lastPathComponent } ?? "-"
            let title = lane.title ?? lane.panes.first?.url ?? "untitled"
            return "\(focused)\(index)\t\(kinds)\t\(tag)\t\(title)"
        }.joined(separator: "\n") + "\n"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override public func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // The title bar's buttons have real frames only once the window has one.
        updateTitlebarAvoidance()
        // Enter fullscreen after the window exists, so the strip lays out once
        // at its final size rather than twice.
        //
        // MAXPANE_WINDOWED skips it: a fullscreen app that takes the display the
        // moment it launches is not something you want during a smoke test on a
        // machine somebody is using.
        let windowed = ProcessInfo.processInfo.environment["MAXPANE_WINDOWED"] != nil
        if !windowed, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    /// Called on quit, so a web pane's session reaches the ledger before the
    /// process stops existing.
    public func flushPaneState() { strip.flushPaneState() }

    // MARK: - CommandHandling

    public func canPerform(_ command: Command) -> Bool {
        switch command {
        case .ungather:
            return store.isGathered
        case .gather:
            return store.focusedLane?.projectRoot != nil
        case .showHelp:
            return true
        case .showSettings:
            return configStore != nil
        case .claimSession:
            // Only meaningful for a terminal pane.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .pty
        case .savePassword:
            // A page, and not a private one: a private lane fills passwords
            // and never offers to keep one, so the item says so by being grey.
            guard let focused = store.state.focusedPaneId, store.pane(focused)?.kind == .web else { return false }
            return store.lane(containing: focused)?.isPrivate != true
        case _ where command.needsWebPane:
            // The mirror of `claimSession`: only a page has an address, a form
            // or a document to print. Greyed out rather than beeping, because
            // the menu can say which panes it is for and a beep cannot — see
            // `Command.needsWebPane` for the list and the sharper reason the
            // password keys are on it.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .web
        case .pairWithNext:
            return pairCandidates() != nil
        case .splitRight:
            // Any pane. It was terminals only while ⌘D was shared with Keep
            // This Page and exactly one of the two had to be live; now the
            // split owns the key, and a terminal beside a page is as useful as
            // one beside a terminal — it starts in `$HOME`, a page having no
            // cwd to inherit. A lane is needed to put the new one beside.
            return store.focusedLane != nil
        case .closePane, .closeLane, .splitDown, .toggleKeepLive,
             .moveLaneLeft, .moveLaneRight, .widenLane, .narrowLane,
             .dockLaneLeft, .dockLaneRight:
            return store.focusedLane != nil
        case .toggleDockMode:
            // A mode is a property of a dock, and a lane that is not docked has
            // none. Greying it out is how the menu says which of the two
            // questions this key answers.
            return store.focusedLane?.dock != nil
        case .laneSizeSmall, .laneSizeMedium, .laneSizeLarge, .laneSizeCycle:
            // Any lane, docked ones too: a dock takes the preset's width inside
            // its own bounds. Not in the gallery, which writes nothing but the
            // layout and focus.
            return store.focusedLane != nil && !strip.isGallery
        case .toggleMaximizePane:
            // A pane with the keyboard — on the strip, in a dock, in a gallery
            // tile — or one that is already up, which can always come down.
            return strip.canToggleMaximize
        case .toggleMobileLayout:
            // A lane with a page in it. The pages are asked, not the snapshot,
            // for the same reason the lane's menu asks them.
            return store.focusedLane.flatMap { strip.mobileLayout(of: $0) } != nil
        case .toggleBlocking:
            // A lane with a page on a site, and a blocker that is on at all.
            return store.focusedLane.flatMap { strip.blocking(of: $0) } != nil
        case .focusDockLeft:
            return store.dockedLane(.left) != nil
        case .focusDockRight:
            return store.dockedLane(.right) != nil
        default:
            return true
        }
    }

    public func title(for command: Command) -> String {
        if command == .toggleMaximizePane, strip.isPaneMaximized, let active = command.activeTitle {
            return active
        }
        return command.title
    }

    public func perform(_ command: Command) {
        guard canPerform(command) else { return }
        let focusedLane = store.focusedLane

        do {
            switch command {
            case .openAnything:
                showOmniPicker(scope: .everything, near: focusedLane)
            case .openPages:
                showOmniPicker(scope: .pages, near: focusedLane)
            case .openSessions:
                showOmniPicker(scope: .sessions, near: focusedLane)

            case .zoomIn, .zoomOut, .zoomReset:
                strip.zoomFocusedPane(command)

            case .reload, .hardReload:
                strip.reloadFocusedPane(fromOrigin: command == .hardReload)

            case .editAddress:
                strip.editFocusedPaneAddress()

            case .bookmarkPage:
                strip.keepFocusedPage()

            case .fillPassword:
                strip.fillFocusedPagePassword()

            case .savePassword:
                strip.saveFocusedPagePassword()

            case .printPage:
                strip.printFocusedPage()

            case .savePDF:
                strip.saveFocusedPageAsPDF()

            case .newTerminalLane:
                try newTerminal(near: focusedLane)

            case .newPrivateWebLane:
                // A blank page, then the address: the lane exists before it
                // is asked where to go, and the ledger holds `about:blank`
                // for it and nothing else. The edit waits a turn for the
                // strip to build the pane the snapshot just announced.
                try store.newWebLane(url: "about:blank", near: focusedLane?.id, private: true)
                DispatchQueue.main.async { [weak self] in self?.strip.editFocusedPaneAddress() }

            case .showHelp:
                showHelp()

            case .showSettings:
                showSettings()

            case .splitRight:
                // iTerm's ⌘D, in this app's geometry: panes stack down inside a
                // lane, so "to the right" is a new lane rather than a second
                // column inside this one. Same cwd as the pane you are in.
                try newTerminal(near: focusedLane)

            case .splitDown:
                guard let lane = focusedLane, let focused = store.state.focusedPaneId,
                      let pane = store.pane(focused) else { return }
                // "Same kind as focused" (PRD §7.1). A web split needs a URL, so
                // a terminal split is the only one that can happen silently.
                if pane.kind == .pty {
                    // Beside a remote pane, on that pane's server in that
                    // pane's directory — the same rule as ⌘T, one pane down.
                    let place = strip.spawnPlace(ofPane: focused)
                    let size = newSessionSize()
                    try spawner(at: place).spawn(
                        cwd: place.cwd, command: nil, args: [], cols: size.cols, rows: size.rows
                    ) { [weak self] result in
                        guard let self else { return }
                        do {
                            try self.store.addTerminalPane(to: lane.id, session: try result.get().key)
                        } catch {
                            self.showError(error)
                        }
                    }
                } else {
                    // The same picker, pointed at this lane instead of a new
                    // one. Splitting a web pane used to open an `NSAlert` with
                    // a text field in it — a fourth way to say "open a page",
                    // and the only one that could not see your history.
                    showOmniPicker(scope: .pages, into: lane)
                }

            case .closePane:
                if let focused = store.state.focusedPaneId { try store.closePane(focused) }

            case .closeLane:
                if let lane = focusedLane { try store.closeLane(lane.id) }

            case .focusLeft:  strip.moveFocus(.left)
            case .focusRight: strip.moveFocus(.right)
            case .focusUp:    strip.moveFocus(.up)
            case .focusDown:  strip.moveFocus(.down)

            case .moveLaneLeft:
                if let lane = focusedLane { try store.nudgeLane(lane.id, right: false) }
            case .moveLaneRight:
                if let lane = focusedLane { try store.nudgeLane(lane.id, right: true) }

            // ⌃⌘= / ⌃⌘- mean "this column is the wrong width", and a docked
            // lane is still a column. Routing them to the dock's width rather
            // than adding two more keys keeps one thought on one pair of keys —
            // and the lane's own width is deliberately left alone, so it comes
            // back to the strip at the width it was dragged to there.
            case .widenLane:
                if let lane = focusedLane {
                    if let dock = lane.dock {
                        try store.setDockWidth(lane.id, dock.widthPt + 60)
                    } else {
                        try store.setLaneWidth(lane.id, config.clampWidth(lane.widthPt + 60))
                    }
                }
            case .narrowLane:
                if let lane = focusedLane {
                    if let dock = lane.dock {
                        try store.setDockWidth(lane.id, dock.widthPt >= 60 ? dock.widthPt - 60 : 0)
                    } else {
                        try store.setLaneWidth(lane.id, config.clampWidth(lane.widthPt >= 60 ? lane.widthPt - 60 : config.laneMinPt))
                    }
                }

            case .dockLaneLeft:  try toggleDock(.left)
            case .dockLaneRight: try toggleDock(.right)

            case .toggleDockMode:
                if let lane = focusedLane { try store.toggleDockMode(lane.id) }

            case .focusDockLeft:  try focusDock(.left)
            case .focusDockRight: try focusDock(.right)

            case .toggleSidebar:
                let item = split.splitViewItems[0]
                item.animator().isCollapsed.toggle()
                statusBar.setSidebarOpen(!item.isCollapsed)
                // The strip is about to become, or stop being, the leftmost
                // thing. The split view's own notification says so too, but only
                // once the animation has run — and the traffic lights do not
                // animate with it.
                updateTitlebarAvoidance()

            case .search:
                showPalette()

            case .gather:
                if let root = focusedLane?.projectRoot { try store.gather(projectRoot: root) }

            case .ungather:
                try store.ungather()

            case .toggleGallery:
                strip.setLayout(strip.isGallery ? .lanes : .gallery)

            case .toggleKeepLive:
                if let lane = focusedLane { try store.setKeepLive(lane.id, !lane.keepLive) }

            case .peekDesktop:
                // PRD §16's accepted v1 boundary: drop out of fullscreen so the
                // rest of macOS is reachable, and let the user come back.
                window?.toggleFullScreen(nil)

            case .claimSession:
                confirmClaimSession()

            case .showMemory:
                showMemoryDashboard()

            case .pairWithNext:
                try pairFocusedWithNeighbour()

            case .exportStrip:
                exportStrip()

            case .importStrip:
                importStrip()

            case .importBrowserHistory:
                importBrowserHistory()

            case .importBrowserPasswords:
                importBrowserPasswords()

            case .showHistory:
                showHistory()

            case .laneSizeSmall, .laneSizeMedium, .laneSizeLarge:
                let preset: LaneSizePreset = command == .laneSizeSmall ? .s : command == .laneSizeMedium ? .m : .xl
                if let lane = focusedLane { strip.applySizePreset(preset, toLane: lane.id) }

            case .laneSizeCycle:
                if let lane = focusedLane { strip.cycleSizePreset(ofLane: lane.id) }

            case .toggleMaximizePane:
                strip.toggleMaximizeFocusedPane()

            case .toggleMobileLayout:
                if let lane = focusedLane { strip.toggleMobileLayout(ofLane: lane.id) }

            case .toggleBlocking:
                if let lane = focusedLane { strip.toggleBlocking(ofLane: lane.id) }
            }
        } catch {
            showError(error)
        }
    }

    // MARK: - docking

    /// Where focus was before it went into a dock, so the same key can bring it
    /// back.
    ///
    /// In memory, not in the ledger. PRD §5.2 keeps durable state in the core,
    /// and this is not durable state: it is the other half of a keystroke. A
    /// launch that restores focus inside a dock has no "before" to return to,
    /// and the fallback below is the honest answer rather than a remembered one
    /// that would be a guess about a session that has ended.
    private var paneBeforeDock: String?

    /// ⌃⌘[ / ⌃⌘] on the focused lane. The rule itself lives in `StripStore`,
    /// because the ⋯ menu asks the same question about a different lane.
    private func toggleDock(_ side: DockSide) throws {
        guard let lane = store.focusedLane else { return }
        try store.toggleDock(lane.id, side: side)
    }

    /// ⌥⌘[ / ⌥⌘]. Focus that dock, or leave it if focus is already inside.
    ///
    /// The way out matters as much as the way in: ⌘[ / ⌘] skip the docks, so
    /// without this a docked lane is a place the keyboard can reach and never
    /// leave. Same key both ways, so there is nothing extra to learn and
    /// nothing to be stuck in.
    ///
    /// Leaving returns focus to the pane it came from. When that pane is gone —
    /// closed while you were in the dock, or a fresh launch that restored focus
    /// inside it — the fallback is the strip lane focused most recently, which
    /// is the lane you were last working in and therefore almost certainly the
    /// one still on screen. Never the first lane of the strip: on a strip of
    /// forty that is a jump to somewhere the user has not been in an hour.
    private func focusDock(_ side: DockSide) throws {
        guard let dock = store.dockedLane(side), let entry = dock.panes.first else { return }
        let focused = store.state.focusedPaneId

        if let focused, dock.panes.contains(where: { $0.id == focused }) {
            let back = paneBeforeDock.flatMap { store.pane($0) }?.id
                ?? store.stripLanes.max(by: { $0.lastFocusAt < $1.lastFocusAt })?.panes.first?.id
            paneBeforeDock = nil
            if let back { try store.focusPane(back) }
            return
        }

        paneBeforeDock = focused
        try store.focusPane(entry.id)
    }

    // MARK: - helpers

    private func newTerminal(near lane: Lane?) throws {
        // PRD §7.1: the new session starts in the focused pane's cwd — and,
        // beside a remote lane, on that lane's server, because a shell here
        // in a directory that only exists over there is not a sibling of
        // anything.
        let place = store.state.focusedPaneId.map { strip.spawnPlace(ofPane: $0) } ?? .local
        let size = newSessionSize()
        try spawner(at: place).spawn(
            cwd: place.cwd, command: nil, args: [], cols: size.cols, rows: size.rows
        ) { [weak self] result in
            guard let self else { return }
            do {
                try self.store.newTerminalLane(session: try result.get().key, near: lane?.id)
            } catch {
                self.showError(error)
            }
        }
    }

    /// The spawner for `place`, or the one line for a server the file no
    /// longer configures — a lane on such a server is still on the strip
    /// (with its banner), so ⌘T beside it is a real thing to try.
    private func spawner(at place: SpawnPlace) throws -> SessionSpawning {
        guard let spawner = servers.spawner(for: place.server, config: config) else {
            throw ServerNotConfigured(name: place.server ?? "")
        }
        return spawner
    }

    struct ServerNotConfigured: LocalizedError {
        let name: String
        var errorDescription: String? {
            "\(name): not in config.toml — add the server in Settings › Servers, then try again"
        }
    }

    /// Where a ⌘O line runs with nothing else said: the focused lane's
    /// server and directory, or this Mac's home with no lane.
    private var focusedPlace: SpawnPlace {
        store.state.focusedPaneId.map { strip.spawnPlace(ofPane: $0) } ?? .local
    }

    /// ⌘O (and ⌘T, ⌘Y, ⌥⌘O) — the picker, and what to do with what it
    /// hands back.
    ///
    /// `into` is the only thing that differs between the keys, and it is not a
    /// subtle difference: the picker prints where the result will land in the
    /// header above the first row, so there is never a question of which of two
    /// identical-looking windows you are in.
    private func showOmniPicker(scope: OmniScope, near lane: Lane?, prefill: String? = nil, notice: String? = nil) {
        present(scope: scope, destination: "→ new lane", prefill: prefill, notice: notice) { [weak self] action in
            self?.launch(action, near: lane)
        }
    }

    private func showOmniPicker(scope: OmniScope, into lane: Lane) {
        present(scope: scope, destination: "↓ into this lane") { [weak self] action in
            guard let self, case .open(let raw) = action, let url = self.normalizeURL(raw) else {
                // A command or a session would need a second pane kind decision
                // that §7.1's "same kind as focused" has already made.
                return
            }
            try? self.store.addPane(to: lane.id, kind: .web, relaySessionId: nil, url: url)
            self.store.noteRecent(.url, url)
        }
    }

    private func present(
        scope: OmniScope, destination: String, prefill: String? = nil, notice: String? = nil,
        onChoose: @escaping (OmniAction) -> Void
    ) {
        let controller = OmniPicker(
            store: store, registry: sessions, scope: scope, destination: destination,
            place: focusedPlace, servers: servers.names
        ) { action in
            guard let action else { return }
            onChoose(action)
        }
        omni = controller
        controller.present(over: window)
        if let prefill { controller.prefill(prefill) }
        if let notice { controller.showNotice(notice) }
    }

    /// Put a choice on the strip, immediately right of `lane`.
    func launch(_ action: OmniAction, near lane: Lane?) {
        do {
            switch action {
            case .open(let raw):
                guard let url = normalizeURL(raw) else { return }
                try store.newWebLane(url: url, near: lane?.id)
                store.noteRecent(.url, url)

            case .run(let line, let place):
                // Not `line.split(separator: " ")`. ⌘O is handed one line of
                // text, and a whitespace split is a shell imitation that gets
                // pipelines, quoting and globbing wrong without saying so:
                // `yes | head` ran `yes` with the literal arguments `|` and
                // `head`, which is a lane spewing `y` forever rather than an
                // error. `TypedCommand` decides, and says why the CLI's door
                // decides differently.
                guard let typed = TypedCommand.parse(line) else { return }
                // The picker has already decided where (`SpawnPlace.resolve`):
                // a remembered command carries the directory — and the
                // server — it last ran in, which is usually the only place it
                // makes sense; `@name` overrides; the focused lane's place is
                // the fallback.
                let size = newSessionSize()
                try spawner(at: place).spawn(
                    cwd: place.cwd, typed: typed, cols: size.cols, rows: size.rows
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let session):
                        do {
                            try self.store.newTerminalLane(session: session.key, near: lane?.id)
                            let ran = SpawnPlace(server: session.key.server, cwd: session.cwd)
                            self.store.noteRecent(.command, line, cwd: ran.remembered)
                        } catch {
                            self.showError(error)
                        }
                    case .failure(let error):
                        // A remote spawn fails after the picker has gone,
                        // so the picker comes back with the line as typed
                        // and the server's one line under it: nothing to
                        // retype, and the reason where the choice is made.
                        // A local failure is the alert it always was, since
                        // it happened before the picker had finished leaving.
                        if let server = place.server {
                            self.showOmniPicker(
                                scope: .everything, near: lane,
                                prefill: "@\(server) \(line)", notice: Self.describe(error))
                        } else {
                            self.showError(error)
                        }
                    }
                }

            case .attach(let key):
                // PRD §7.1: attaching an existing session creates a lane at the
                // end. Never beside the focused lane — an attach is not a
                // consequence of what you were reading, and the old picker put
                // it at the end for the same reason.
                attach(key)
            }
        } catch {
            showError(error)
        }
    }

    private func showPalette() {
        let controller = SearchPaletteController(store: store, registry: sessions) { [weak self] hit in
            guard let self, let hit else { return }
            // PRD §7.5: focus the pane, centre its lane, flash the border.
            // A lane a folded group or a gather is hiding comes back first.
            self.bringBack(laneId: hit.laneId)
            try? self.store.focusPane(hit.paneId)
            self.strip.reveal(laneId: hit.laneId, flash: true)
        }
        palette = controller
        controller.present(over: window)
    }

    /// The terminal size a *new* session should start at, measured against the
    /// strip's own height. See `TerminalPaneController.newSessionSize`.
    private func newSessionSize() -> (cols: Int, rows: Int) {
        TerminalPaneController.newSessionSize(
            config: config, viewHeight: strip.view.bounds.height)
    }

    private func refreshStatus() {
        stripToolbar.setSessions(sessions.sessions.values.filter(\.isRunning).count)
        statusBar.update(
            state: store.state,
            telemetry: sessions.sessions,
            webBytes: WebProcessMemory.currentBytes(),
            asking: WebAskCenter.shared.count)
    }

    /// A session needs a human — it finished, or it is asking — and the human
    /// may be elsewhere. Bounce the Dock icon once when the app is not in
    /// front; when it is, the sidebar chip is the alert and a bounce would
    /// be noise. `.informationalRequest` bounces once and stops; the
    /// critical kind keeps going until the app is activated.
    private func alert(_ telemetry: SessionTelemetry, became state: AgentState) {
        guard state == .done || state == .blocked, !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Go to the next BLOCKED agent that has a lane, after the one the
    /// keyboard is in. Through `attach`, so a lane a folded sidebar group or
    /// a gather is hiding comes back first: the count in the status bar may
    /// be the only thing on screen that knows it is there.
    private func revealNextBlocked() {
        let blocked = sessions.sessions.values
            .filter { $0.isRunning && $0.needsAttention }
            .map(\.key).sorted()
            .filter { store.lane(holdingSession: $0) != nil }
        guard !blocked.isEmpty else { return }
        let here = store.state.focusedPaneId.flatMap { store.pane($0)?.sessionKey }
        let next = here.flatMap { blocked.firstIndex(of: $0) }.map { blocked[($0 + 1) % blocked.count] }
        attach(next ?? blocked[0])
    }

    /// Tell the registry which sessions have lanes, so the picker can hide them
    /// and the sidebar can mark them.
    private func syncAttachedSessions() {
        sessions.setAttached(attachedSessionIDs())
    }

    /// Every session with a lane, including lanes a gather view is hiding. The
    /// narrowed list offered a gathered-out session to ⌘O as not yet attached.
    private func attachedSessionIDs() -> Set<SessionKey> {
        Set(store.allLanes.flatMap(\.panes).compactMap(\.sessionKey))
    }

    /// Put a Relay session in front of the user — its lane if it has one.
    ///
    /// The sidebar and ⌘O both come through here, and both used to attach
    /// unconditionally on the strength of a lookup a gather filter could fool.
    /// Now a session that already has a lane gets that lane, revealed and
    /// focused, and the core refuses a second one anyway. A session with no lane
    /// leaves any gather first: its new lane has no project tag yet, so the
    /// gather would hide it, and a click that visibly does nothing is the click
    /// that gets repeated.
    private func attach(_ key: SessionKey) {
        if let lane = store.lane(holdingSession: key) {
            bringBack(laneId: lane.id)
            let pane = lane.panes.first { $0.sessionKey == key }
            _ = strip.select(laneId: lane.id, paneId: pane?.id)
            return
        }
        do {
            if store.isGathered { try store.ungather() }
            try store.attachSessionAtEnd(key)
            if let laneId = store.state.lanes.last?.id {
                strip.reveal(laneId: laneId, flash: true)
            }
        } catch {
            showError(error)
        }
    }

    /// Leave a gather view when it is what stands between the user and a lane —
    /// the same way ⌘P already ignores one.
    ///
    /// A lane can be off the strip for a second reason, a folded sidebar
    /// group (ADR-0024), and the answer is the same: whatever is in the way
    /// gets out of it. The group expands, then you are there.
    private func bringBack(laneId: String) {
        store.expandGroups(hiding: laneId)
        guard store.isGathered, store.lane(laneId) == nil,
              store.allLanes.contains(where: { $0.id == laneId })
        else { return }
        try? store.ungather()
    }

    /// What the user typed, as something `WKWebView` will load. Bare hostnames
    /// get a scheme; anything with a space becomes a search.
    private func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            return "https://duckduckgo.com/?q=\(q)"
        }
        return "https://\(trimmed)"
    }

    /// Write the strip somewhere (§13 Phase 3). Useful between machines, and
    /// more useful during the trial as a copy of a layout that took days to
    /// arrange, taken before doing something that might disturb it.
    private func exportStrip() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "strip-\(Self.dateStamp()).json"
        panel.allowedContentTypes = [.json]
        panel.message = "The whole strip: order, widths, titles, tags and URLs."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportStrip().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(error)
        }
    }

    /// Read a strip in, appended to the right-hand end. Appending rather than
    /// replacing because the user can build "replace" out of it, and cannot
    /// build "append" out of "replace".
    private func importStrip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Lanes are added to the right-hand end of the strip."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importStrip(String(contentsOf: url, encoding: .utf8))
            if let last = store.state.lanes.last?.id {
                strip.reveal(laneId: last, flash: true)
            }
        } catch {
            showError(error)
        }
    }

    /// The history-import wizard: which browser, merge or replace, what it
    /// would do, then do it.
    ///
    /// Its own window rather than an `NSOpenPanel` like `importStrip`, because
    /// the file is not the question — the user does not know where Vivaldi keeps
    /// its history and should not have to, and "merge or replace" is a decision
    /// a file chooser has nowhere to put.
    private func importBrowserHistory() {
        // Open, not merely visible: one still fading out is on its way out.
        if let existing = importWizard, existing.isOpen {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wizard = ImportHistoryWizard(store: store)
        importWizard = wizard
        wizard.present(over: window)
    }

    /// ⌃⌥⌘Y — another browser's saved passwords into the macOS Keychain.
    ///
    /// A second window rather than a screen in the history wizard, because the
    /// consent it ends with is macOS's and not ours — see
    /// `ImportPasswordsWizard`.
    private func importBrowserPasswords() {
        // Open, not merely visible: one still fading out is on its way out.
        if let existing = passwordsWizard, existing.isOpen {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wizard = ImportPasswordsWizard(store: store)
        passwordsWizard = wizard
        wizard.present(over: window)
    }

    /// ⇧⌘Y — the record, in a window with room in it.
    ///
    /// A second press raises the one already open rather than stacking another,
    /// which matters more here than for the wizard: this window is meant to be
    /// left open, so the key that opens it is a key someone will press while it
    /// is on screen.
    private func showHistory() {
        // Open, not merely visible: one still fading out is on its way out.
        if let existing = historyWindow, existing.isOpen {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let history = HistoryWindow(store: store) { [weak self] url in
            guard let self else { return }
            self.launch(.open(url), near: self.store.focusedLane)
        }
        historyWindow = history
        history.present(over: window)
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// The focused pane and its right-hand neighbour, when one is a terminal
    /// and the other a web pane. `nil` when there is nothing sensible to pair.
    private func pairCandidates() -> (pty: String, web: String)? {
        let state = store.state
        guard let focused = state.focusedPaneId,
              let index = state.lanes.firstIndex(where: { $0.panes.contains { $0.id == focused } }),
              index + 1 < state.lanes.count,
              let here = store.pane(focused),
              let next = state.lanes[index + 1].panes.first
        else { return nil }

        switch (here.kind, next.kind) {
        case (.pty, .web), (.pty, .placeholder): return (pty: here.id, web: next.id)
        case (.web, .pty), (.placeholder, .pty): return (pty: next.id, web: here.id)
        default: return nil
        }
    }

    /// ⌘⌥P — link a terminal to the web pane beside it, or unlink them if they
    /// are already linked. PRD §7.1's "explicit terminal↔web link (optional)".
    private func pairFocusedWithNeighbour() throws {
        guard let pair = pairCandidates() else { return }
        if store.pairs(of: pair.pty).contains(pair.web) {
            try store.unpair(pty: pair.pty, web: pair.web)
        } else {
            try store.pair(pty: pair.pty, web: pair.web)
        }
    }

    /// ⌘/ — every shortcut, generated from `Command`.
    /// ⌘/ — every shortcut, in the same popup as every other dialog. Pressed
    /// again while it is open, it closes: the key that asked the question can
    /// put the answer away.
    private func showHelp() {
        if let existing = helpPanel, existing.isOpen {
            existing.closePopup()
            return
        }
        let panel = HelpPanel()
        helpPanel = panel
        panel.present(over: window)
    }

    /// ⌘, — every setting and every key, written to `config.toml` as they
    /// change. Pressed again while open, it closes, like ⌘/.
    private func showSettings() {
        if let existing = settingsWindow, existing.isOpen {
            existing.closePopup()
            return
        }
        openSettings()
    }

    /// Settings, scrolled to the Servers section with `server`'s row marked
    /// — from a click on that server's header in the sidebar. Raises the
    /// window already open rather than stacking another.
    private func showSettings(server: String) {
        if let existing = settingsWindow, existing.isOpen {
            existing.reveal(.servers, animated: true)
            existing.mark(server: server)
            return
        }
        let panel = openSettings()
        panel?.reveal(.servers, animated: false)
        panel?.mark(server: server)
    }

    @discardableResult
    private func openSettings() -> SettingsWindow? {
        guard let configStore else { return nil }
        let panel = SettingsWindow(store: configStore, servers: serverBook) { [weak self] file in
            self?.openInEditor(file)
        }
        panel.onRenameServer = { [weak self] old, new in
            do { try self?.store.renameServer(from: old, to: new) } catch {
                Log.warn("server \(old) → \(new): the ledger's panes were not renamed: \(error.localizedDescription)")
            }
        }
        settingsWindow = panel
        panel.present(over: window)
        return panel
    }

    /// A terminal lane running the `editor` setting on `file` — the same line a
    /// ⌘-clicked path gets, from `FileOpen`, read from the file as it is now
    /// rather than as it was at launch.
    private func openInEditor(_ file: URL) {
        let editor = configStore?.config.editor ?? config.editor
        guard case .editor(let line) = FileOpen.plan(for: .file(path: file.path, line: nil, column: nil), editor: editor)
        else { return }
        let size = newSessionSize()
        do {
            let session = try LocalSpawner(config: config)
                .spawn(cwd: file.deletingLastPathComponent().path, shellLine: line, cols: size.cols, rows: size.rows)
            try store.newTerminalLane(relaySessionId: session, near: store.focusedLane?.id)
        } catch {
            ConfirmPopup.inform(
                over: window, title: "Could not open the config file in an editor",
                detail: error.localizedDescription)
        }
    }

    /// PRD §13 Phase 2's memory dashboard. Floating, so it can sit beside the
    /// strip while scrolling changes what it reports.
    private func showMemoryDashboard() {
        if let existing = memoryDashboard {
            existing.orderFront(nil)
            return
        }
        let panel = MemoryDashboard(store: store, config: config)
        memoryDashboard = panel
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 600, y: frame.maxY - 520))
        }
        panel.orderFront(nil)
    }

    /// ADR-0007 §5: the one path that sends `RESIZE`. It reshapes the PTY for
    /// every other attached client — Scott's phone included — so it asks first,
    /// every time, and names who else it affects.
    private func confirmClaimSession() {
        guard let paneId = store.state.focusedPaneId else { return }
        ConfirmPopup.confirm(
            over: window,
            title: "Resize this session to fit the lane?",
            detail: "This changes the terminal's size for everyone attached to it, "
                + "including the Relay web client on your phone, and will redraw "
                + "whatever is running.\n\n"
                + "Max Pane otherwise never resizes a session — it sizes the lane "
                + "to the session instead.",
            action: "Resize Session", returnConfirms: true
        ) { [weak self] resize in
            guard resize else { return }
            self?.strip.claimSession(paneId: paneId)
        }
    }

    private func showError(_ error: Error) {
        ConfirmPopup.inform(over: window, title: "That didn't work", detail: Self.describe(error))
    }

    /// What to show a human, in an alert or down the CLI's stderr.
    ///
    /// Not `"\(error)"`: interpolating an enum reflects it, so every
    /// `errorDescription` written for these — the whole reason they conform to
    /// `LocalizedError` — was being thrown away and `maxpane run` was answering
    /// `binaryNotFound` where a sentence was waiting. Not `localizedDescription`
    /// either, which turns an error that has no message into "The operation
    /// couldn't be completed", burying the case name that at least named it.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

/// Fullscreen is where the traffic lights go away, so it is where the band
/// reserved for them has to go away too — otherwise the fix for a windowed bug
/// becomes a permanent dead stripe across the top of the interface.
///
/// `didEnter`/`didExit` rather than `will`: the style mask that
/// `TitlebarAvoidance.band` reads is only true after the transition, so asking
/// on the way in gets the answer for where the window has just left.
extension StripWindowController: NSWindowDelegate {
    public func windowDidEnterFullScreen(_ notification: Notification) {
        updateTitlebarAvoidance()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        updateTitlebarAvoidance()
    }
}
