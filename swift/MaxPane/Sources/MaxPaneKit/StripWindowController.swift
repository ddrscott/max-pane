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
    private var openServer: OpenServer?
    private var memoryDashboard: MemoryDashboard?
    private var helpPanel: HelpPanel?
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

        // Setting `contentViewController` makes AppKit resize the window to the
        // content's *fitting* size. An empty strip has no intrinsic width, so
        // that collapses the window to the sidebar's minimum thickness — a
        // 228×50 sliver. Restore a real size and floor it, after the assignment.
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.minSize = NSSize(width: 720, height: 400)
        window.center()

        sidebar.registry = sessions
        sidebar.onSelect = { [weak self] laneId in self?.strip.reveal(laneId: laneId, flash: true) }
        sidebar.onNewSession = { [weak self] in self?.perform(.runCommand) }
        sidebar.onAttach = { [weak self] sessionId in
            try? self?.store.attachSessionAtEnd(relaySessionId: sessionId)
        }
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
                MainActor.assumeIsolated {
                    self?.handle(request) ?? .refused("max pane is shutting down")
                }
            }
        } catch {
            // Not fatal. Without it, URLs from terminals go to the default
            // browser — the same thing that happens when the app is not running.
            FileHandle.standardError.write(Data("maxpane: open socket unavailable: \(error)\n".utf8))
        }

        store.observe { [weak self] _ in self?.syncAttachedSessions() }
        sessions.observe { [weak self] telemetry in
            guard let self else { return }
            self.strip.sessionsChanged(telemetry)
            self.sidebar.sessionsChanged(telemetry)
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
    private func openFromCLI(url: String, sessionId: String) -> OpenServer.Reply {
        let near = sessionId.isEmpty ? nil : strip.lane(forRelaySession: sessionId)
        do {
            try store.newWebLane(url: url, near: near)
            if let laneId = store.state.lanes.last?.id, near == nil {
                strip.reveal(laneId: laneId, flash: true)
            }
            return .handled
        } catch {
            return .refused("\(error)")
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
            let session = try RelaySessionSpawner(config: config).spawn(
                cwd: workingDirectory,
                command: command.isEmpty ? nil : command,
                args: args)
            try store.newTerminalLane(relaySessionId: session, near: near)
            if let laneId = store.state.lanes.last?.id {
                strip.reveal(laneId: laneId, flash: true)
            }
            return OpenServer.Reply(ok: true, session: session)
        } catch {
            return .refused("\(error)")
        }
    }

    /// One line per lane, tab-separated, so `maxpane ls` pipes.
    private func describeStrip() -> String {
        let state = store.state
        guard !state.lanes.isEmpty else { return "(no lanes)\n" }
        return state.lanes.enumerated().map { index, lane in
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
        case .runCommand, .showHelp:
            return true
        case .claimSession:
            // Only meaningful for a terminal pane.
            return store.state.focusedPaneId.flatMap { store.pane($0) }?.kind == .pty
        case .pairWithNext:
            return pairCandidates() != nil
        case .closePane, .closeLane, .splitDown, .togglePinned,
             .moveLaneLeft, .moveLaneRight, .widenLane, .narrowLane, .toggleSpan:
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

            case .runCommand:
                promptForCommand { [weak self] line in
                    guard let self, let line, !line.isEmpty else { return }
                    // Split on whitespace the way a shell would for the simple
                    // case; anything quoted goes through $SHELL -c anyway.
                    let parts = line.split(separator: " ").map(String.init)
                    _ = self.runFromCLI(
                        command: parts[0], args: Array(parts.dropFirst()),
                        sessionId: "", cwd: "")
                }

            case .showHelp:
                showHelp()

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

            case .showMemory:
                showMemoryDashboard()

            case .pairWithNext:
                try pairFocusedWithNeighbour()

            case .exportStrip:
                exportStrip()

            case .importStrip:
                importStrip()

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

    /// Tell the registry which sessions have lanes, so the picker can hide them
    /// and the sidebar can mark them.
    private func syncAttachedSessions() {
        sessions.setAttached(attachedSessionIDs())
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

    /// ⌘R — what to run in a new terminal lane.
    private func promptForCommand(_ completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Run a command"
        alert.informativeText = "Starts a Relay session in a new lane. Empty runs your shell."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "htop"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return completion(nil) }
        completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
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
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
