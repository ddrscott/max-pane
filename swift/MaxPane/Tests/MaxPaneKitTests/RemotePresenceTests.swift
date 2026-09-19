import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit
@testable import RelayClient

// Remote presence (ADR-0023): a dead server shows at once, everywhere, and a
// remote session is recognisably remote. The fake servers are the ones the
// remote relay suites already use: `FakeRelayServer` (HTTP + /ws/events) and
// `FakeRelayWS` (a session socket).

@MainActor private func spin(_ seconds: TimeInterval = 5, until cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return cond()
}

// MARK: - the source and the registry: one truth per server

@Suite("a server that goes quiet, against a fake relay server", .serialized)
@MainActor
struct ServerGoesQuietTests {
    /// The shipped numbers divided by ten: 0.5 s poll, 0.4 s request
    /// timeout, 0.5 s ping, 0.4 s pong. The window is poll + two timeouts + the retry's beat.
    private func source(_ server: FakeRelayServer, poll: TimeInterval = 0.5, unreachableAfter: TimeInterval = 60) -> RemoteSessionSource {
        RemoteSessionSource(
            name: "wsl", endpoint: RelayServer(baseURL: server.baseURL, token: "t0k3n", placement: .cookie),
            pollInterval: poll, requestTimeout: 0.4, pingInterval: 0.5, pongTimeout: 0.4,
            unreachableAfter: unreachableAfter)
    }
    private let window: TimeInterval = 0.5 + 0.4 + 0.05 + 0.4
    private let key = SessionKey(server: "wsl", id: "a1")

