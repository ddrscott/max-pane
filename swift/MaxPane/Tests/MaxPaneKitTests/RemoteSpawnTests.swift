import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit
@testable import RelayClient

// serial pass: a real loopback server, and waits measured against the wall
// clock. The whole suite runs in `scripts/test.sh`'s second, --no-parallel
// pass; see README, "The serial pass".

// Phase 3 of the remote relay plan: starting a session on a remote server
// from ⌘O, ⌘T and ⌘D. The body the server is sent, where a line runs, the
// picker's one piece of grammar, and the ledger doors — against the fake
// server, never the real one (that is `LiveRemoteSpawnTests`).

private func args(_ body: [String: Any]) -> [String] { body["args"] as? [String] ?? [] }

@Suite("the body POST /api/sessions is sent")
struct RemoteSpawnBodyTests {
    @Test("a command line is the no-exec wrapper: $SHELL -li -c '<program> <args>; exit $?'")
    func programBody() {
        let body = RemoteSpawner.body(cwd: "/home/s/proj", command: "claude", args: ["--model", "sonnet"], cols: 100, rows: 40)
        #expect(body["command"] as? String == "$SHELL")
        #expect(args(body) == ["-li", "-c", "'claude' '--model' 'sonnet'; exit $?"])
        #expect(body["cwd"] as? String == "/home/s/proj")
        #expect(body["cols"] as? Int == 100)
        #expect(body["rows"] as? Int == 40)
        // The same wrapper the local argv carries, word for word after the head.
        let local = LocalSpawner.buildArgs(id: "x", cols: 100, rows: 40, cwd: "/home/s/proj", command: "claude", args: ["--model", "sonnet"])
        #expect(Array(local.dropFirst(5)) == args(body))
    }

    @Test("a typed line reaches -c whole, terminated by a newline, exactly as the local argv does")
    func shellLineBody() {
        let body = RemoteSpawner.body(cwd: nil, shellLine: "yes | head", cols: 80, rows: 24)
        #expect(body["command"] as? String == "$SHELL")
        #expect(args(body) == ["-li", "-c", "yes | head\nexit $?"])
        #expect(body["cwd"] == nil, "no directory means the server's home, and the key is absent rather than this Mac's path")
        let local = LocalSpawner.buildShellArgs(id: "x", cols: 80, rows: 24, cwd: "/", line: "yes | head")
        #expect(Array(local.dropFirst(5)) == args(body))
    }

    @Test("a bare shell is $SHELL with no arguments, so the server gives it --login and it stays the leader")
    func bareShellBody() {
        let body = RemoteSpawner.body(cwd: "/home/s", command: nil, args: [], cols: 80, rows: 24)
        #expect(body["command"] as? String == "$SHELL")
        #expect(args(body) == [])
        #expect(body["cwd"] as? String == "/home/s")
    }

    @Test("a shell named outright is the command itself, unwrapped, as it is locally")
    func namedShellBody() {
        let body = RemoteSpawner.body(cwd: nil, command: "zsh", args: [], cols: 80, rows: 24)
        #expect(body["command"] as? String == "zsh")
        #expect(args(body) == [])
        let bash = RemoteSpawner.body(cwd: nil, command: "/bin/bash", args: ["-x"], cols: 80, rows: 24)
        #expect(bash["command"] as? String == "/bin/bash")
        #expect(args(bash) == ["-x"])
    }

    @Test("the server's error body becomes the one line, and a non-JSON body is trimmed to a line")
    func errorLine() {
        #expect(RemoteSpawner.errorLine(Data("{\"error\":\"command is required\"}".utf8)) == "command is required")
        #expect(RemoteSpawner.errorLine(Data("Bad Gateway\nmore\n".utf8)) == "Bad Gateway")
        #expect(RemoteSpawner.errorLine(nil) == "")
        let refused = RemoteSpawner.SpawnError.refused(server: "yorkshire", status: 502, body: "Bad Gateway")
        #expect(refused.errorDescription == "yorkshire: could not start the session — HTTP 502: Bad Gateway")
    }
}

