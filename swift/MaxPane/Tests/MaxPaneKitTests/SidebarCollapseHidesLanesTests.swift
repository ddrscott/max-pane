import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

// serial pass: real surfaces and strip motion, settled against the wall clock.
// The whole suite runs in `scripts/test.sh`'s second, --no-parallel pass; see
// README, "The serial pass".

// Collapsing a sidebar group hides its lanes (ADR-0024). Three layers, three
// suites: which lanes a set of folds covers (pure), what the store does with
// that against a real ledger (hide, persist, hand focus on, reach through),
// and what the strip does with a lane that is hidden rather than closed.

private let home = NSHomeDirectory()

private func telemetry(
    _ id: String, server: String? = nil, cwd: String, state: AgentState = .idle
) -> SessionTelemetry {
    SessionTelemetry(
        sessionId: id, server: server, title: id, cwd: cwd, command: "claude", state: state,
        bytesPerSecond: 0, lastActivity: Date(timeIntervalSince1970: 0))
}

private func pane(_ id: String, lane: String, session: String? = nil, server: String? = nil, url: String? = nil) -> Pane {
    Pane(id: id, laneId: lane, position: 0, kind: session == nil ? .web : .pty,
         relaySessionId: session, relayServer: server, url: url, scrollY: nil, dataStoreId: nil,
         snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)
}

private func lane(_ id: String, tag: String? = nil, panes: [Pane]) -> Lane {
    Lane(id: id, ordinal: 1, widthPt: 500, title: nil, projectRoot: tag, projectSource: .cwd,
         createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1, isPrivate: false, panes: panes)
}

// MARK: - the model

@Suite("which lanes a folded sidebar group hides")
struct CollapseHidesLanesModelTests {
    private let sessions: [SessionKey: SessionTelemetry] = [
        "max": telemetry("max", cwd: home + "/code/max-pane/swift"),
        "life": telemetry("life", cwd: home + "/life"),
        // The two panes of one split lane, in two projects.
        "mx1": telemetry("mx1", cwd: home + "/code/max-pane/swift"),
        "mx2": telemetry("mx2", cwd: home + "/life"),
        SessionKey(server: "wsl", id: "r1"): telemetry("r1", server: "wsl", cwd: "/home/spierce/m7out"),
        SessionKey(server: "wsl", id: "r2"): telemetry("r2", server: "wsl", cwd: "/home/spierce"),
    ]

    private var lanes: [Lane] {
        [
            // Tagged with the git root, filed in the sidebar under the cwd.
            lane("L-max", tag: home + "/code/max-pane", panes: [pane("p1", lane: "L-max", session: "max")]),
            lane("L-life", tag: home + "/life", panes: [pane("p2", lane: "L-life", session: "life")]),
            lane("L-docs", tag: home + "/life", panes: [pane("p3", lane: "L-docs", url: "https://docs")]),
            lane("L-loose", panes: [pane("p4", lane: "L-loose", url: "https://news")]),
            lane("L-r1", tag: "wsl:/home/spierce/m7out", panes: [pane("p5", lane: "L-r1", session: "r1", server: "wsl")]),
            lane("L-r2", tag: "wsl:/home/spierce", panes: [pane("p6", lane: "L-r2", session: "r2", server: "wsl")]),
            lane("L-mixed", tag: home + "/life", panes: [
                pane("p7", lane: "L-mixed", session: "mx1"), pane("p8", lane: "L-mixed", session: "mx2"),
            ]),
        ]
    }

    private func hidden(_ collapsed: Set<String>, hasServers: Bool = true) -> Set<String> {
        SidebarModel.hiddenLanes(lanes: lanes, telemetry: sessions, collapsed: collapsed, hasServers: hasServers)
    }

    @Test("a lane files where its rows are: under its session's directory, and under its tag only when no session is known")
    func groupsOfALane() {
        #expect(SidebarModel.groups(of: lanes[0], telemetry: sessions) == ["~/code/max-pane/swift"])
        #expect(SidebarModel.groups(of: lanes[0], telemetry: [:]) == ["~/code/max-pane"])
        #expect(SidebarModel.groups(of: lanes[2], telemetry: sessions) == ["~/life"], "a web lane, through its tag")
        #expect(SidebarModel.groups(of: lanes[3], telemetry: sessions) == [SidebarModel.looseWebGroup])
        #expect(SidebarModel.groups(of: lanes[4], telemetry: sessions) == ["wsl:/home/spierce/m7out"])
        #expect(SidebarModel.groups(of: lanes[6], telemetry: sessions) == ["~/code/max-pane/swift", "~/life"])
    }