    @Test("accepts TCP and never replies: the source flips inside the window, its sessions go offline in the same turn, and recovery restores both")
    func silentDeath() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("a1", agentState: "blocked")]
        let registry = SessionRegistry(sources: [source(server)])
        defer { registry.stop() }
        // What the lanes are told, and what the registry held at that moment.
        var told: [(ServerState, offline: Bool?, shown: AgentState?)] = []
        registry.onServerStateChange = { _, state in
            told.append((state, registry.sessions[self.key]?.isOffline, registry.sessions[self.key]?.state))
        }
        #expect(await spin { registry.serverStates["wsl"] == .connected && registry.sessions[key] != nil })
        #expect(registry.sessions[key]?.state == .blocked)
        #expect(registry.blockedCount == 1)

        server.silent = true
        let died = Date()
        #expect(await spin(window + 4) { registry.serverStates["wsl"] == .reconnecting }, "never noticed")
        let took = Date().timeIntervalSince(died)
        // Alone this lands inside the window (1.3 s, printed below). In the
        // whole run a hundred suites share the main actor these timers fire
        // on, so the bound is the window three times over — still a third of
        // what the old 15 s timeout would be at this scale — and the shipped
        // numbers are timed for real in `LivePresenceTests`.
        #expect(took <= window * 3, "took \(took) s; the window is \(window) s")
        print("presence: fake silent death noticed in \(String(format: "%.2f", took)) s (window \(window) s)")

        // Same turn: the callback that tells the lanes saw the session offline.
        let last = try #require(told.last)
        #expect(last.0 == .reconnecting && last.offline == true && last.shown == .unknown)
        // The session is still there; nothing it last said is repeated.
        let t = try #require(registry.sessions[key])
        #expect(t.isOffline && t.state == .unknown && t.badgeText == "offline" && !t.needsAttention)
        #expect(t.relayState == .blocked, "the last reading is kept, not shown")
        #expect(registry.blockedCount == 0, "a BLOCKED from a dead server is not counted")
        #expect(registry.offlineCount == 1)
        #expect(registry.serverErrors["wsl"]?.hasPrefix("unreachable — 127.0.0.1") == true)

        server.silent = false
        let back = Date()
        #expect(await spin(3) { registry.serverStates["wsl"] == .connected })
        print("presence: fake recovery in \(String(format: "%.2f", Date().timeIntervalSince(back))) s")
        #expect(registry.sessions[key]?.isOffline == false)
        #expect(registry.sessions[key]?.state == .blocked, "the state is back from a fresh list")
        #expect(registry.blockedCount == 1)
        #expect(registry.serverErrors["wsl"] == nil)
        #expect(told.map(\.0) == [.connected, .reconnecting, .connected])
    }

    @Test("one slow response is a retry, not a verdict: the state never leaves connected")
    func slowOnce() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("a1")]
        let remote = source(server)
        let registry = SessionRegistry(sources: [remote])
        defer { registry.stop() }
        var states: [ServerState] = []
        registry.onServerStateChange = { _, state in states.append(state) }
        #expect(await spin { registry.serverStates["wsl"] == .connected })
        let before = remote.fetches
        server.listDelays = [1.0]                 // past the 0.4 s timeout, once
        try await Task.sleep(for: .seconds(2))
        #expect(remote.fetches >= before + 2, "the timed-out request was not retried")
        #expect(states == [.connected], "flapped: \(states)")
        #expect(registry.sessions[key]?.isOffline == false)
    }

    @Test("a lane losing its wire makes the source check now rather than at its next poll")
    func laneLostWire() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("a1")]
        // A poll so long it never comes, and no ping to help.
        let remote = RemoteSessionSource(
            name: "wsl", endpoint: RelayServer(baseURL: server.baseURL, token: "t0k3n", placement: .cookie),
            pollInterval: 60, requestTimeout: 0.4, pingInterval: 60, pongTimeout: 0.4)
        let registry = SessionRegistry(sources: [remote])
        defer { registry.stop() }
        #expect(await spin { registry.serverStates["wsl"] == .connected })
        server.silent = true
        try await Task.sleep(for: .seconds(0.5))
        #expect(registry.serverStates["wsl"] == .connected, "nothing has asked yet")
        registry.laneLostWire(server: "wsl")
        #expect(await spin(2) { registry.serverStates["wsl"] == .reconnecting })
        #expect(registry.sessions[key]?.isOffline == true)
        registry.laneLostWire(server: nil)        // a local lane: nothing to ask
    }

    @Test("a missed pong on /ws/events is a reason to check now, with a poll that never comes")
    func missedPong() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("a1")]
        let remote = RemoteSessionSource(
            name: "wsl", endpoint: RelayServer(baseURL: server.baseURL, token: "t0k3n", placement: .cookie),
            pollInterval: 60, requestTimeout: 0.4, pingInterval: 0.3, pongTimeout: 0.3)
        let registry = SessionRegistry(sources: [remote])
        defer { registry.stop() }
        #expect(await spin { registry.serverStates["wsl"] == .connected && server.eventClients == 1 })
        // Pongs arrive while the server is well: no churn, no flip.
        try await Task.sleep(for: .seconds(1))
        #expect(registry.serverStates["wsl"] == .connected)
        let settled = remote.fetches
        server.silent = true
        #expect(await spin(3) { registry.serverStates["wsl"] == .reconnecting })
        #expect(remote.fetches > settled)
    }

    @Test("reconnecting becomes UNREACHABLE once it has gone on past the limit, and both are off")
    func unreachable() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        let registry = SessionRegistry(sources: [source(server, unreachableAfter: 0.8)])
        defer { registry.stop() }
        #expect(await spin { registry.serverStates["wsl"] == .connected })
        server.silent = true
        #expect(await spin(3) { registry.serverStates["wsl"] == .reconnecting })
        #expect(await spin(4) { registry.serverStates["wsl"] == .unreachable })
        #expect(ServerState.unreachable.label == "UNREACHABLE" && ServerState.unreachable.isOff)
        #expect(ServerState.reconnecting.isOff && ServerState.refused.isOff && !ServerState.connected.isOff)
        server.silent = false
        #expect(await spin(3) { registry.serverStates["wsl"] == .connected })
    }

    @Test("an agent that finished during the outage is DONE when the server comes back")
    func doneAcrossAnOutage() {
        final class Fake: SessionSource {
            let server: String? = "wsl"
            var onChange: (([RelaySessionInfo]) -> Void)?
            var onStateChange: ((ServerState) -> Void)?
            var state: ServerState = .connected
            func start() {}; func stop() {}; func refresh() {}
        }
        func info(_ agentState: String) -> RelaySessionInfo {
            let row = FakeRelayServer.session("a1", agentState: agentState)
            return try! JSONDecoder().decode(RelaySessionInfo.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let fake = Fake()
        let registry = SessionRegistry(sources: [fake])
        var shown: [AgentState] = []
        registry.onStateChange = { _, _, to in shown.append(to) }
        fake.onChange?([info("working")])
        fake.state = .reconnecting; fake.onStateChange?(.reconnecting)
        #expect(registry.sessions[key]?.state == .unknown)
        // The list before the state, as the source does it.
        fake.onChange?([info("idle")])
        fake.state = .connected; fake.onStateChange?(.connected)
        #expect(registry.sessions[key]?.state == .done)
        #expect(shown == [.unknown, .done], "a stale WORKING was shown on the way back: \(shown)")
    }
}

// MARK: - the lane's wire hears the server's verdict

@Suite("a lane's attachment and its server's state", .serialized)
@MainActor
struct AdapterServerStateTests {
    private func sync(_ offset: Double) -> [UInt8] {
        var out = [WSMsg.sync]
        let raw = offset.bitPattern
        for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((raw >> UInt64(s)) & 0xff)) }
        return out
    }

    private func attached(_ server: FakeRelayWS) async -> (RelayAttachmentAdapter, () -> [Bool], () -> Int) {
        let target = RelayServer(baseURL: server.baseURL, token: "t")
        let adapter = RelayAttachmentAdapter(sessionId: "0368d543", server: "wsl") { queue in
            WebSocketTransport(server: target, sessionId: "0368d543", queue: queue, pingInterval: 30, zombieAfter: 45)
        }
        adapter.pongDeadline = 0.3
        var changes: [Bool] = []
        var lost = 0
        adapter.onConnectionChange = { changes.append($0) }
        adapter.onWireLost = { lost += 1 }
        adapter.connect()
        _ = await spin { server.clientCount == 1 && !server.received.isEmpty }
        server.sendBinary(encodeResize(cols: 80, rows: 24))
        server.sendBinary(sync(100))
        _ = await spin { changes == [true] }
        return (adapter, { changes }, { lost })
    }

    @Test("the server goes quiet and the wire is half-open: the lane says so in the pong deadline, not in 45 s, and tells the source")
    func deadWire() async throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let (adapter, changes, lost) = await attached(server)
        defer { adapter.disconnect() }
        #expect(changes() == [true])
        server.answersPings = false
        let asked = Date()
        adapter.serverStateChanged(.reconnecting)
        #expect(await spin(3) { changes() == [true, false] })
        #expect(Date().timeIntervalSince(asked) < 1.5)
        #expect(lost() == 1, "the source was not told to check now")
    }

    @Test("the list is down but the wire answers: the session is left alone")
    func liveWire() async throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let (adapter, changes, lost) = await attached(server)
        defer { adapter.disconnect() }
        adapter.serverStateChanged(.reconnecting)
        try await Task.sleep(for: .seconds(0.8))
        #expect(changes() == [true] && lost() == 0)
        #expect(server.clientCount == 1)
    }

    @Test("input typed while the wire is down and then too old is dropped, and said")
    func droppedInputIsSaid() {
        let adapter = RelayAttachmentAdapter(sessionId: "x")
        var dropped: [Int] = []
        adapter.onInputDropped = { dropped.append($0) }
        // Over the buffer's limit with no wire: dropped at once, and reported.
        adapter.send([UInt8](repeating: 0x61, count: PendingInput.limit + 1)[...])
        #expect(dropped == [PendingInput.limit + 1])
        #expect(ReconnectingBanner.inputNotSent == "INPUT IS NOT BEING SENT")
    }
}