@Suite("the remote spawner against the fake server")
@MainActor
struct RemoteSpawnLiveTests {
    private func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    @Test("POST with the cookie, 201 is readiness, then GET /api/sessions/:id; the key is (server, id) and the cwd is the server's home when none was sent")
    func spawnOnFake() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.home = "/home/spierce"
        server.nextSpawnId = "c0ffee01"
        let spawner = RemoteSpawner(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: server.token))
        var result: Result<SpawnedSession, Error>?
        spawner.spawn(cwd: nil, typed: .program("claude", args: []), cols: 100, rows: 40) { result = $0 }
        #expect(await spin(5) { result != nil })
        let spawned = try #require(try result?.get())
        #expect(spawned.key == SessionKey(server: "yorkshire", id: "c0ffee01"))
        #expect(spawned.cwd == "/home/spierce")

        let bodies = server.spawnBodies
        #expect(bodies.count == 1)
        #expect(bodies.first?["command"] as? String == "$SHELL")
        #expect(bodies.first.map(args) == ["-li", "-c", "'claude'; exit $?"])
        #expect(bodies.first?["cwd"] == nil)
        #expect(server.requestLines == ["POST /api/sessions HTTP/1.1", "GET /api/sessions/c0ffee01 HTTP/1.1"])
    }

    /// How every caller in the app spawns: `try spawner(at: place).spawn(…)`,
    /// a spawner made for one spawn and let go on the same line. The first
    /// version captured itself weakly, so by the time the server answered it
    /// was gone and the completion was never called: a session started on the
    /// box, no lane here, and no error. Found by driving the installed app over
    /// its socket; every test above holds its spawner in a `let`, which is why
    /// none of them saw it.
    @Test("a spawner nobody holds still answers, for a success and for a refusal")
    func aTemporarySpawnerCompletes() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.nextSpawnId = "c0ffee02"
        let endpoint = RelayServer(baseURL: server.baseURL, token: server.token)
        var result: Result<SpawnedSession, Error>?
        RemoteSpawner(name: "yorkshire", endpoint: endpoint)
            .spawn(cwd: nil, command: nil, args: [], cols: 80, rows: 24) { result = $0 }
        #expect(await spin(5) { result != nil }, "the completion was never called")
        #expect(try result?.get().key == SessionKey(server: "yorkshire", id: "c0ffee02"))

        server.spawnRefusal = (status: 500, error: "no")
        var refused: Result<SpawnedSession, Error>?
        RemoteSpawner(name: "yorkshire", endpoint: endpoint)
            .spawn(cwd: nil, command: nil, args: [], cols: 80, rows: 24) { refused = $0 }
        #expect(await spin(5) { refused != nil }, "the refusal was never reported")
    }

    @Test("a refusal is one line naming the server and the server's error body")
    func refusedOnFake() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.spawnRefusal = (status: 500, error: "spawn ENOENT relay-pty-host")
        let spawner = RemoteSpawner(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: server.token))
        var result: Result<SpawnedSession, Error>?
        spawner.spawn(cwd: "/home/s", shellLine: "claude", cols: 80, rows: 24) { result = $0 }
        #expect(await spin(5) { result != nil })
        guard case .failure(let error)? = result else { Issue.record("the refusal was not an error"); return }
        #expect(StripWindowController.describe(error) == "yorkshire: could not start the session — HTTP 500: spawn ENOENT relay-pty-host")
    }

    @Test("a wrong token is a 401 with the server named, never a session")
    func wrongTokenOnFake() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        let spawner = RemoteSpawner(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: "nope"))
        var result: Result<SpawnedSession, Error>?
        spawner.spawn(cwd: nil, command: nil, args: [], cols: 80, rows: 24) { result = $0 }
        #expect(await spin(5) { result != nil })
        guard case .failure(let error)? = result else { Issue.record("a wrong token spawned"); return }
        #expect(StripWindowController.describe(error).hasPrefix("yorkshire: could not start the session — HTTP 401"))
        #expect(server.spawnBodies.isEmpty, "the fake refuses on the cookie before it reads a body, as relay-tty's middleware does")
    }

    @Test("the servers book hands out a spawner per name, local for nil, none for a stranger")
    func spawnerPerServer() throws {
        let servers = RelayServers(
            entries: [RelayServerEntry(name: "yorkshire", url: "http://127.0.0.1:1", enabled: true)],
            token: { _ in "t" })
        let config = Config()
        #expect(servers.spawner(for: nil, config: config) is LocalSpawner)
        #expect((servers.spawner(for: "yorkshire", config: config) as? RemoteSpawner)?.server == "yorkshire")
        #expect(servers.spawner(for: "alien", config: config) == nil)
    }
}