    @Test("a folded directory takes its terminals and the web lanes tagged with it, and nothing else")
    func aDirectory() {
        #expect(hidden(["~/life"]) == ["L-life", "L-docs"])
        #expect(hidden(["~/code/max-pane/swift"]) == ["L-max"])
        // The tag is not the group: folding the git root folds nothing here.
        #expect(hidden(["~/code/max-pane"]).isEmpty)
        #expect(hidden([]).isEmpty)
    }

    @Test("a mixed lane goes only when every group it is in is folded")
    func mixed() {
        #expect(!hidden(["~/life"]).contains("L-mixed"))
        #expect(!hidden(["~/code/max-pane/swift"]).contains("L-mixed"))
        #expect(hidden(["~/life", "~/code/max-pane/swift"]).contains("L-mixed"))
        // A section's fold counts for each group under it.
        #expect(hidden([SidebarModel.localSection]).contains("L-mixed"))
    }

    @Test("an untagged web lane is never hidden: not by Web, not by // LOCAL, not by everything at once")
    func untagged() {
        #expect(!hidden([SidebarModel.looseWebGroup]).contains("L-loose"))
        #expect(!hidden([SidebarModel.localSection]).contains("L-loose"))
        let everything: Set<String> = [
            SidebarModel.looseWebGroup, SidebarModel.localSection, "wsl:", "~/life", "~/code/max-pane/swift",
        ]
        #expect(hidden(everything) == ["L-max", "L-life", "L-docs", "L-r1", "L-r2", "L-mixed"])
    }

    @Test("a server's project folds its own lanes; the server's section folds all of them")
    func servers() {
        #expect(hidden(["wsl:/home/spierce/m7out"]) == ["L-r1"])
        #expect(hidden(["wsl:"]) == ["L-r1", "L-r2"])
        #expect(hidden([SidebarModel.localSection]) == ["L-max", "L-life", "L-docs", "L-mixed"])
    }

    @Test("a remote lane nobody has heard from yet files under its tag, which is host:path too")
    func remoteBeforeTheServerAnswers() {
        let quiet = SidebarModel.hiddenLanes(
            lanes: lanes, telemetry: [:], collapsed: ["wsl:/home/spierce/m7out"], hasServers: true)
        #expect(quiet == ["L-r1"])
    }

    @Test("// LOCAL folds nothing once there is no server: there is no header left to open it by")
    func localWithoutServers() {
        #expect(hidden([SidebarModel.localSection], hasServers: false).isEmpty)
        #expect(hidden([SidebarModel.localSection, "~/life"], hasServers: false) == ["L-life", "L-docs"])
    }