// MARK: - the sidebar, the header, the status bar

@Suite("what a disconnected server looks like")
@MainActor
struct DisconnectedLookTests {
    private func t(_ id: String, _ server: String?, _ cwd: String, _ state: AgentState,
                   connection: ServerState? = nil) -> SessionTelemetry {
        var t = SessionTelemetry(
            sessionId: id, server: server, title: "session \(id)", cwd: cwd, command: "claude", state: state,
            bytesPerSecond: 900, lastActivity: Date().addingTimeInterval(-30))
        t.connection = connection
        return t
    }

    private static func store() throws -> StripStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
    }

    private func remoteLane(root: String = "wsl:/home/spierce") -> Lane {
        Lane(id: "L", ordinal: 1, widthPt: 500, title: "Latest commit", projectRoot: root,
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1,
             isPrivate: false,
             panes: [Pane(id: "P", laneId: "L", position: 0, kind: .pty, relaySessionId: "a1", relayServer: "wsl",
                          url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
                          heightWeight: 1, zoom: 1, mobile: false)])
    }

    @Test("rows under a disconnected server carry offline and no stale state, and are not counted BLOCKED; the header carries the chip")
    func sidebarRows() throws {
        let telemetry: [SessionKey: SessionTelemetry] = [
            SessionKey(server: "wsl", id: "a1"): t("a1", "wsl", "/home/spierce", .blocked, connection: .reconnecting),
            SessionKey(server: "wsl", id: "a2"): t("a2", "wsl", "/home/spierce", .working, connection: .reconnecting),
            "b1": t("b1", nil, NSHomeDirectory() + "/code", .blocked),
        ]
        let rows = SidebarModel.rows(
            lanes: [], telemetry: telemetry, servers: ["wsl": .reconnecting],
            serverErrors: ["wsl": "unreachable — yourslug.relaytty.com: The request timed out."])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        let entries = rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }

        let header = try #require(groups.first { $0.isServer })
        #expect(header.header == "WSL")
        #expect(header.stateChip == "RECONNECTING")
        #expect(header.countText == "2 SESSIONS", "the dead server's BLOCKED is not the header's alarm")
        #expect(header.blocked == 0)
        #expect(header.serverError?.contains("timed out") == true)
        let project = try #require(groups.first { $0.path == "wsl:/home/spierce" })
        #expect(project.header == "/home/spierce")
        #expect(project.countText == "2 OFFLINE")

        for e in entries where e.server == "wsl" {
            #expect(e.offline)
            #expect(e.state == .unknown && e.chip.isEmpty && e.glyph == "—")
            #expect(e.badge == "offline" && !e.badgeIsThroughput && !e.needsAttention)
        }
        let local = try #require(entries.first { $0.server == nil })
        #expect(!local.offline && local.chip == "BLOCKED")
        #expect(SidebarModel.blockedCount(telemetry) == 1, "only the local one")

        // The view: the server's square is there, hollow, and the badge says
        // OFFLINE. The row does not name its server; `// WSL` above it does
        // (ADR-0025).
        let view = SidebarEntryView(entry: try #require(entries.first { $0.server == "wsl" }))
        #expect(view.badgeText == "OFFLINE")
        #expect(view.serverChipText == nil)
        #expect(view.serverMarkServer == "wsl" && view.serverMarkIsHollow == true)
        #expect(!view.isBlockedMarkPulsing)
        let headerView = SidebarGroupView(group: header)
        #expect(headerView.stateChipText == "RECONNECTING")
        #expect(headerView.labelText == "// WSL")
        #expect(headerView.toolTip?.contains("timed out") == true, "the last error is the tooltip")

        // Coming back is a change worth the fade; an age tick is not.
        let healthy = SidebarModel.rows(
            lanes: [], telemetry: telemetry.mapValues { var t = $0; t.connection = $0.server == nil ? nil : .connected; return t },
            servers: ["wsl": .connected])
        #expect(SidebarModel.statusChanged(from: rows, to: healthy))
        #expect(!SidebarModel.statusChanged(from: rows, to: rows))
    }

    @Test("a remote lane whose server was already gone at launch is offline, not EXITED, in the sidebar and in its header")
    func goneAtLaunch() throws {
        let lane = remoteLane()
        let rows = SidebarModel.rows(lanes: [lane], telemetry: [:], servers: ["wsl": .unreachable])
        let entry = try #require(rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }.first)
        #expect(entry.offline && entry.badge == "offline" && entry.chip.isEmpty && entry.state == .unknown)
        let header = try #require(rows.compactMap { if case .group(let g) = $0, g.isServer { return g } else { return nil } }.first)
        #expect(header.stateChip == "UNREACHABLE")

        let model = LaneHeaderModel(lane: lane, telemetry: nil, serverState: .unreachable)
        #expect(model.serverOff == .unreachable && model.state == nil && !model.isLive)
        // With the server answering, the same lane is what it always was: gone.
        #expect(LaneHeaderModel(lane: lane, telemetry: nil, serverState: .connected).state == .exited)
    }

    @Test("the lane header shows the server's state where a state chip goes, and goes hollow")
    func laneHeader() {
        let lane = remoteLane()
        let header = LaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: 620, height: Theme.laneHeaderHeight)
        header.apply(lane)
        header.telemetry = t("a1", "wsl", "/home/spierce/proj", .blocked, connection: .connected)
        header.layout()
        #expect(header.chipText == "BLOCKED" && !header.isServerOff)

        header.telemetry = t("a1", "wsl", "/home/spierce/proj", .blocked, connection: .reconnecting)
        header.layout()
        #expect(header.isServerOff)
        #expect(header.chipText == "RECONNECTING")
        #expect(!header.isBlockedMarkPulsing, "a stale BLOCKED kept breathing")

        header.telemetry = t("a1", "wsl", "/home/spierce/proj", .blocked, connection: .refused)
        header.layout()
        #expect(header.chipText == "TOKEN REFUSED")

        // Too narrow for the word: a glyph, as every other state does.
        header.frame.size.width = 250
        header.layout()
        #expect(header.chipText == ServerState.refused.glyph)
    }

    @Test("a gallery tile of a lane on a dead server dims; the same lane on the strip does not")
    func galleryTile() throws {
        let store = try Self.store()
        try store.attachSessionAtEnd(SessionKey(server: "wsl", id: "a1"))
        let lane = try #require(store.allLanes.first)
        let view = LaneView(lane: lane, widthBounds: 240...1800)
        let key = SessionKey(server: "wsl", id: "a1")
        let off = [key: t("a1", "wsl", "/home/spierce", .idle, connection: .reconnecting)]
        view.applyTelemetry(off, servers: ["wsl": .reconnecting])
        #expect(view.isOffline)
        #expect(view.paneAlphaTarget == 1, "the strip keeps the scrollback readable")
        view.thumbnailScale = 0.4
        #expect(view.paneAlphaTarget == LaneView.offlineAlpha)
        view.applyTelemetry([key: t("a1", "wsl", "/home/spierce", .idle, connection: .connected)], servers: ["wsl": .connected])
        #expect(!view.isOffline && view.paneAlphaTarget == 1)
        // No telemetry at all and the server off: still offline.
        view.applyTelemetry([:], servers: ["wsl": .unreachable])
        #expect(view.isOffline)
    }

    @Test("the status bar counts the offline sessions as offline and never as BLOCKED or working")
    func statusBar() throws {
        let store = try Self.store()
        let bar = StatusBar()
        let telemetry: [SessionKey: SessionTelemetry] = [
            SessionKey(server: "wsl", id: "a1"): t("a1", "wsl", "/home/spierce", .blocked, connection: .reconnecting),
            SessionKey(server: "wsl", id: "a2"): t("a2", "wsl", "/home/spierce", .working, connection: .reconnecting),
            "b1": t("b1", nil, "/x", .idle),
        ]
        bar.update(state: store.state, telemetry: telemetry, webBytes: 0)
        #expect(bar.sessionsText == "3 sessions · 2 offline")
        #expect(bar.attentionText == "" && !bar.isAttentionPulsing)
        let healthy = telemetry.mapValues { var t = $0; if t.server != nil { t.connection = .connected }; return t }
        bar.update(state: store.state, telemetry: healthy, webBytes: 0)
        #expect(bar.sessionsText == "3 sessions")
        #expect(bar.attentionText == "1 BLOCKED")
    }
}

