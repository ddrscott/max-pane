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
    private var palette: SearchPaletteController?
    /// Held while it is on screen, like `palette` — for the same reason: the
    /// table's data source is weak.
    private var omni: OmniPicker?
    private var openServer: OpenServer?
    private var alternateMonitor: Any?
    private var memoryDashboard: MemoryDashboard?
    private var helpPanel: HelpPanel?
    /// Held only so a second ⌥⌘Y raises the wizard already on screen instead of
    /// stacking another one over it; the wizard keeps itself alive otherwise.
    private var importWizard: ImportHistoryWizard?
    private var passwordsWizard: ImportPasswordsWizard?
    /// Held for the same reason as the wizard, and with more cause: this one is
    /// expected to stay open beside the strip while the reader works.
    private var historyWindow: HistoryWindow?
    private let statusBar = StatusBar()
    private var statusTimer: Timer?
    /// Our subscription to `WebAskCenter`, so the orange count appears the
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
    public let sessions = SessionRegistry()

    public init(store: StripStore, config: Config) {
        self.store = store
        self.config = config
        self.sidebar = SidebarViewController(store: store)
        self.strip = StripViewController(store: store, config: config)

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
        // The strip with a footer under it. A footer rather than a toolbar
        // because the strip is the interface, and chrome across the top would
        // eat the lane headers' room.
        let stripSide = NSViewController()
        stripSide.view = NSView()
        // The strip's own ground, because with the sidebar collapsed this view
        // shows through above the strip as the band the traffic lights sit in.
        // Left unpainted that band is the window's grey, which reads as a title
        // bar — the thing this window does not have.
        stripSide.view.wantsLayer = true
        stripSide.view.layer?.backgroundColor = Theme.stripBackground.cgColor
        strip.view.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        stripSide.addChild(strip)
        stripSide.view.addSubview(strip.view)
        stripSide.view.addSubview(statusBar)
        stripTop = strip.view.topAnchor.constraint(equalTo: stripSide.view.topAnchor)
        NSLayoutConstraint.activate([
            stripTop,
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
            self?.strip.select(laneId: laneId, paneId: paneId)
        }
        sidebar.onNewSession = { [weak self] in self?.perform(.openAnything) }
        sidebar.onAttach = { [weak self] sessionId in
            try? self?.store.attachSessionAtEnd(relaySessionId: sessionId)
        }
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
        let sidebarItem = split.splitViewItems[0]
        let stripStartsAt = sidebarItem.isCollapsed ? 0 : sidebar.view.frame.width

        sidebar.titlebarInset = TitlebarAvoidance.inset(
            band: band, buttonsEndAt: buttonsEnd, contentStartsAt: 0)
        let stripInset = TitlebarAvoidance.inset(
            band: band, buttonsEndAt: buttonsEnd, contentStartsAt: stripStartsAt)
        if stripTop.constant != stripInset { stripTop.constant = stripInset }
    }

    /// Every key the menu cannot carry.
    ///
    /// Two kinds land here. A menu item holds exactly one key equivalent, and
    /// ⌘O, ⌘T and ⌘D are one thought — so the other two are matched here, ahead
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
            // A palette on screen owns the keyboard; ⌘D while typing a command
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

        store.observe { [weak self] _ in
            self?.syncAttachedSessions()
            self?.refreshStatus()
        }
        sessions.observe { [weak self] telemetry in
            guard let self else { return }
            self.strip.sessionsChanged(telemetry)
            self.sidebar.sessionsChanged(telemetry)
            self.refreshStatus()
        }
        statusBar.onClickSessions = { [weak self] in self?.perform(.openSessions) }
        statusBar.onClickMemory = { [weak self] in self?.perform(.showMemory) }
        statusBar.onClickAsking = { [weak self] in self?.strip.revealNextAsking() }
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
        }
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
            let session = try RelaySessionSpawner(config: config).spawn(
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
                case .pty: return pane.relaySessionId.map { "pty:\($0)" } ?? "pty"
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
        case .claimSession:
            // Only meaningful for a terminal pane.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .pty
        case .editAddress, .bookmarkPage, .fillPassword, .savePassword:
            // The mirror of `claimSession`: only a page has an address. Greyed
            // out rather than beeping, because the menu can say which panes it
            // is for and a beep cannot. Fill and save are here for the same
            // reason and a sharper one — there is no form in a terminal, and a
            // key that could put a password somewhere unexpected should be
            // dead everywhere it does not mean anything.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .web
        case .pairWithNext:
            return pairCandidates() != nil
        case .closePane, .closeLane, .splitDown, .toggleKeepLive,
             .moveLaneLeft, .moveLaneRight, .widenLane, .narrowLane, .toggleSpan,
             .dockLaneLeft, .dockLaneRight:
            return store.focusedLane != nil
        case .toggleDockMode:
            // A mode is a property of a dock, and a lane that is not docked has
            // none. Greying it out is how the menu says which of the two
            // questions this key answers.
            return store.focusedLane?.dock != nil
        case .focusDockLeft:
            return store.dockedLane(.left) != nil
        case .focusDockRight:
            return store.dockedLane(.right) != nil
        default:
            return true
        }
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

            case .newTerminalLane:
                try newTerminal(near: focusedLane)

            case .showHelp:
                showHelp()

            case .splitDown:
                guard let lane = focusedLane, let focused = store.state.focusedPaneId,
                      let pane = store.pane(focused) else { return }
                // "Same kind as focused" (PRD §7.1). A web split needs a URL, so
                // a terminal split is the only one that can happen silently.
                if pane.kind == .pty {
                    let cwd = strip.cwd(ofPane: focused) ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let size = newSessionSize()
                    let session = try RelaySessionSpawner(config: config)
                        .spawn(cwd: cwd, cols: size.cols, rows: size.rows)
                    try store.addPane(to: lane.id, kind: .pty, relaySessionId: session, url: nil)
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

            case .toggleSpan:
                // §1's invariant is that a lane is a portrait column; §13 Phase 3
                // allows one deliberate exception at 2×, for content that
                // genuinely cannot be read in portrait.
                if let lane = focusedLane {
                    try store.setLaneSpan(lane.id, lane.span == 1 ? 2 : 1)
                    if lane.span == 1 {
                        // Widening is only useful if the lane actually takes the
                        // room, so give it to the new ceiling.
                        try store.setLaneWidth(lane.id, config.laneMaxPt * 2)
                    }
                }
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
        // PRD §7.1: the new session starts in the focused pane's cwd.
        let cwd = store.state.focusedPaneId.flatMap { strip.cwd(ofPane: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let size = newSessionSize()
        let session = try RelaySessionSpawner(config: config)
            .spawn(cwd: cwd, cols: size.cols, rows: size.rows)
        try store.newTerminalLane(relaySessionId: session, near: lane?.id)
    }

    /// ⌘O (and ⌘T, ⌘D, ⌘Y, ⌥⌘O) — the picker, and what to do with what it
    /// hands back.
    ///
    /// `into` is the only thing that differs between the keys, and it is not a
    /// subtle difference: the picker prints where the result will land in the
    /// header above the first row, so there is never a question of which of two
    /// identical-looking windows you are in.
    private func showOmniPicker(scope: OmniScope, near lane: Lane?) {
        present(scope: scope, destination: "→ new lane") { [weak self] action in
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
        scope: OmniScope, destination: String, onChoose: @escaping (OmniAction) -> Void
    ) {
        let controller = OmniPicker(
            store: store, registry: sessions, scope: scope, destination: destination
        ) { action in
            guard let action else { return }
            onChoose(action)
        }
        omni = controller
        controller.present(over: window)
    }

    /// Put a choice on the strip, immediately right of `lane`.
    func launch(_ action: OmniAction, near lane: Lane?) {
        do {
            switch action {
            case .open(let raw):
                guard let url = normalizeURL(raw) else { return }
                try store.newWebLane(url: url, near: lane?.id)
                store.noteRecent(.url, url)

            case .run(let line, let remembered):
                let parts = line.split(separator: " ").map(String.init)
                guard let program = parts.first else { return }
                // A remembered command carries the directory it last ran in,
                // which is usually the only place it makes sense — `npm test`
                // in the wrong repo is a failure, not a command. It loses to
                // the focused lane only when that directory is gone.
                let cwd = remembered.flatMap { path in
                    FileManager.default.fileExists(atPath: path) ? path : nil
                } ?? store.state.focusedPaneId.flatMap { strip.cwd(ofPane: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                let size = newSessionSize()
                let session = try RelaySessionSpawner(config: config)
                    .spawn(cwd: cwd, command: program, args: Array(parts.dropFirst()),
                           cols: size.cols, rows: size.rows)
                try store.newTerminalLane(relaySessionId: session, near: lane?.id)
                store.noteRecent(.command, line, cwd: cwd)

            case .attach(let sessionId):
                // PRD §7.1: attaching an existing session creates a lane at the
                // end. Never beside the focused lane — an attach is not a
                // consequence of what you were reading, and the old picker put
                // it at the end for the same reason.
                try store.attachSessionAtEnd(relaySessionId: sessionId)
                if let laneId = store.state.lanes.last?.id {
                    strip.reveal(laneId: laneId, flash: true)
                }
            }
        } catch {
            showError(error)
        }
    }

    private func showPalette() {
        let controller = SearchPaletteController(store: store, registry: sessions) { [weak self] hit in
            guard let self, let hit else { return }
            // PRD §7.5: focus the pane, centre its lane, flash the border.
            try? self.store.focusPane(hit.paneId)
            self.strip.reveal(laneId: hit.laneId, flash: true)
        }
        palette = controller
        controller.present(over: window)
    }

    /// The terminal size a *new* session should start at.
    ///
    /// ADR-0007 says Max Pane never resizes a session, because the PTY's size is
    /// shared by every client including Scott's phone. It says nothing about the
    /// size a session is *born* at — at that instant we are the only client, and
    /// choosing it is not taking it from anyone.
    ///
    /// Getting this wrong is very visible: a session born at 80×40 in a lane
    /// that can show 60 rows leaves a third of the column black forever, and
    /// ADR-0007 then forbids us from fixing it.
    private func newSessionSize() -> (cols: Int, rows: Int) {
        let font = NSFont(name: config.fontName, size: config.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)

        // Match SwiftTerm's own cell metric rather than approximating it.
        // `AppleTerminalView.computeFontDimensions` uses
        // `ceil(ascent + descent + leading)`; `boundingRectForFont.height` is
        // several points taller, and guessing high leaves a band of dead black
        // at the bottom of every terminal lane that ADR-0007 then forbids
        // fixing.
        let ctFont = font as CTFont
        let cellHeight = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        let advance = Double(font.advancement(forGlyph: font.glyph(withName: "space") ?? 0).width)
        let cellWidth = advance > 0 ? advance.rounded() : config.fontSize * 0.6

        let laneWidth = Double(config.laneDefaultPt) - 16
        let usableHeight = Double(strip.view.bounds.height) - Double(Theme.laneHeaderHeight)

        let cols = max(40, Int(laneWidth / max(cellWidth, 1)))
        // Fall back to something sane before the strip has been laid out.
        let rows = usableHeight > 100 ? max(20, Int(usableHeight / max(cellHeight, 1))) : 40
        return (cols, rows)
    }

    private func refreshStatus() {
        statusBar.update(
            state: store.state,
            telemetry: sessions.sessions,
            webBytes: WebProcessMemory.currentBytes(),
            asking: WebAskCenter.shared.count)
    }

    /// Tell the registry which sessions have lanes, so the picker can hide them
    /// and the sidebar can mark them.
    private func syncAttachedSessions() {
        sessions.setAttached(attachedSessionIDs())
    }

    private func attachedSessionIDs() -> Set<String> {
        Set(store.state.lanes.flatMap(\.panes).compactMap(\.relaySessionId))
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
        if let existing = importWizard, existing.window?.isVisible == true {
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
        if let existing = passwordsWizard, existing.window?.isVisible == true {
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
        if let existing = historyWindow, existing.window?.isVisible == true {
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
    private func showHelp() {
        if let existing = helpPanel {
            existing.orderFront(nil)
            return
        }
        let panel = HelpPanel()
        helpPanel = panel
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 280, y: frame.midY - 260))
        }
        panel.orderFront(nil)
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
        let alert = NSAlert()
        alert.messageText = "Resize this session to fit the lane?"
        alert.informativeText =
            "This changes the terminal's size for everyone attached to it, "
            + "including the Relay web client on your phone, and will redraw "
            + "whatever is running.\n\n"
            + "Max Pane otherwise never resizes a session — it sizes the lane "
            + "to the session instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Resize Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        strip.claimSession(paneId: paneId)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "That didn't work"
        alert.informativeText = Self.describe(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
