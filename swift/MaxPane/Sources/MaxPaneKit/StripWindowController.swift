import AppKit
import LanedCore

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
    private var openServer: OpenServer?
    private var sessionWatcher: RelaySessionWatcher?

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
        window.title = "Max Pane"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The strip is the interface; the menu bar is an interruption.
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        super.init(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: strip))
        window.contentViewController = split

        sidebar.onSelect = { [weak self] laneId in self?.strip.reveal(laneId: laneId, flash: true) }
        startSideChannels()
    }

    /// The two things that talk to the world outside the window: the shim's
    /// socket, and RelayTTY's session directory.
    private func startSideChannels() {
        // Snapshots outlive the panes that made them when the app is killed;
        // sweep the ones with no pane before anything can read a stale path.
        SnapshotStore.sweep(keeping: Set(store.state.lanes.flatMap(\.panes).map(\.id)))

        do {
            openServer = try OpenServer { [weak self] request in
                MainActor.assumeIsolated { self?.handleOpen(request) ?? false }
            }
        } catch {
            // Not fatal. Without it, URLs from terminals go to the default
            // browser — the same thing that happens when the app is not running.
            FileHandle.standardError.write(Data("maxpane: open socket unavailable: \(error)\n".utf8))
        }

        sessionWatcher = RelaySessionWatcher(pollInterval: config.sessionPollSeconds) { [weak self] sessions in
            MainActor.assumeIsolated { self?.strip.sessionsChanged(sessions) }
        }
    }

    /// A URL arrived from `maxpane-open` (PRD §7.1).
    ///
    /// The web lane goes immediately right of the terminal that asked, tagged
    /// with that terminal's project. A URL from somewhere that is not a lane —
    /// a plain shell, a cron job — goes to the end of the strip rather than
    /// being refused.
    private func handleOpen(_ request: OpenServer.Request) -> Bool {
        let near = request.sessionId.isEmpty ? nil : strip.lane(forRelaySession: request.sessionId)
        do {
            try store.newWebLane(url: request.url, near: near)
            if let laneId = store.state.lanes.last?.id, near == nil {
                strip.reveal(laneId: laneId, flash: true)
            }
            return true
        } catch {
            return false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override public func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
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

    // MARK: - CommandHandling

    public func canPerform(_ command: Command) -> Bool {
        switch command {
        case .ungather:
            return store.isGathered
        case .gather:
            return store.focusedLane?.projectRoot != nil
        case .claimSession:
            // Only meaningful for a terminal pane.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .pty
        case .closePane, .closeLane, .splitDown, .togglePinned,
             .moveLaneLeft, .moveLaneRight, .widenLane, .narrowLane:
            return store.focusedLane != nil
        default:
            return true
        }
    }

    public func perform(_ command: Command) {
        guard canPerform(command) else { return }
        let focusedLane = store.focusedLane

        do {
            switch command {
            case .newTerminalLane:
                try newTerminal(near: focusedLane)

            case .newWebLane:
                promptForURL { [weak self] url in
                    guard let self, let url else { return }
                    try? self.store.newWebLane(url: url, near: focusedLane?.id)
                }

            case .splitDown:
                guard let lane = focusedLane, let focused = store.state.focusedPaneId,
                      let pane = store.pane(focused) else { return }
                // "Same kind as focused" (PRD §7.1). A web split needs a URL, so
                // a terminal split is the only one that can happen silently.
                if pane.kind == .pty {
                    let cwd = strip.cwd(ofPane: focused) ?? FileManager.default.homeDirectoryForCurrentUser.path
                    let session = try RelaySessionSpawner(config: config).spawn(cwd: cwd)
                    try store.addPane(to: lane.id, kind: .pty, relaySessionId: session, url: nil)
                } else {
                    promptForURL { [weak self] url in
                        guard let self, let url else { return }
                        try? self.store.addPane(to: lane.id, kind: .web, relaySessionId: nil, url: url)
                    }
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

            case .widenLane:
                if let lane = focusedLane {
                    try store.setLaneWidth(lane.id, config.clampWidth(lane.widthPt + 60))
                }
            case .narrowLane:
                if let lane = focusedLane {
                    try store.setLaneWidth(lane.id, config.clampWidth(lane.widthPt >= 60 ? lane.widthPt - 60 : config.laneMinPt))
                }

            case .toggleSidebar:
                split.splitViewItems[0].animator().isCollapsed.toggle()

            case .search:
                showPalette()

            case .gather:
                if let root = focusedLane?.projectRoot { try store.gather(projectRoot: root) }

            case .ungather:
                try store.ungather()

            case .attachSession:
                showSessionPicker()

            case .togglePinned:
                if let lane = focusedLane { try store.setPinned(lane.id, !lane.pinned) }

            case .peekDesktop:
                // PRD §16's accepted v1 boundary: drop out of fullscreen so the
                // rest of macOS is reachable, and let the user come back.
                window?.toggleFullScreen(nil)

            case .claimSession:
                confirmClaimSession()
            }
        } catch {
            showError(error)
        }
    }

    // MARK: - helpers

    private func newTerminal(near lane: Lane?) throws {
        // PRD §7.1: the new session starts in the focused pane's cwd.
        let cwd = store.state.focusedPaneId.flatMap { strip.cwd(ofPane: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let session = try RelaySessionSpawner(config: config).spawn(cwd: cwd)
        try store.newTerminalLane(relaySessionId: session, near: lane?.id)
    }

    private func showPalette() {
        let controller = SearchPaletteController(store: store) { [weak self] hit in
            guard let self, let hit else { return }
            // PRD §7.5: focus the pane, centre its lane, flash the border.
            try? self.store.focusPane(hit.paneId)
            self.strip.reveal(laneId: hit.laneId, flash: true)
        }
        palette = controller
        controller.present(over: window)
    }

    private func showSessionPicker() {
        let sessions = RelaySessionDirectory().attachable(excluding: attachedSessionIDs())
        let controller = SessionPickerController(sessions: sessions) { [weak self] session in
            guard let self, let session else { return }
            // PRD §7.1: attaching an existing session creates a lane at the end.
            try? self.store.attachSessionAtEnd(relaySessionId: session.id)
        }
        palette = nil
        controller.present(over: window)
    }

    private func attachedSessionIDs() -> Set<String> {
        Set(store.state.lanes.flatMap(\.panes).compactMap(\.relaySessionId))
    }

    private func promptForURL(_ completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return completion(nil) }
        completion(normalizeURL(field.stringValue))
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
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