// MARK: - the server chip

@Suite("the server chip")
@MainActor
struct ServerChipTests {
    private func t(_ id: String, _ server: String?, _ cwd: String) -> SessionTelemetry {
        var t = SessionTelemetry(sessionId: id, server: server, title: "bash", cwd: cwd, command: "bash", state: .idle,
                                 lastActivity: Date())
        t.connection = server == nil ? nil : .connected
        return t
    }

    @Test("a name past ten characters is cut with an ellipsis; the tooltip is the URL's host")
    func text() {
        #expect(ServerChip.text(for: "WSL") == "WSL")
        #expect(ServerChip.text(for: "yorkshire1") == "yorkshire1")
        #expect(ServerChip.text(for: "yorkshire-miniforum") == "yorkshire…")
        _ = RelayServers(entries: [RelayServerEntry(name: "WSL", url: "https://yourslug.relaytty.com", enabled: true)], token: { _ in nil })
        let chip = ServerChip(server: "WSL")
        #expect(chip.text == "WSL" && !chip.isHidden && chip.fittingWidth > 0)
        #expect(chip.toolTip == "WSL — yourslug.relaytty.com")
        chip.server = nil
        #expect(chip.isHidden && chip.fittingWidth == 0)
        _ = RelayServers(entries: [], token: { _ in nil })
    }