    @Test("reaching a lane opens every fold over it: its group's and its section's")
    func keysToExpand() {
        let collapsed: Set<String> = ["wsl:", "wsl:/home/spierce/m7out", "~/life"]
        #expect(SidebarModel.keysToExpand(toShow: lanes[4], telemetry: sessions, collapsed: collapsed)
            == ["wsl:", "wsl:/home/spierce/m7out"])
        #expect(SidebarModel.keysToExpand(toShow: lanes[1], telemetry: sessions, collapsed: collapsed) == ["~/life"])
        #expect(SidebarModel.keysToExpand(toShow: lanes[0], telemetry: sessions, collapsed: collapsed).isEmpty)
    }

    // MARK: the rows

    private func groups(_ rows: [SidebarModel.Row]) -> [SidebarModel.Group] {
        rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    @Test("a folded header says how many lanes it is holding, and BLOCKED beside it")
    func headerCounts() {
        var t = sessions
        t["life"] = telemetry("life", cwd: home + "/life", state: .blocked)
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let rows = SidebarModel.rows(
            lanes: lanes, telemetry: t, controls: controls, servers: ["wsl": .connected],
            hiddenLanes: ["L-life", "L-docs"])
        let life = groups(rows).first { $0.path == "~/life" }!
        #expect(life.hiddenLanes == 2)
        #expect(life.countText == "2 LANES HIDDEN")
        #expect(life.blockedText == "1 BLOCKED")
        // An open group says what it always said.
        let max = groups(rows).first { $0.path == "~/code/max-pane/swift" }!
        #expect(max.hiddenLanes == 0 && max.blockedText == nil && max.countText == "2 RUNNING")
    }

    @Test("the setting off: a folded header hides no lanes, and still rolls up what is under it")
    func settingOffHeader() {
        var t = sessions
        t["life"] = telemetry("life", cwd: home + "/life", state: .blocked)
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        // Off, nothing is hidden, so nothing is handed in.
        let rows = SidebarModel.rows(lanes: lanes, telemetry: t, controls: controls)
        let life = groups(rows).first { $0.path == "~/life" }!
        #expect(life.hiddenLanes == 0)
        #expect(life.blockedText == "1 BLOCKED" && life.countText == "3 RUNNING", "life, the mixed lane, and the web lane")
        #expect(life.rollUpText == "1 BLOCKED · 3 RUNNING")
    }

    @Test("a folded section keeps its header and drops every project under it; Web is under no section and stays")
    func foldedSection() {
        var controls = SidebarModel.Controls()
        controls.collapsed = ["wsl:", SidebarModel.localSection]
        let rows = SidebarModel.rows(
            lanes: lanes, telemetry: sessions, controls: controls, servers: ["wsl": .connected],
            hiddenLanes: ["L-max", "L-life", "L-docs", "L-mixed", "L-r1", "L-r2"])
        #expect(groups(rows).map(\.path) == [SidebarModel.localSection, SidebarModel.looseWebGroup, "wsl:"])
        let local = groups(rows)[0], wsl = groups(rows)[2]
        #expect(local.collapsed && local.countText == "4 LANES HIDDEN")
        #expect(wsl.collapsed && wsl.countText == "2 LANES HIDDEN")
        #expect(rows.count == 4, "three headers and the one loose web row")
    }

    @Test("a split lane is one lane, however many rows it has under the header")
    func countsLanesNotRows() {
        var t = sessions
        t["s1"] = telemetry("s1", cwd: home + "/life")
        t["s2"] = telemetry("s2", cwd: home + "/life")
        let split = lane("L-split", tag: home + "/life", panes: [
            pane("p9", lane: "L-split", session: "s1"), pane("p10", lane: "L-split", session: "s2"),
        ])
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life", "~/code/max-pane/swift"]
        let rows = SidebarModel.rows(
            lanes: [split, lanes[6]], telemetry: t, controls: controls, hiddenLanes: ["L-split", "L-mixed"])
        let life = groups(rows).first { $0.path == "~/life" }!
        #expect(life.total == 4, "s1, s2, mx2 and the unattached `life`")
        #expect(life.countText == "2 LANES HIDDEN", "the split lane once, and the mixed one")
        #expect(groups(rows).first { $0.path == "~/code/max-pane/swift" }?.countText == "1 LANE HIDDEN")
    }
}

// MARK: - the store, on a real ledger

@MainActor
private final class HidingRig {
    let dir: URL
    var store: StripStore
    var inputs = StripStore.HidingInputs()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-hiding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        wire()
    }

    private func wire() {
        store.hidingInputs = { [unowned self] in self.inputs }
        store.refreshHidden()
    }

    /// Drop the store with no shutdown path and open the file again.
    func relaunch() throws {
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        wire()
    }

    /// A terminal lane on `session`, whose directory is `cwd`.
    @discardableResult
    func terminal(_ session: String, cwd: String, state: AgentState = .idle) throws -> String {
        inputs.telemetry[SessionKey(id: session)] = telemetry(session, cwd: cwd, state: state)
        try store.attachSessionAtEnd(relaySessionId: session)
        return store.lane(holdingSession: SessionKey(id: session))!.id
    }

    @discardableResult
    func web(_ url: String, tag: String?) throws -> String {
        try store.newWebLane(url: url, near: nil)
        let id = store.allLanes.last!.id
        if let tag { try store.setManualTag(id, tag) }
        return id
    }

    func pane(of laneId: String) -> String { store.allLanes.first { $0.id == laneId }!.panes[0].id }
    var shown: [String] { store.state.lanes.map(\.id) }
    var focusedLane: String? {
        store.state.focusedPaneId.flatMap { id in store.allLanes.first { $0.panes.contains { $0.id == id } }?.id }
    }

    func tearDown() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("folding a sidebar group, against a real ledger")
@MainActor
struct CollapseHidesLanesStoreTests {
    private func rig(_ body: (HidingRig) throws -> Void) throws {
        let rig = try HidingRig()
        defer { rig.tearDown() }
        try body(rig)
    }