@Suite("where a line runs")
struct SpawnPlaceTests {
    private let exists: (String) -> Bool = { $0.hasPrefix("/here") }
    private let connected: (String) -> Bool = { $0 == "yorkshire" }
    private let remoteLane = SpawnPlace(server: "yorkshire", cwd: "/home/s/proj")
    private let localLane = SpawnPlace(server: nil, cwd: "/here/code")

    @Test("⌘T and ⌘D beside a lane are that lane's server and directory; beside nothing, this Mac's home")
    func siblings() {
        // ⌘T/⌘D use the focused place directly — `resolve` with no choice
        // and no memory is that place, whichever server it is on.
        #expect(SpawnPlace.resolve(choice: nil, remembered: nil, focused: remoteLane, exists: exists, connected: connected) == remoteLane)
        #expect(SpawnPlace.resolve(choice: nil, remembered: nil, focused: localLane, exists: exists, connected: connected) == localLane)
        #expect(SpawnPlace.resolve(choice: nil, remembered: nil, focused: .local, exists: exists, connected: connected) == .local)
        // A remote lane whose directory the server has not reported yet is
        // that server's home, never this Mac's.
        let unknown = SpawnPlace(server: "yorkshire", cwd: nil)
        #expect(SpawnPlace.resolve(choice: nil, remembered: nil, focused: unknown, exists: exists, connected: connected) == unknown)
    }

    @Test("⌘O with nothing said: a remembered place wins when it can be used, else the focused lane's")
    func plainLine() {
        let rememberedHere = SpawnPlace(server: nil, cwd: "/here/other")
        let rememberedGone = SpawnPlace(server: nil, cwd: "/gone")
        let rememberedRemote = SpawnPlace(server: "yorkshire", cwd: "/home/s/x")
        let rememberedOffline = SpawnPlace(server: "alien", cwd: "/home/s/x")
        #expect(SpawnPlace.resolve(choice: nil, remembered: rememberedHere, focused: remoteLane, exists: exists, connected: connected) == rememberedHere)
        #expect(SpawnPlace.resolve(choice: nil, remembered: rememberedGone, focused: remoteLane, exists: exists, connected: connected) == remoteLane)
        #expect(SpawnPlace.resolve(choice: nil, remembered: rememberedRemote, focused: localLane, exists: exists, connected: connected) == rememberedRemote)
        #expect(SpawnPlace.resolve(choice: nil, remembered: rememberedOffline, focused: localLane, exists: exists, connected: connected) == localLane)
    }

    @Test("@server: that server; the remembered directory only if it was there, else the focused lane's if it is there, else home")
    func explicitServer() {
        let choice = SpawnPlace.Choice.server("yorkshire")
        #expect(SpawnPlace.resolve(choice: choice, remembered: nil, focused: localLane, exists: exists, connected: connected) == SpawnPlace(server: "yorkshire", cwd: nil))
        #expect(SpawnPlace.resolve(choice: choice, remembered: nil, focused: remoteLane, exists: exists, connected: connected) == remoteLane)
        #expect(SpawnPlace.resolve(choice: choice, remembered: SpawnPlace(server: nil, cwd: "/here/code"), focused: localLane, exists: exists, connected: connected) == SpawnPlace(server: "yorkshire", cwd: nil), "a local path is no help over there")
        #expect(SpawnPlace.resolve(choice: choice, remembered: SpawnPlace(server: "yorkshire", cwd: "/home/s/y"), focused: remoteLane, exists: exists, connected: connected) == SpawnPlace(server: "yorkshire", cwd: "/home/s/y"))
        // Even a server that is not connected: the spawn says so, the rule does not guess.
        #expect(SpawnPlace.resolve(choice: .server("alien"), remembered: nil, focused: remoteLane, exists: exists, connected: connected) == SpawnPlace(server: "alien", cwd: nil))
    }