    @Test("the name is on a remote ⌘O row and ⌘P rows; a sidebar row carries the square and no name; local ones neither")
    func whereItIs() throws {
        let remote = t("a1", "WSL", "/home/spierce")
        let local = t("b1", nil, NSHomeDirectory() + "/code")
        let rows = SidebarModel.rows(
            lanes: [], telemetry: [remote.key: remote, local.key: local], servers: ["WSL": .connected])
        let entries = rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
        let remoteRow = SidebarEntryView(entry: try #require(entries.first { $0.server == "WSL" }))
        #expect(remoteRow.serverChipText == nil && remoteRow.serverMarkServer == "WSL")
        let localRow = SidebarEntryView(entry: try #require(entries.first { $0.server == nil }))
        #expect(localRow.serverChipText == nil && localRow.serverMarkServer == nil)

        // ⌘O: the session row and the launch row.
        let omni = OmniRanking.build(
            query: "", scope: .sessions, recents: [], pages: [], bookmarks: [], sessions: [remote, local], destination: "")
        for c in omni.compactMap(\.candidate) {
            let row = OmniPickerRow(candidate: c, query: "", shortcut: nil)
            #expect(row.serverChipText == (c.action == .attach(remote.key) ? "WSL" : nil))
        }
        let launch = OmniCandidate(
            action: .run("claude", at: SpawnPlace(server: "WSL", cwd: "/home/spierce")), kind: .typed,
            headline: "claude", detail: "/home/spierce", quality: .typed, chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil)
        #expect(OmniPickerRow(candidate: launch, query: "claude", shortcut: nil).serverChipText == "WSL")
        let here = OmniCandidate(
            action: .run("claude", at: .local), kind: .typed,
            headline: "claude", detail: "", quality: .typed, chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil)
        #expect(OmniPickerRow(candidate: here, query: "claude", shortcut: nil).serverChipText == nil)

        // ⌘P's session rows.
        #expect(PaletteSessionRow(PaletteSession(telemetry: remote, titleMatches: [])).serverChipText == "WSL")
        #expect(PaletteSessionRow(PaletteSession(telemetry: local, titleMatches: [])).serverChipText == nil)
    }

    @Test("the lane header wears the chip beside a path that no longer repeats the server; the ledger's tag keeps it")
    func laneHeader() {
        let lane = Lane(
            id: "L", ordinal: 1, widthPt: 500, title: "bash", projectRoot: "WSL:/home/spierce",
            projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1, isPrivate: false,
            panes: [Pane(id: "P", laneId: "L", position: 0, kind: .pty, relaySessionId: "a1", relayServer: "WSL",
                         url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
                         heightWeight: 1, zoom: 1, mobile: false)])
        let header = LaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: 620, height: Theme.laneHeaderHeight)
        header.apply(lane)
        header.telemetry = t("a1", "WSL", "/home/spierce")
        header.layout()
        #expect(header.serverChipText == "WSL")
        #expect(header.pathText == "/home/spierce")
        #expect(lane.projectRoot == "WSL:/home/spierce")
        #expect(t("a1", "WSL", "/home/spierce").groupPath == "WSL:/home/spierce", "the group's key, and the tag, are unchanged")
        // A remote path is never `~` for this Mac's home.
        header.telemetry = t("a1", "WSL", NSHomeDirectory() + "/x")
        header.layout()
        #expect(header.pathText == NSHomeDirectory() + "/x")
    }

    @Test("with no server configured there is no chip, no section header and no offline anywhere")
    func noServers() throws {
        let a = t("b1", nil, NSHomeDirectory() + "/code/max-pane")
        let b = t("b2", nil, NSHomeDirectory() + "/life")
        let rows = SidebarModel.rows(lanes: [], telemetry: [a.key: a, b.key: b])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        #expect(groups.map(\.header) == ["~/code/max-pane", "~/life"])
        #expect(groups.allSatisfy { !$0.isSection && $0.stateChip == nil && !$0.serverIsOffline })
        #expect(groups.map(\.countText) == ["1 RUNNING", "1 RUNNING"])
        for case .entry(let e) in rows {
            #expect(!e.offline && e.server == nil)
            #expect(SidebarEntryView(entry: e).serverChipText == nil)
        }
        for case .group(let g) in rows {
            let view = SidebarGroupView(group: g)
            #expect(view.stateChipText.isEmpty && !view.labelText.hasPrefix("//"))
        }
        #expect(!a.isOffline && a.badgeText == "idle")
    }
}

// MARK: - render sheets

/// The sidebar connected and disconnected, and a lane header connected and
/// disconnected, for looking at. Gated on `MAXPANE_SHOTS` like every sheet.
@Suite("remote presence rendering")
@MainActor
struct RemotePresenceRenderTests {
    private func t(_ id: String, _ server: String?, _ cwd: String, _ state: AgentState, _ title: String,
                   _ connection: ServerState?) -> SessionTelemetry {
        var t = SessionTelemetry(
            sessionId: id, server: server, title: title, cwd: cwd, command: "claude", state: state,
            bytesPerSecond: state == .working ? 1740 : 0, lastActivity: Date().addingTimeInterval(-40))
        t.connection = connection
        return t
    }