    @Test("folding hides, opening brings back: same order, same widths, and the ledger never changed")
    func hideAndReturn() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/two")
            let c = try r.web("https://two.test", tag: home + "/code/two")
            let d = try r.terminal("d", cwd: home + "/code/one")
            try r.store.setLaneWidth(b, 720)
            _ = try r.store.focusPane(r.pane(of: a))
            let ledger = r.store.allLanes

            r.store.setCollapsedGroups(["~/code/two"])
            #expect(r.shown == [a, d])
            #expect(r.store.state.hiddenLaneIds == [b, c])
            #expect(r.store.hiddenLanes.map(\.id) == [b, c])
            #expect(r.store.allLanes == ledger, "nothing about a lane was written")
            #expect(r.store.lane(holdingSession: "b") != nil, "still attached, so a click reveals rather than attaches again")

            r.store.setCollapsedGroups([])
            #expect(r.shown == [a, b, c, d])
            #expect(r.store.state.lanes == ledger)
        }
    }

    @Test("a relaunch comes back with the same groups folded and the same lanes hidden, in the first snapshot")
    func persisted() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/two")
            _ = try r.store.focusPane(r.pane(of: a))
            r.store.setCollapsedGroups(["~/code/two", "wsl:"])

            let reopened = try StripStore(ledgerPath: r.dir.appendingPathComponent("ledger.db").path)
            #expect(reopened.state.lanes.map(\.id) == [a], "before anything is wired: the ledger's own first snapshot")
            #expect(reopened.state.hiddenLaneIds == [b])
            #expect(reopened.collapsedGroups == ["~/code/two", "wsl:"])

            try r.relaunch()
            #expect(r.shown == [a])
            r.store.setCollapsedGroups(["wsl:"])
            #expect(r.shown == [a, b])
        }
    }

    @Test("the setting off is today's behaviour exactly, and it applies live in both directions")
    func settingOff() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/two")
            r.inputs.enabled = false
            r.store.setCollapsedGroups(["~/code/two"])
            #expect(r.shown == [a, b])
            #expect(r.store.state.hiddenLaneIds.isEmpty)
            #expect(r.store.collapsedGroups == ["~/code/two"], "the rows still fold")

            r.inputs.enabled = true
            _ = try r.store.focusPane(r.pane(of: a))
            r.store.refreshHidden()
            #expect(r.shown == [a])

            r.inputs.enabled = false
            r.store.refreshHidden()
            #expect(r.shown == [a, b])
            // And a relaunch with it off does not keep what the ledger remembered.
            r.inputs.enabled = true
            r.store.refreshHidden()
            r.inputs.enabled = false
            try r.relaunch()
            #expect(r.shown == [a, b])
        }
    }

    @Test("focus goes to the nearest lane still there, right first, then left — the rule closing a lane follows")
    func focusHandOff() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/two")
            let c = try r.terminal("c", cwd: home + "/code/two")
            let d = try r.terminal("d", cwd: home + "/code/three")
            _ = try r.store.focusPane(r.pane(of: b))
            r.store.setCollapsedGroups(["~/code/two"])
            #expect(r.focusedLane == d, "c is going too, so d is the nearest to the right")

            r.store.setCollapsedGroups(["~/code/two", "~/code/three"])
            #expect(r.focusedLane == a, "nothing to the right: left")
            #expect(r.shown == [a])
        }
    }

    @Test("everything folded: the keyboard has nowhere to go, and the next recount does not reopen what was just folded")
    func everythingFolded() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            r.store.setCollapsedGroups(["~/code/one"])
            #expect(r.shown.isEmpty)
            r.store.refreshHidden()
            r.store.refreshHidden()
            #expect(r.shown.isEmpty && r.store.collapsedGroups == ["~/code/one"])
            #expect(r.store.state.hiddenLaneIds == [a])
        }
    }

    @Test("reach-through: a sidebar row, ⌘P's focus, and an attach each open the group, and then the lane is there")
    func reachThrough() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/two")
            _ = try r.store.focusPane(r.pane(of: a))

            // The door the sidebar, `maxpane attach` and a BLOCKED click share.
            r.inputs.hasServers = true
            r.store.setCollapsedGroups(["~/code/two", SidebarModel.localSection])
            #expect(r.shown.isEmpty && r.store.state.hiddenLaneIds == [a, b])
            r.store.expandGroups(hiding: b)
            #expect(r.store.lane(b) != nil)
            #expect(r.store.collapsedGroups.isEmpty, "its group's fold and its section's")

            // ⌘P focuses the pane it found. Focus landing in a folded group opens it.
            r.store.setCollapsedGroups(["~/code/two"])
            #expect(r.store.lane(b) == nil)
            _ = try r.store.focusPane(r.pane(of: b))
            #expect(r.store.lane(b) != nil && r.store.collapsedGroups.isEmpty)

            // A session with no lane, in a folded group, attached from ⌘O or the CLI.
            _ = try r.store.focusPane(r.pane(of: a))
            r.store.setCollapsedGroups(["~/code/two"])
            let c = try r.terminal("c", cwd: home + "/code/two")
            #expect(r.store.lane(c) != nil, "the lane it asked for is on the strip")
            #expect(r.store.lane(b) != nil && r.store.collapsedGroups.isEmpty, "because the group opened")
        }
    }

    @Test("a recount hides a lane whose session moved into a folded group — unless it is the lane you are typing in, and then the group opens")
    func recount() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let b = try r.terminal("b", cwd: home + "/code/one")
            let z = try r.terminal("z", cwd: home + "/code/two")
            _ = try r.store.focusPane(r.pane(of: a))
            r.store.setCollapsedGroups(["~/code/two"])
            #expect(r.shown == [a, b] && r.store.state.hiddenLaneIds == [z])

            // b's agent did `cd ~/code/two`. Nobody is in b.
            r.inputs.telemetry["b"] = telemetry("b", cwd: home + "/code/two")
            r.store.refreshHidden()
            #expect(r.shown == [a])
            #expect(r.focusedLane == a, "a recount never moves the keyboard")

            // a does the same, with the keyboard in it.
            r.inputs.telemetry["a"] = telemetry("a", cwd: home + "/code/two")
            r.store.refreshHidden()
            #expect(r.shown == [a, b, z])
            #expect(r.store.collapsedGroups.isEmpty)
        }
    }

    @Test("a docked lane in a folded group stays at its wall, and is not counted as hidden")
    func docked() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            let music = try r.web("https://music.test", tag: home + "/code/two")
            let b = try r.terminal("b", cwd: home + "/code/two")
            try r.store.dockLane(music, side: .left, mode: .overlay)
            _ = try r.store.focusPane(r.pane(of: a))
            r.store.setCollapsedGroups(["~/code/two"])
            #expect(Set(r.shown) == [a, music])
            #expect(r.store.state.hiddenLaneIds == [b])
        }
    }

    @Test("the status bar says how many lanes are hidden, and nothing when none are")
    func statusBar() throws {
        try rig { r in
            let a = try r.terminal("a", cwd: home + "/code/one")
            try r.terminal("b", cwd: home + "/code/two")
            try r.web("https://two.test", tag: home + "/code/two")
            _ = try r.store.focusPane(r.pane(of: a))
            let bar = StatusBar()
            bar.update(state: r.store.state, telemetry: r.inputs.telemetry, webBytes: 0)
            #expect(bar.lanesText == "3 lanes")
            r.store.setCollapsedGroups(["~/code/two"])
            bar.update(state: r.store.state, telemetry: r.inputs.telemetry, webBytes: 0)
            #expect(bar.lanesText == "1 lane · 2 hidden")
        }
    }

    @Test("the header as drawn: lanes hidden at rest, BLOCKED beside it and breathing; a section has a triangle")
    func headerView() {
        var group = SidebarModel.Group(
            path: "~/code/two", running: 2, blocked: 1, total: 2, collapsed: true,
            countOverride: nil, serverState: nil, hiddenLanes: 3)
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: 300, height: 26), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BlockedPulse.isReduced = { false }
        defer { BlockedPulse.isReduced = { Motion.isReduced } }
        let view = SidebarGroupView(group: group)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        window.contentView?.addSubview(view)
        #expect(view.countText == "3 LANES HIDDEN")
        #expect(view.blockedText == "1 BLOCKED")
        #expect(view.isBlockedPulsing)

        group.blocked = 0
        let calm = SidebarGroupView(group: group)
        #expect(calm.blockedText.isEmpty && !calm.isBlockedPulsing)

        let section = SidebarGroupView(group: SidebarModel.Group(
            path: "wsl:", running: 1, blocked: 0, total: 1, collapsed: true,
            countOverride: nil, serverState: .connected, hiddenLanes: 1))
        #expect(section.hasTriangle && section.countText == "1 LANE HIDDEN")
    }

    @Test("an empty strip that is empty because everything was folded says so")
    func emptyState() {
        let view = EmptyStripView()
        #expect(!view.bodyText.contains("collapsed"))
        view.hiddenLanes = 4
        #expect(view.bodyText.contains("4 lanes are in collapsed sidebar groups"))
    }
}