    @Test("@local: this Mac, in the remembered directory if it is here and exists, else the focused lane's if it is local, else home")
    func explicitLocal() {
        #expect(SpawnPlace.resolve(choice: .local, remembered: nil, focused: remoteLane, exists: exists, connected: connected) == .local)
        #expect(SpawnPlace.resolve(choice: .local, remembered: nil, focused: localLane, exists: exists, connected: connected) == localLane)
        #expect(SpawnPlace.resolve(choice: .local, remembered: SpawnPlace(server: nil, cwd: "/here/x"), focused: remoteLane, exists: exists, connected: connected) == SpawnPlace(server: nil, cwd: "/here/x"))
        #expect(SpawnPlace.resolve(choice: .local, remembered: SpawnPlace(server: "yorkshire", cwd: "/home/s"), focused: localLane, exists: exists, connected: connected) == localLane)
    }

    @Test("a recent remembers its place as host:path, the ledger's own form, and reads it back only for a configured server")
    func remembered() {
        #expect(SpawnPlace(server: "yorkshire", cwd: "/home/s").remembered == "yorkshire:/home/s")
        #expect(SpawnPlace(server: nil, cwd: "/Users/s").remembered == "/Users/s")
        #expect(SpawnPlace(server: "yorkshire", cwd: nil).remembered == nil)
        #expect(SpawnPlace.parse(remembered: "yorkshire:/home/s", servers: ["yorkshire"]) == SpawnPlace(server: "yorkshire", cwd: "/home/s"))
        #expect(SpawnPlace.parse(remembered: "yorkshire:/home/s", servers: []) == SpawnPlace(server: nil, cwd: "yorkshire:/home/s"), "a server that is gone reads as a path that will not exist")
        #expect(SpawnPlace.parse(remembered: "/Users/s", servers: ["yorkshire"]) == SpawnPlace(server: nil, cwd: "/Users/s"))
        #expect(SpawnPlace.parse(remembered: nil, servers: ["yorkshire"]) == nil)
        #expect(SpawnPlace.parse(remembered: "", servers: ["yorkshire"]) == nil)
        #expect(SpawnPlace(server: "yorkshire", cwd: nil).label == "yorkshire:~")
        #expect(SpawnPlace(server: "yorkshire", cwd: "/home/s").label == "yorkshire:/home/s")
    }
}

@Suite("⌘O's grammar: @server, @local, and the row that says where")
@MainActor
struct OmniServerGrammarTests {
    private func recent(_ value: String, cwd: String?, at: Int64 = 1) -> Recent {
        Recent(kind: .command, value: value, cwd: cwd, lastUsedAt: at, useCount: 1)
    }

    private func build(_ query: String, recents: [Recent] = [], place: SpawnPlace = .local,
                       servers: [String] = ["yorkshire", "alien"], connected: Set<String> = ["yorkshire"]) -> [OmniRow] {
        OmniRanking.build(
            query: query, scope: .everything, recents: recents, pages: [], bookmarks: [], sessions: [],
            destination: "→", shellName: "zsh", place: place, servers: servers, connected: connected,
            exists: { $0.hasPrefix("/here") })
    }

    private func launch(_ rows: [OmniRow]) -> OmniCandidate? {
        rows.compactMap(\.candidate).first { $0.kind == .typed }
    }

    @Test("the prefix is a known server's name, or local, or nothing at all")
    func prefix() {
        let servers = ["yorkshire"]
        #expect(OmniServerPrefix.parse("@yorkshire claude", servers: servers) == OmniServerPrefix(choice: .server("yorkshire"), line: "claude", unknown: nil))
        #expect(OmniServerPrefix.parse("  @yorkshire   yes | head ", servers: servers) == OmniServerPrefix(choice: .server("yorkshire"), line: "yes | head", unknown: nil))
        #expect(OmniServerPrefix.parse("@local htop", servers: servers) == OmniServerPrefix(choice: .local, line: "htop", unknown: nil))
        #expect(OmniServerPrefix.parse("@yorkshire", servers: servers) == OmniServerPrefix(choice: .server("yorkshire"), line: "", unknown: nil))
        #expect(OmniServerPrefix.parse("@nope claude", servers: servers) == OmniServerPrefix(choice: nil, line: "@nope claude", unknown: "nope"))
        #expect(OmniServerPrefix.parse("claude", servers: servers) == OmniServerPrefix(choice: nil, line: "claude", unknown: nil))
        #expect(OmniServerPrefix.parse("user@host", servers: servers) == OmniServerPrefix(choice: nil, line: "user@host", unknown: nil))
    }