    private func telemetry(_ wsl: ServerState) -> [SessionKey: SessionTelemetry] {
        [
            "0368d543": t("0368d543", nil, NSHomeDirectory() + "/code/max-pane", .working, "◐ Editing SidebarModel.swift", nil),
            "77aa0000": t("77aa0000", nil, NSHomeDirectory() + "/life", .idle, "✳ Inbox sweep", nil),
            SessionKey(server: "WSL", id: "0368d543"): t("0368d543", "WSL", "/home/spierce/m7out", .blocked, "Waiting on permission", wsl),
            SessionKey(server: "WSL", id: "4f2a0000"): t("4f2a0000", "WSL", "/home/spierce", .working, "◑ Refactoring the tunnel client", wsl),
            SessionKey(server: "WSL", id: "5b1c0000"): t("5b1c0000", "WSL", "/home/spierce", .idle, "bash", wsl),
        ]
    }

    @Test("renders the sidebar connected, disconnected, unreachable and refused, and with no servers at all")
    func sidebarSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let cases: [(String, [SessionKey: SessionTelemetry], [String: ServerState], [String: String])] = [
            ("connected", telemetry(.connected), ["WSL": .connected], [:]),
            ("reconnecting", telemetry(.reconnecting), ["WSL": .reconnecting], ["WSL": "unreachable — yourslug.relaytty.com: The request timed out."]),
            ("unreachable", telemetry(.unreachable), ["WSL": .unreachable, "yorkshire-miniforum": .refused], [:]),
            ("no-servers", telemetry(.connected).filter { $0.key.server == nil }, [:], [:]),
        ]
        for (name, telemetry, servers, errors) in cases {
            let rows = SidebarModel.rows(lanes: [], telemetry: telemetry, servers: servers, serverErrors: errors)
            let heights = rows.map { row -> CGFloat in
                if case .group = row { return SidebarGroupView.height }
                return SidebarEntryView.height
            }
            for width in [260.0, 320.0] as [CGFloat] {
                try AppearanceSheet.render(to: dir, named: "presence-sidebar-\(name)-\(Int(width))") {
                    let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: heights.reduce(0, +) + 8))
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
                    return sheet
                }
            }
        }
    }

    @Test("renders a remote lane header connected and disconnected, beside a local one")
    func headerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        func lane(_ title: String, server: String?, root: String) -> Lane {
            Lane(id: "l", ordinal: 1, widthPt: 420, title: title, projectRoot: root,
                 projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1, isPrivate: false,
                 panes: [Pane(id: "p", laneId: "l", position: 0, kind: .pty, relaySessionId: "a", relayServer: server,
                              url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
                              heightWeight: 1, zoom: 1, mobile: false)])
        }
        let remote = lane("Waiting on permission", server: "WSL", root: "WSL:/home/spierce/m7out")
        let cases: [(Lane, SessionTelemetry?, ServerState?, Bool)] = [
            (lane("Editing SidebarModel.swift", server: nil, root: NSHomeDirectory() + "/code/max-pane"),
             t("l", nil, NSHomeDirectory() + "/code/max-pane", .working, "", nil), nil, true),
            (remote, t("a", "WSL", "/home/spierce/m7out", .blocked, "", .connected), .connected, false),
            (remote, t("a", "WSL", "/home/spierce/m7out", .working, "", .connected), .connected, true),
            (remote, t("a", "WSL", "/home/spierce/m7out", .blocked, "", .reconnecting), .reconnecting, true),
            (remote, t("a", "WSL", "/home/spierce/m7out", .blocked, "", .unreachable), .unreachable, false),
            (remote, nil, .refused, false),
            (lane("bash", server: "yorkshire-miniforum", root: "yorkshire-miniforum:/srv/very/deep/path/to/a/project"),
             t("a", "yorkshire-miniforum", "/srv/very/deep/path/to/a/project", .idle, "", .connected), .connected, false),
        ]
        for width in [300.0, 420.0, 620.0] as [CGFloat] {
            try AppearanceSheet.render(to: dir, named: "presence-header-\(Int(width))") {
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(cases.count) * 40))
                sheet.wantsLayer = true
                sheet.layerBackgroundColor = Theme.laneBackground
                for (index, item) in cases.enumerated() {
                    let header = LaneHeaderView()
                    header.frame = NSRect(
                        x: 0, y: CGFloat(cases.count - index - 1) * 40 + 6, width: width, height: Theme.laneHeaderHeight)
                    header.apply(item.0)
                    header.serverState = item.2
                    header.telemetry = item.1
                    header.isFocused = item.3
                    sheet.addSubview(header)
                    header.layoutSubtreeIfNeeded()
                    header.layout()
                }
                return sheet
            }
        }
    }

    @Test("renders ⌘O's remote session and launch rows, and the pane banner")
    func pickerAndBannerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let sessions = Array(telemetry(.connected).values) + [t("9c000000", "WSL", "/home/spierce", .idle, "htop", .reconnecting)]
        let rows = OmniRanking.build(
            query: "", scope: .sessions, recents: [], pages: [], bookmarks: [],
            sessions: sessions.sorted { $0.key < $1.key }, destination: "→ new lane")
            + [.item(OmniCandidate(
                action: .run("claude", at: SpawnPlace(server: "WSL", cwd: "/home/spierce/m7out")), kind: .typed,
                headline: "claude", detail: "/home/spierce/m7out", quality: .typed, chosenAt: 0, count: 0,
                telemetry: nil, bookmarkId: nil))]
        let heights = rows.map { $0.isSelectable ? 42.0 : 26.0 as CGFloat }
        try AppearanceSheet.render(to: dir, named: "presence-omni") {
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: heights.reduce(0, +) + 30 * 3))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBackground
            var y = sheet.bounds.height
            for (row, height) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .item(let c): view = OmniPickerRow(candidate: c, query: "", shortcut: nil)
                case .section(let title, let note), .note(let title, let note): view = PaletteSectionRow(title: title, note: note)
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: 640, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            for state in [ReconnectingBanner.State.reconnecting, .offline(.reconnecting), .offline(.unreachable)] {
                let banner = ReconnectingBanner(frame: .zero)
                banner.setState(state)
                y -= 30
                banner.frame = NSRect(x: 0, y: y + 4, width: 640, height: 22)
                sheet.addSubview(banner)
                banner.layoutSubtreeIfNeeded()
            }
            return sheet
        }
    }
}