// MARK: - the strip

@Suite("a hidden lane on the strip")
@MainActor
struct CollapseHidesLanesStripTests {
    final class CountingPane: PaneController {
        let paneId: String
        let view = NSView()
        var tornDown = 0
        init(_ pane: Pane) { paneId = pane.id }
        func apply(_ pane: Pane) {}
        func takeFocus() {}
        func tearDown() { tornDown += 1 }
        func unparent() {}
        func reparentIfNeeded() {}
        func evict() {}
        func rehydrate() {}
    }

    @Test("its pane is never torn down, its view leaves the window, and the same pane is back when the group opens")
    func controllersSurvive() async throws {
        let rig = try HidingRig()
        defer { rig.tearDown() }
        let a = try rig.web("about:blank", tag: home + "/code/one")
        let b = try rig.web("about:blank", tag: home + "/code/two")
        _ = try rig.store.focusPane(rig.pane(of: a))

        var panes: [String: CountingPane] = [:]
        let strip = StripViewController(store: rig.store, config: Config())
        strip.controllerFactory = { pane, _ in
            let made = CountingPane(pane)
            panes[pane.id] = made
            return made
        }
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        strip.view.frame = window.contentView!.bounds
        window.contentView?.addSubview(strip.view)
        defer { strip.view.removeFromSuperview() }
        func settle(_ seconds: Double = 0.5) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        await settle()
        let hiddenPane = try #require(panes[rig.pane(of: b)])
        #expect(hiddenPane.view.window != nil)

        rig.store.setCollapsedGroups(["~/code/two"])
        await settle(0.6)
        #expect(hiddenPane.tornDown == 0, "hidden is not closed")
        #expect(hiddenPane.view.window == nil, "and it is not on the strip")

        rig.store.setCollapsedGroups([])
        await settle(0.6)
        #expect(panes[rig.pane(of: b)] === hiddenPane, "the same pane, not one rebuilt")
        #expect(hiddenPane.view.window != nil && hiddenPane.tornDown == 0)

        // Closed is still closed.
        try rig.store.closeLane(b)
        await settle(0.6)
        #expect(hiddenPane.tornDown == 1)
    }