    @Test("with no @, the LAUNCH row runs where the focused lane is, and says so only when that is a server")
    func launchRowFollowsTheLane() {
        let local = launch(build("claude"))
        #expect(local?.action == .run("claude", at: .local))
        #expect(local?.detail == "")
        let remote = launch(build("claude", place: SpawnPlace(server: "yorkshire", cwd: "/home/s/proj")))
        #expect(remote?.action == .run("claude", at: SpawnPlace(server: "yorkshire", cwd: "/home/s/proj")))
        #expect(remote?.headline == "claude")
        #expect(remote?.detail == "/home/s/proj")
        #expect(remote?.server == "yorkshire", "the chip says which server; the line says which directory")
        #expect(local?.server == nil)
        let unknownDir = launch(build("yes | head", place: SpawnPlace(server: "yorkshire", cwd: nil)))
        #expect(unknownDir?.detail == "~", "the server's home, and no local shell named for a remote line")
        #expect(unknownDir?.server == "yorkshire")
    }

    @Test("@server moves the line to that server, in its home from a local lane; @local brings it back")
    func explicitPrefix() {
        let there = launch(build("@yorkshire claude", place: SpawnPlace(server: nil, cwd: "/here/code")))
        #expect(there?.headline == "claude")
        #expect(there?.action == .run("claude", at: SpawnPlace(server: "yorkshire", cwd: nil)))
        #expect(there?.detail == "~")
        #expect(there?.server == "yorkshire")
        let here = launch(build("@local claude", place: SpawnPlace(server: "yorkshire", cwd: "/home/s")))
        #expect(here?.action == .run("claude", at: .local))
        #expect(here?.detail == "")
        // A shell line still says which shell, locally.
        #expect(launch(build("@local yes | head"))?.detail == "through zsh")
    }

    @Test("@nothing is left as typed and the row says it is not a server")
    func unknownPrefix() {
        let row = launch(build("@nope claude"))
        #expect(row?.headline == "@nope claude")
        #expect(row?.action == .run("@nope claude", at: .local))
        #expect(row?.detail == "@nope is not a server")
    }

    @Test("a recent remembers its server: offered with its place while the server is connected, not at all while it is not")
    func recentsRemember() {
        let recents = [
            recent("claude", cwd: "yorkshire:/home/s/proj", at: 3),
            recent("npm test", cwd: "alien:/home/s/web", at: 2),
            recent("htop", cwd: "/here/code", at: 1),
        ]
        let rows = build("", recents: recents).compactMap(\.candidate)
        #expect(rows.map(\.headline) == ["claude", "htop"], "the alien recent is not offered while alien is not connected")
        #expect(rows[0].action == .run("claude", at: SpawnPlace(server: "yorkshire", cwd: "/home/s/proj")))
        #expect(rows[0].detail == "/home/s/proj")
        #expect(rows[0].server == "yorkshire")
        #expect(rows[1].action == .run("htop", at: SpawnPlace(server: nil, cwd: "/here/code")))

        // Connected now: offered, with its place.
        let back = build("npm", recents: recents, connected: ["yorkshire", "alien"]).compactMap(\.candidate).first { $0.kind == .command }
        #expect(back?.action == .run("npm test", at: SpawnPlace(server: "alien", cwd: "/home/s/web")))
    }