// MARK: - the real server, frozen

/// Freeze the real relay server (`kill -STOP` on its node pid, by the
/// caller, over ssh) and time what the app's own source and adapter do.
/// Gated on `MAXPANE_PRESENCE_VERIFY` naming the base URL, with
/// `MAXPANE_REMOTE_TOKEN` and `MAXPANE_REMOTE_SESSION`; the freeze and the
/// thaw are commands in `MAXPANE_PRESENCE_FREEZE` / `MAXPANE_PRESENCE_THAW`,
/// run with `/bin/sh -c`. The token is read from the environment and never
/// printed. Nothing is typed into the session and nothing is spawned.
@Suite("presence against the real server, frozen, when MAXPANE_PRESENCE_VERIFY names it", .serialized)
@MainActor
struct LivePresenceTests {
    private func sh(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try? p.run()
        p.waitUntilExit()
    }

    @Test("time to offline, and time to recover, with the shipped numbers")
    func frozen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MAXPANE_PRESENCE_VERIFY"].flatMap(URL.init(string:)),
              let freeze = env["MAXPANE_PRESENCE_FREEZE"], let thaw = env["MAXPANE_PRESENCE_THAW"]
        else {
            print("SKIPPED live presence check — set MAXPANE_PRESENCE_VERIFY, _FREEZE, _THAW and MAXPANE_REMOTE_TOKEN to run it")
            return
        }
        let endpoint = RelayServer(baseURL: base, token: env["MAXPANE_REMOTE_TOKEN"])
        let source = RemoteSessionSource(name: "live", endpoint: endpoint, pollInterval: 5)
        let registry = SessionRegistry(sources: [source])
        defer { registry.stop(); sh(thaw) }
        #expect(await spin(20) { registry.serverStates["live"] == .connected && !registry.sessions.isEmpty })
        let id = env["MAXPANE_REMOTE_SESSION"] ?? registry.sessions.keys.first!.id
        let key = SessionKey(server: "live", id: id)