    @Test("the lane held still is the focused one when it is on screen and staying, else the first that is")
    func anchorPick() {
        let lanes = ["a", "b", "c", "d"].map { lane($0, panes: [pane("p" + $0, lane: $0, url: "x")]) }
        let step = 500 + Theme.borderWidth
        // Scrolled so b and c are on screen; a (left of the window) is going.
        let after = [lanes[1], lanes[2], lanes[3]]
        let focused = StripAnchor.pick(before: lanes, after: after, focusedLaneId: "c", offset: step, width: 2 * step)
        #expect(focused == StripAnchor(laneId: "c", x: step))
        let first = StripAnchor.pick(before: lanes, after: after, focusedLaneId: "a", offset: step, width: 2 * step)
        #expect(first == StripAnchor(laneId: "b", x: 0))
        // Nothing on screen survives: nothing to hold, focus moving is the answer.
        #expect(StripAnchor.pick(before: lanes, after: [lanes[3]], focusedLaneId: "b", offset: 0, width: step) == nil)
    }

    @Test("where the held lane starts follows the columns closing to its left, slot by slot")
    func anchorOrigin() {
        let lanes = ["a", "b", "c"].map { lane($0, panes: [pane("p" + $0, lane: $0, url: "x")]) }
        let b = Theme.borderWidth
        #expect(StripAnchor.origin(of: "c", in: lanes, slots: [:]) == 2 * (500 + b))
        #expect(StripAnchor.origin(of: "c", in: lanes, slots: ["a": 125]) == 125 + b + 500 + b)
        #expect(StripAnchor.origin(of: "c", in: lanes, slots: ["a": 0, "b": 0]) == 2 * b)
        #expect(StripAnchor.origin(of: "z", in: lanes, slots: [:]) == nil)
    }
}

// MARK: - render sheet