    @Test("@server over a recent keeps the remembered directory only when it was on that server")
    func prefixOverRecent() {
        let recents = [recent("claude", cwd: "yorkshire:/home/s/proj"), recent("htop", cwd: "/here/code")]
        let rows = build("@yorkshire", recents: recents).compactMap(\.candidate)
        #expect(rows.map(\.headline) == ["claude", "htop"])
        #expect(rows[0].action == .run("claude", at: SpawnPlace(server: "yorkshire", cwd: "/home/s/proj")))
        #expect(rows[1].action == .run("htop", at: SpawnPlace(server: "yorkshire", cwd: nil)), "a local path does not follow the line to the server")
        let local = build("@local", recents: recents).compactMap(\.candidate)
        #expect(local[0].action == .run("claude", at: .local))
        #expect(local[1].action == .run("htop", at: SpawnPlace(server: nil, cwd: "/here/code")))
    }

    @Test("nothing local changes when no server is configured")
    func noServers() {
        let recents = [recent("htop", cwd: "/here/code")]
        let rows = OmniRanking.build(
            query: "htop", scope: .everything, recents: recents, pages: [], bookmarks: [], sessions: [],
            destination: "→", shellName: "zsh", exists: { $0.hasPrefix("/here") })
        let candidates = rows.compactMap(\.candidate)
        #expect(candidates.map(\.action) == [.run("htop", at: .local), .open("htop"), .run("htop", at: SpawnPlace(server: nil, cwd: "/here/code"))])
        #expect(candidates.map(\.detail) == ["", "", OmniText.tilde("/here/code")])
        // `@x` with no servers at all is still just a line.
        #expect(launch(OmniRanking.build(query: "@x y", scope: .everything, recents: [], pages: [], bookmarks: [], sessions: [], destination: "→"))?.action == .run("@x y", at: .local))
    }
}

@Suite("the ledger doors a remote spawn goes through")
@MainActor
struct RemoteSpawnDoorTests {
    private func store() throws -> StripStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
    }

    @Test("a remote session started beside a lane lands right of it knowing its server; a split pane joins the lane the same way")
    func doors() throws {
        let store = try store()
        try store.newTerminalLane(relaySessionId: "aaaa0001", near: nil)
        try store.newTerminalLane(relaySessionId: "aaaa0002", near: nil)
        let first = store.state.lanes[0].id
        try store.newTerminalLane(session: SessionKey(server: "yorkshire", id: "c0ffee01"), near: first)
        #expect(store.state.lanes.map { $0.panes[0].sessionKey } == ["aaaa0001", SessionKey(server: "yorkshire", id: "c0ffee01"), "aaaa0002"])
        let remoteLane = store.state.lanes[1].id
        try store.addTerminalPane(to: remoteLane, session: SessionKey(server: "yorkshire", id: "c0ffee02"))
        #expect(store.lane(remoteLane)?.panes.map(\.sessionKey) == [SessionKey(server: "yorkshire", id: "c0ffee01"), SessionKey(server: "yorkshire", id: "c0ffee02")])
        #expect(store.lane(remoteLane)?.panes.map(\.relayServer) == ["yorkshire", "yorkshire"])
        // And a local one through the same door is a local pane.
        try store.addTerminalPane(to: first, session: "aaaa0003")
        #expect(store.lane(first)?.panes.map(\.relayServer) == [nil, nil])
    }

    @Test("a remote lane's project is host:path from the cwd the server reports, so it gathers with its own and never with a local path that matches")
    func projectRoot() throws {
        let store = try store()
        let here = FileManager.default.currentDirectoryPath
        try store.newTerminalLane(session: SessionKey(server: "yorkshire", id: "c0ffee01"), near: nil)
        try store.newTerminalLane(session: SessionKey(server: "yorkshire", id: "c0ffee02"), near: nil)
        try store.newTerminalLane(relaySessionId: "aaaa0001", near: nil)
        let lanes = store.state.lanes.map(\.id)
        store.observeCwd(lanes[0], here)
        store.observeCwd(lanes[1], here)
        store.observeCwd(lanes[2], here)
        let roots = store.state.lanes.map(\.projectRoot)
        #expect(roots[0] == "yorkshire:\(here)")
        #expect(roots[1] == "yorkshire:\(here)")
        #expect(roots[2] != roots[0])
        try store.gather(projectRoot: "yorkshire:\(here)")
        #expect(store.state.lanes.map(\.id) == [lanes[0], lanes[1]])
    }
}