        let adapter = RelayAttachmentAdapter(sessionId: id, server: "live") { queue in
            WebSocketTransport(server: endpoint, sessionId: id, queue: queue)
        }
        var wire: [(Bool, Date)] = []
        var lost = 0
        adapter.onConnectionChange = { wire.append(($0, Date())) }
        adapter.onWireLost = { lost += 1; registry.laneLostWire(server: "live") }
        registry.onServerStateChange = { _, state in adapter.serverStateChanged(state) }
        adapter.connect()
        defer { adapter.disconnect() }
        #expect(await spin(20) { wire.last?.0 == true })

        // A quiet minute first: the ping must not churn a healthy server.
        let fetchesBefore = source.fetches
        try await Task.sleep(for: .seconds(20))
        #expect(registry.serverStates["live"] == .connected)
        print("live presence: 20 s healthy — \(source.fetches - fetchesBefore) list fetches, state \(registry.serverStates["live"]!)")

        for round in 1...2 {
            sh(freeze)
            let frozenAt = Date()
            #expect(await spin(40) { registry.serverStates["live"]?.isOff == true }, "never noticed the freeze")
            let sourceTook = Date().timeIntervalSince(frozenAt)
            #expect(registry.sessions[key]?.isOffline == true)
            #expect(await spin(20) { wire.last?.0 == false }, "the lane's wire never agreed")
            let laneTook = (wire.last?.1 ?? Date()).timeIntervalSince(frozenAt)
            print(String(format: "live presence round %d: source offline after %.1f s; lane banner after %.1f s (error: %@)",
                         round, sourceTook, laneTook, registry.serverErrors["live"] ?? "-"))

            try await Task.sleep(for: .seconds(round == 1 ? 8 : 25))
            sh(thaw)
            let thawedAt = Date()
            #expect(await spin(40) { registry.serverStates["live"] == .connected }, "never recovered")
            let sourceBack = Date().timeIntervalSince(thawedAt)
            #expect(registry.sessions[key]?.isOffline == false)
            #expect(await spin(60) { wire.last?.0 == true }, "the lane never reattached")
            let laneBack = (wire.last?.1 ?? Date()).timeIntervalSince(thawedAt)
            print(String(format: "live presence round %d: source back after %.1f s; lane reattached after %.1f s", round, sourceBack, laneBack))
            try await Task.sleep(for: .seconds(6))
        }
        print("live presence: wire-lost reports \(lost)")
    }
}