@Suite("collapse hides lanes rendering")
@MainActor
struct CollapseHidesLanesRenderTests {
    @Test("renders the sidebar with folded groups and sections holding lanes, calm and BLOCKED, and the status bar beside it")
    func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        func t(_ id: String, _ server: String?, _ cwd: String, _ state: AgentState, _ title: String) -> SessionTelemetry {
            var t = SessionTelemetry(
                sessionId: id, server: server, title: title, cwd: cwd, command: "claude", state: state,
                bytesPerSecond: state == .working ? 1740 : 0, lastActivity: Date().addingTimeInterval(-40))
            t.connection = server == nil ? nil : .connected
            return t
        }
        let sessions: [SessionKey: SessionTelemetry] = [
            "m1": t("m1", nil, home + "/code/max-pane", .working, "◐ Editing SidebarModel.swift"),
            "m2": t("m2", nil, home + "/code/max-pane", .idle, "✳ Review ADR-0024"),
            "l1": t("l1", nil, home + "/life", .blocked, "Waiting on permission"),
            "l2": t("l2", nil, home + "/life", .idle, "✳ Inbox sweep"),
            "t1": t("t1", nil, home + "/code/trifecta", .idle, "bash"),
            SessionKey(server: "WSL", id: "r1"): t("r1", "WSL", "/home/spierce/m7out", .blocked, "Waiting on permission"),
            SessionKey(server: "WSL", id: "r2"): t("r2", "WSL", "/home/spierce", .working, "◑ Refactoring the tunnel client"),
        ]
        let everyLane: [Lane] = sessions.keys.sorted().map { key in
            lane("L-" + key.id, panes: [pane("p-" + key.id, lane: "L-" + key.id, session: key.id, server: key.server)])
        }
        let cases: [(String, Set<String>, [String: ServerState])] = [
            ("open", [], ["WSL": .connected]),
            ("groups", ["~/life", "~/code/trifecta"], ["WSL": .connected]),
            ("server", ["~/life", "WSL:"], ["WSL": .connected]),
            ("all-sections", [SidebarModel.localSection, "WSL:"], ["WSL": .connected]),
            ("no-servers", ["~/life"], [:]),
        ]
        for (name, collapsed, servers) in cases {
            let telemetry = servers.isEmpty ? sessions.filter { $0.key.server == nil } : sessions
            let lanes = servers.isEmpty ? everyLane.filter { $0.panes[0].relayServer == nil } : everyLane
            let hidden = SidebarModel.hiddenLanes(
                lanes: lanes, telemetry: telemetry, collapsed: collapsed, hasServers: !servers.isEmpty)
            var controls = SidebarModel.Controls()
            controls.collapsed = collapsed
            let rows = SidebarModel.rows(
                lanes: lanes, telemetry: telemetry, controls: controls, servers: servers, hiddenLanes: hidden)
            let heights = rows.map { row -> CGFloat in
                if case .group = row { return SidebarGroupView.height }
                return SidebarEntryView.height
            }
            for width in [260.0, 320.0] as [CGFloat] {
                try AppearanceSheet.render(to: dir, named: "collapse-sidebar-\(name)-\(Int(width))") {
                    let barHeight = StatusBar.height
                    let sheet = NSView(frame: NSRect(
                        x: 0, y: 0, width: width + 420, height: heights.reduce(0, +) + 8 + barHeight))
                    sheet.wantsLayer = true
                    sheet.layerBackgroundColor = Theme.stripBackground
                    var y = sheet.bounds.height - 4
                    for (row, height) in zip(rows, heights) {
                        let view: NSView
                        switch row {
                        case .group(let g): view = SidebarGroupView(group: g)
                        case .entry(let e): view = SidebarEntryView(entry: e)
                        case .bookmark: continue
                        }
                        y -= height
                        view.frame = NSRect(x: 0, y: y, width: width, height: height)
                        sheet.addSubview(view)
                        view.layoutSubtreeIfNeeded()
                    }
                    let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: width + 420, height: barHeight))
                    let shown = lanes.filter { !hidden.contains($0.id) }
                    bar.update(
                        state: StripState(
                            lanes: shown, scrollX: 0, focusedPaneId: nil, gatherFilter: nil,
                            hiddenLaneIds: hidden.sorted(), revision: 1),
                        telemetry: telemetry, webBytes: 0)
                    sheet.addSubview(bar)
                    bar.layoutSubtreeIfNeeded()
                    return sheet
                }
            }
        }
    }
}