// MARK: - the real server

/// The whole path against the real server, when `MAXPANE_REMOTE_VERIFY`
/// names it (base URL) and `MAXPANE_REMOTE_TOKEN` carries the token, read at
/// run time and never printed. `MAXPANE_REMOTE_LINE` is the line ⌘O would be
/// given (default `claude`), and `MAXPANE_REMOTE_CWD` where; with a real
/// Claude Code that cannot prompt (an expired login) the owner points the
/// line at a stand-in the classifier recognises and the report says so.
///
/// What it proves: the wrapper reaches the box and the agent is classified
/// BLOCKED in the registry — the sidebar's model — while the same program
/// started through the server's own `exec` wrapper never is; the lane is
/// made, closed, and the session reattached from the picker's action; the
/// prompt is answered over the WebSocket; the session is torn down.
@Suite("starting a session on the real server, when MAXPANE_REMOTE_VERIFY names it", .serialized)
@MainActor
struct LiveRemoteSpawnTests {
    @Test("⌘O's line runs there through the wrapper, goes BLOCKED in the sidebar, is answered, closed and reattached")
    func spawnAndBlock() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MAXPANE_REMOTE_VERIFY"].flatMap(URL.init(string:)), let token = env["MAXPANE_REMOTE_TOKEN"], !token.isEmpty else {
            print("SKIPPED live remote spawn check — set MAXPANE_REMOTE_VERIFY=<base url> and MAXPANE_REMOTE_TOKEN to run it")
            return
        }
        let line = env["MAXPANE_REMOTE_LINE"] ?? "claude"
        let cwd = env["MAXPANE_REMOTE_CWD"]
        func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return cond()
        }
        let endpoint = RelayServer(baseURL: base, token: token)
        let registry = SessionRegistry(sources: [RemoteSessionSource(name: "live", endpoint: endpoint, pollInterval: 2)])
        defer { registry.stop() }
        #expect(await spin(20) { registry.serverStates["live"] == .connected }, "no list from \(base)")

        // 1. The spawn, exactly as ⌘O would ask for it.
        let typed = try #require(TypedCommand.parse(line))
        let spawner = RemoteSpawner(name: "live", endpoint: endpoint)
        var result: Result<SpawnedSession, Error>?
        let t0 = Date()
        spawner.spawn(cwd: cwd, typed: typed, cols: 100, rows: 40) { result = $0 }
        #expect(await spin(60) { result != nil })
        let spawned = try #require(try result?.get())
        print("live spawn: \(spawned.key) in \(spawned.cwd) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        defer { Self.kill(spawned.key.id, endpoint: endpoint) }

        // 2. BLOCKED, as the sidebar sees it.
        let blocked = await spin(45) { registry.sessions[spawned.key]?.state == .blocked }
        let seen = registry.sessions[spawned.key]
        print("live spawn: state \(seen.map { "\($0.state)" } ?? "none"), relay \(seen.map { "\($0.relayState)" } ?? "-"), title \(seen?.title ?? "-")")
        #expect(blocked, "the session never read blocked: \(seen.map { "\($0.state)" } ?? "not in the registry")")
        let rows = SidebarModel.rows(lanes: [], telemetry: registry.sessions, servers: registry.serverStates)
        let group = rows.compactMap { if case .group(let g) = $0, g.server == "live", !g.isServer { return g } else { return nil } }
            .first { $0.path == "live:\(spawned.cwd)" }
        #expect(group?.countText.hasSuffix("BLOCKED") == true, "the sidebar group says \(group?.countText ?? "nothing")")

        // 3. The lane: made beside nothing, closed, reattached from ⌘O's action.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-live-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(session: spawned.key, near: nil)
        let laneId = try #require(store.state.lanes.last?.id)
        store.observeCwd(laneId, spawned.cwd)
        #expect(store.state.lanes.last?.projectRoot == "live:\(spawned.cwd)")
        try store.closeLane(laneId)
        #expect(store.state.lanes.isEmpty)
        try store.attachSessionAtEnd(spawned.key)
        #expect(store.state.lanes.last?.panes.first?.sessionKey == spawned.key)

        // 4. Answer it over the WebSocket, as the pane would.
        let adapter = RelayAttachmentAdapter(sessionId: spawned.key.id, server: "live") { queue in
            WebSocketTransport(server: endpoint, sessionId: spawned.key.id, queue: queue)
        }
        var connected = false, output = [UInt8]()
        adapter.onConnectionChange = { connected = $0 }
        adapter.onData = { output += $0 }
        adapter.connect()
        defer { adapter.disconnect() }
        #expect(await spin(20) { connected })
        let before = output.count
        adapter.send(Array("y\r".utf8)[...])
        #expect(await spin(10) { output.count > before }, "the answer produced no output")
        print("live spawn: answered; \(output.count - before) B after y⏎")

        // 5. The control: the same program through the server's own exec
        // wrapper is the session leader and never BLOCKED.
        if let program = env["MAXPANE_REMOTE_EXEC_CONTROL"] {
            // Not through `RemoteSpawner`, which always sends the wrapper:
            // the body names the program as `command`, which is what the
            // relay-tty web app's form sends and what `exec` wraps.
            var request = URLRequest(url: base.appendingPathComponent("/api/sessions"))
            request.httpMethod = "POST"
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["command": program, "args": [], "cols": 100, "rows": 40]
            if let cwd { body["cwd"] = cwd }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let id = RemoteSpawner.session(in: data)?["id"] as? String {
                let key = SessionKey(server: "live", id: id)
                defer { Self.kill(key.id, endpoint: endpoint) }
                var seen: [String] = []
                let everBlocked = await spin(15) {
                    let now = registry.sessions[key].map { "\($0.state)" } ?? "none"
                    if seen.last != now { seen.append(now) }
                    return registry.sessions[key]?.state == .blocked
                }
                print("live spawn control (exec'd \(program)): states \(seen.joined(separator: " → ")), title \(registry.sessions[key]?.title ?? "-")")
                #expect(!everBlocked, "an exec'd agent read BLOCKED, which the wrapper exists to make possible")
            }
        }
    }

    /// `DELETE /api/sessions/:id`, so nothing is left running on the owner's box.
    private static func kill(_ id: String, endpoint: RelayServer) {
        var c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/api/sessions/\(id)"
        var request = URLRequest(url: c.url!)
        request.httpMethod = "DELETE"
        if let token = endpoint.token { request.setValue("session=\(token)", forHTTPHeaderField: "Cookie") }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            print("live spawn: DELETE \(id) → HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
    }
}

/// The control socket's doors for a remote server. The owner drives the app
/// over Relay TTY with the screen locked; a socket is the only hand he has.
@Suite("the CLI's remote doors")
struct RemoteCLIDoorTests {
    @Test("run with a server is its own request, and without one is the run it always was")
    func runOn() {
        guard case .runOn(let server, let command, let args)? = OpenServer.parse(
            #"{"op":"run","server":"yorkshire","command":"claude","args":["--model","sonnet"]}"#)
        else { Issue.record("not runOn"); return }
        #expect(server == "yorkshire" && command == "claude" && args == ["--model", "sonnet"])

        guard case .run(let local, _, _, _)? = OpenServer.parse(#"{"op":"run","server":"","command":"htop"}"#)
        else { Issue.record("an empty server is local"); return }
        #expect(local == "htop")
    }

    @Test("attach takes a bare id or a server and an id, and refuses no id")
    func attach() {
        guard case .attach(let server, let id)? = OpenServer.parse(#"{"op":"attach","server":"yorkshire","id":"0368d543"}"#)
        else { Issue.record("not attach"); return }
        #expect(server == "yorkshire" && id == "0368d543")

        guard case .attach(let none, let local)? = OpenServer.parse(#"{"op":"attach","server":"","id":"a7ab2d3b"}"#)
        else { Issue.record("not attach"); return }
        #expect(none == nil && local == "a7ab2d3b")

        #expect(OpenServer.parse(#"{"op":"attach","server":"yorkshire"}"#) == nil)
    }

    @Test("sessions is a request")
    func sessions() {
        guard case .listSessions? = OpenServer.parse(#"{"op":"sessions"}"#) else {
            Issue.record("not listSessions"); return
        }
    }
}
