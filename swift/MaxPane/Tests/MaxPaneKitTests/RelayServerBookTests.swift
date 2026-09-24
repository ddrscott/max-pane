import AppKit
import Foundation
import Testing
@testable import MaxPaneKit
@testable import RelayClient

// serial pass: a real loopback server, and spins measured against the wall
// clock. The whole suite runs in `scripts/test.sh`'s second, --no-parallel
// pass; see README, "The serial pass".

// MARK: - the pasted line

@Suite("the line pasted into Settings › Servers")
struct StartupLineTests {
    private func parse(_ s: String) -> RelayServerTokens.Parsed? { RelayServerTokens.parse(s) }

    @Test("the whole startup line, as the terminal printed it, is the base and the token")
    func wholeLine() throws {
        let raw = "  \u{1b}[2mAuth URL (1y):\u{1b}[0m \u{1b}[36mhttps://yourslug.relaytty.com/api/auth/callback?token=eyJhb.Ci0.sig-_x\u{1b}[0m\n"
        let p = try #require(parse(raw))
        #expect(p.base.absoluteString == "https://yourslug.relaytty.com")
        #expect(p.token == "eyJhb.Ci0.sig-_x")
        #expect(p.isCallback)
        #expect(p.host == "yourslug.relaytty.com")
    }

    @Test("a bare URL is a server with no token; a port and a path are kept out of the base")
    func bareURL() throws {
        let p = try #require(parse("http://localhost:44936"))
        #expect(p.base.absoluteString == "http://localhost:44936")
        #expect(p.token == nil)
        let q = try #require(parse("HTTPS://Box.Local:7680/some/where#frag"))
        #expect(q.base.absoluteString == "https://box.local:7680")
        #expect(q.path == "/some/where")
        #expect(!q.isCallback)
        #expect(q.token == nil)
    }

    @Test("trailing junk from the sentence it was copied out of comes off; text after a space is not the URL")
    func trailingJunk() throws {
        #expect(parse("(https://x.example/api/auth/callback?token=abc).")?.token == "abc")
        #expect(parse("https://x.example/?token=abc, then press enter")?.token == "abc")
        #expect(parse("https://x.example/?token=abc\"")?.base.absoluteString == "https://x.example")
        #expect(parse("$ open 'https://x.example/?token=abc'")?.token == "abc")
    }

    @Test("a URL on the wrong path is still that server, and says it is not the callback")
    func wrongPath() throws {
        let p = try #require(parse("https://yourslug.relaytty.com/sessions?token=abc"))
        #expect(p.base.absoluteString == "https://yourslug.relaytty.com")
        #expect(p.token == "abc")
        #expect(!p.isCallback)
    }

    @Test("no URL, no host, another scheme, or a token that is not one, is nothing")
    func refused() {
        #expect(parse("") == nil)
        #expect(parse("yorkshire") == nil)
        #expect(parse("ftp://x/?token=abc") == nil)
        #expect(parse("https:///?token=abc") == nil)
        #expect(parse("https://x/?token=") == nil)
        #expect(parse("https://x/?token=a%20b") == nil)
        #expect(parse("https://x/?token=a/b") == nil)
    }

    @Test("credentials in the URL never reach the base")
    func noUserInfo() {
        #expect(parse("https://user:pw@x.example/?token=abc")?.base.absoluteString == "https://x.example")
    }

    @Test("the default name is the host's first label, or the whole address")
    func defaultName() {
        func name(_ s: String) -> String { RelayServerTokens.defaultName(for: URL(string: s)!) }
        #expect(name("https://yourslug.relaytty.com") == "yourslug")
        #expect(name("http://localhost:44936") == "localhost")
        #expect(name("http://192.168.68.10:7680") == "192.168.68.10")
        #expect(name("http://Alien4090.lan") == "alien4090")
    }

    @Test("a relaytty.com host is a tunnel; anything else is direct")
    func tunnel() {
        #expect(RelayServerTokens.isTunnelled(URL(string: "https://yourslug.relaytty.com")!))
        #expect(RelayServerTokens.isTunnelled(URL(string: "https://RELAYTTY.com")!))
        #expect(!RelayServerTokens.isTunnelled(URL(string: "https://relaytty.com.evil.example")!))
        #expect(!RelayServerTokens.isTunnelled(URL(string: "http://192.168.68.10:7680")!))
    }
}

// MARK: - the file

@Suite("[[servers]] edits keep the rest of the file")
@MainActor
struct ServersFileTests {
    private func store(_ text: String) throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try text.write(to: path, atomically: true, encoding: .utf8)
        return (ConfigStore(path: path, watches: false), path)
    }

    static let file = """
        # my settings
        theme = "dark"   # at night

        # the home box, through its tunnel
        [[servers]]
        name = "yorkshire"     # the lane header's word
        url = "https://yourslug.relaytty.com"

        [[servers]]
        name = "alien"
        url = "http://192.168.68.10:7680"
        enabled = false

        [keys]
        closePane = []

        """

    @Test("enable, rename and remove touch their own lines and nothing else")
    func roundTrip() throws {
        let (store, path) = try store(Self.file)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        store.setServerEnabled(named: "yorkshire", false)
        var text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("url = \"https://yourslug.relaytty.com\"\nenabled = false\n\n[[servers]]"), Comment(rawValue: text))
        #expect(store.config.servers[0].enabled == false)

        store.setServerEnabled(named: "alien", true)
        text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("url = \"http://192.168.68.10:7680\"\nenabled = true\n"), Comment(rawValue: text))

        #expect(store.renameServer(from: "yorkshire", to: "york"))
        #expect(!store.renameServer(from: "york", to: "alien"), "renamed onto a name in use")
        #expect(!store.renameServer(from: "nobody", to: "x"))
        text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("name = \"york\"     # the lane header's word\n"), Comment(rawValue: text))
        #expect(store.config.servers.map(\.name) == ["york", "alien"])

        store.removeServer(named: "york")
        text = try String(contentsOf: path, encoding: .utf8)
        // The comment above the removed table stays, as `remove` keeps a
        // comment above a key: it may be about more than the one element.
        #expect(text == """
            # my settings
            theme = "dark"   # at night

            # the home box, through its tunnel

            [[servers]]
            name = "alien"
            url = "http://192.168.68.10:7680"
            enabled = true

            [keys]
            closePane = []

            """, Comment(rawValue: text))
        #expect(store.config.servers.map(\.name) == ["alien"])
        #expect(store.config.theme == .dark)
        #expect(store.isSet(Command.closePane))
    }
}

// MARK: - the book, live

/// The whole path from a pasted line to sessions in the registry and back
/// out, against the fake relay server: add, refuse, paste a token, disable,
/// rename, remove, and a hand edit of the file through `ConfigWatch`. The
/// tokens go to a dictionary, not the login keychain (see `PasswordTests`
/// for why), through the store seam the app fills with the Keychain.
@Suite("the server book, against a fake relay server", .serialized)
@MainActor
struct RelayServerBookTests {
    private func spin(until cond: () -> Bool, _ seconds: TimeInterval = 6) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    private struct Fixture {
        let dir: URL
        let path: URL
        let store: ConfigStore
        let registry: SessionRegistry
        let servers: RelayServers
        let book: RelayServerBook
        let box: RelayServerTokens.TokenBox
    }

    private func fixture(watches: Bool = false) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try "theme = \"dark\"\n".write(to: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path, watches: watches)
        let box = RelayServerTokens.TokenBox()
        RelayServerTokens.store = .memory(box)
        let registry = SessionRegistry(sources: [])
        let servers = RelayServers(entries: store.config.enabledServers)
        let book = RelayServerBook(servers: servers, registry: registry, store: store, pollInterval: 60)
        return Fixture(dir: dir, path: path, store: store, registry: registry, servers: servers, book: book, box: box)
    }

    private func tearDown(_ f: Fixture) {
        f.registry.stop()
        RelayServerTokens.store = .keychain
        try? FileManager.default.removeItem(at: f.dir)
    }

    private func origin(_ server: FakeRelayServer) -> PasswordOrigin { PasswordOrigin(url: server.baseURL)! }

    @Test("add: the token goes to the store, the table to the file, the source to the registry, and the count comes back")
    func addConnects() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543", agentState: "blocked"), FakeRelayServer.session("deadbeef")]
        let f = try fixture()
        defer { tearDown(f) }
        var changed: [String] = []
        f.book.onServerChanged = { changed.append($0) }

        let result = f.book.add(pasted: "Auth URL (1y): http://127.0.0.1:\(server.port)/api/auth/callback?token=t0k3n\n", name: "")
        guard case .success(let entry) = result else { Issue.record("add refused: \(result)"); return }
        #expect(entry.name == "127.0.0.1")
        #expect(entry.url == "http://127.0.0.1:\(server.port)")
        #expect(f.box.values[origin(server)] == "t0k3n")
        let text = try String(contentsOf: f.path, encoding: .utf8)
        #expect(!text.contains("t0k3n"), "the token reached the file")
        #expect(text.contains("[[servers]]\nname = \"127.0.0.1\""))
        #expect(f.servers.names == ["127.0.0.1"])
        #expect(f.servers.hasToken["127.0.0.1"] == true)
        #expect(f.registry.remoteServers == ["127.0.0.1"])
        #expect(changed == ["127.0.0.1"])

        #expect(await spin(until: { f.registry.serverStates["127.0.0.1"] == .connected }))
        #expect(await spin(until: { f.registry.sessionCount(server: "127.0.0.1") == 2 }))
        let status = f.book.status(of: entry)
        #expect(status.kind == .connected)
        #expect(status.sessions == 2)
        #expect(status.detail == nil)
        #expect(!status.isTunnelled)
        #expect(f.registry.blockedCount == 1, "BLOCKED counts include remote sessions")
        // The fake answers 200 only to the right cookie, so the count is the
        // proof the token went out.

        // The same name twice is refused before anything is written.
        guard case .failure(let why) = f.book.add(pasted: "http://127.0.0.1:1", name: "127.0.0.1") else {
            Issue.record("a duplicate name was accepted"); return
        }
        #expect(why.text.contains("already named 127.0.0.1"))
        #expect(f.book.entries.count == 1)
        // And a line with no URL in it.
        guard case .failure(let junk) = f.book.add(pasted: "not a url", name: "x") else {
            Issue.record("junk was accepted"); return
        }
        #expect(junk.text.contains("Auth URL"))
    }

    @Test("a refused token is one line with what to do; pasting a token restarts the source under the same name")
    func refusedThenPasted() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543")]
        let f = try fixture()
        defer { tearDown(f) }

        f.book.add(pasted: "http://127.0.0.1:\(server.port)/api/auth/callback?token=wrong", name: "box")
        #expect(await spin(until: { f.registry.serverStates["box"] == .refused }))
        let entry = f.book.entries[0]
        var status = f.book.status(of: entry)
        #expect(status.kind == .refused)
        #expect(status.word == "refused")
        #expect(status.detail == "token refused — paste the Auth URL from the server's startup output")
        #expect(f.registry.sessionCount(server: "box") == 0, "a refused server contributes sessions")

        // Wrong host: refused, nothing stored.
        #expect(f.book.pasteToken("box", pasted: "http://other.example/?token=t0k3n")?.contains("other.example") == true)
        #expect(f.box.values[origin(server)] == "wrong")
        // No token in the line.
        #expect(f.book.pasteToken("box", pasted: "http://127.0.0.1:\(server.port)") != nil)

        #expect(f.book.pasteToken("box", pasted: "http://127.0.0.1:\(server.port)/api/auth/callback?token=t0k3n") == nil)
        #expect(f.box.values[origin(server)] == "t0k3n")
        #expect(await spin(until: { f.registry.serverStates["box"] == .connected }))
        #expect(await spin(until: { f.registry.sessionCount(server: "box") == 1 }))
        status = f.book.status(of: entry)
        #expect(status.kind == .connected)
        #expect(status.sessions == 1)
    }

    @Test("a server with no token says so and offers paste; an unreachable one names the host")
    func noTokenAndUnreachable() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        let f = try fixture()
        defer { tearDown(f) }

        f.book.add(pasted: "http://127.0.0.1:\(server.port)", name: "bare")
        #expect(f.servers.hasToken["bare"] == false)
        #expect(await spin(until: { f.registry.serverStates["bare"] == .refused }))
        let bare = f.book.status(of: f.book.entries[0])
        #expect(bare.kind == .noToken)
        #expect(bare.word == "no token")
        #expect(bare.detail?.hasPrefix("no token") == true)

        // Port 1 on loopback: refused at once, no server there.
        f.book.add(pasted: "http://127.0.0.1:1/?token=abc", name: "nobody")
        #expect(await spin(until: { f.registry.serverErrors["nobody"] != nil }))
        let down = f.book.status(of: f.book.entries[1])
        #expect(down.kind == .reconnecting)
        #expect(down.detail?.hasPrefix("unreachable — 127.0.0.1:") == true, Comment(rawValue: down.detail ?? "nil"))
    }

    @Test("disable stops the source and hides the server; enable brings it back; rename keeps its sessions and tells the ledger")
    func disableEnableRename() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543")]
        let f = try fixture()
        defer { tearDown(f) }
        var changed: [String] = []
        f.book.onServerChanged = { changed.append($0) }

        f.book.add(pasted: "http://127.0.0.1:\(server.port)/?token=t0k3n", name: "yorkshire")
        #expect(await spin(until: { f.registry.sessionCount(server: "yorkshire") == 1 }))
        let clients = server.eventClients

        f.book.setEnabled("yorkshire", false)
        #expect(f.registry.remoteServers.isEmpty)
        #expect(f.registry.serverStates["yorkshire"] == nil)
        #expect(f.registry.sessionCount(server: "yorkshire") == 0, "a disabled server's sessions stayed")
        #expect(f.book.status(of: f.book.entries[0]).kind == .disabled)
        #expect(f.servers.names.isEmpty)
        #expect(changed == ["yorkshire", "yorkshire"])
        #expect(server.waitUntil { server.eventClients < clients }, "the events socket stayed open")
        // Not shown in the sidebar at all.
        let hidden = SidebarModel.rows(lanes: [], telemetry: f.registry.sessions, servers: f.registry.serverStates)
        #expect(hidden.isEmpty)

        f.book.setEnabled("yorkshire", true)
        #expect(f.registry.remoteServers == ["yorkshire"])
        #expect(await spin(until: { f.registry.sessionCount(server: "yorkshire") == 1 }))

        var ledger: [(String, String)] = []
        #expect(f.book.rename("yorkshire", to: "york", ledger: { ledger.append(($0, $1)) }) == nil)
        #expect(ledger.map { "\($0.0)→\($0.1)" } == ["yorkshire→york"])
        #expect(f.book.entries.map(\.name) == ["york"])
        #expect(f.registry.remoteServers == ["york"])
        #expect(f.registry.serverStates["yorkshire"] == nil)
        #expect(await spin(until: { f.registry.sessionCount(server: "york") == 1 }))
        #expect(f.registry.sessions.keys.contains(SessionKey(server: "york", id: "0368d543")))
        #expect(f.box.values[origin(server)] == "t0k3n", "the token is keyed on the host, not the name")
        #expect(f.book.rename("york", to: "a/b", ledger: nil)?.contains("':' or '/'") == true)
        #expect(f.book.rename("york", to: "york", ledger: nil) == nil)
        #expect(f.book.rename("gone", to: "x", ledger: nil) == "no server named gone")
    }

    @Test("remove takes the table, the token and the source; a second server on the same host keeps the token")
    func remove() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        let f = try fixture()
        defer { tearDown(f) }

        f.book.add(pasted: "http://127.0.0.1:\(server.port)/?token=t0k3n", name: "one")
        f.book.add(pasted: "http://127.0.0.1:\(server.port)", name: "two")
        #expect(f.registry.remoteServers == ["one", "two"])

        f.book.remove("one")
        #expect(f.box.values[origin(server)] == "t0k3n", "removing one of two servers on a host dropped the shared token")
        #expect(f.book.entries.map(\.name) == ["two"])
        #expect(f.registry.remoteServers == ["two"])

        f.book.remove("two")
        #expect(f.box.values.isEmpty)
        #expect(f.book.entries.isEmpty)
        #expect(f.registry.remoteServers.isEmpty)
        #expect(f.registry.serverStates.isEmpty)
        let text = try String(contentsOf: f.path, encoding: .utf8)
        #expect(text == "theme = \"dark\"\n", Comment(rawValue: text))
        f.book.remove("nobody")
    }

    @Test("a hand edit of config.toml reaches the registry through ConfigWatch")
    func handEdit() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543")]
        let f = try fixture(watches: true)
        defer { tearDown(f) }
        _ = RelayServerTokens.save("t0k3n", for: server.baseURL)

        try """
            theme = "dark"

            [[servers]]
            name = "typed"
            url = "http://127.0.0.1:\(server.port)"

            """.write(to: f.path, atomically: true, encoding: .utf8)
        #expect(await spin(until: { f.registry.remoteServers == ["typed"] }))
        #expect(await spin(until: { f.registry.sessionCount(server: "typed") == 1 }))

        try "theme = \"dark\"\n".write(to: f.path, atomically: true, encoding: .utf8)
        #expect(await spin(until: { f.registry.remoteServers.isEmpty }))
        #expect(f.registry.sessionCount(server: "typed") == 0)
    }

    @Test("a source that changes nothing is not restarted by an unrelated setting")
    func unrelatedEdit() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        let f = try fixture()
        defer { tearDown(f) }
        f.book.add(pasted: "http://127.0.0.1:\(server.port)/?token=t0k3n", name: "box")
        #expect(await spin(until: { f.registry.serverStates["box"] == .connected }))
        let before = f.servers.endpoints["box"]
        var changed: [String] = []
        f.book.onServerChanged = { changed.append($0) }
        f.store.set(ConfigField.all.first { $0.key == "theme" }!, to: .string("light"))
        #expect(changed.isEmpty)
        #expect(f.servers.endpoints["box"] == before)
        #expect(f.registry.serverStates["box"] == .connected)
    }
}

// MARK: - the sidebar

@Suite("the sidebar's server headers")
struct SidebarServerHeaderTests {
    @Test("a refused server is a header with the state and no rows; a disabled one is nothing")
    func refusedHeader() {
        let rows = SidebarModel.rows(lanes: [], telemetry: [:], servers: ["yorkshire": .refused])
        // `// LOCAL` heads this Mac's block once there is a server beside it.
        #expect(rows.count == 2)
        guard case .group(let local) = rows[0], case .group(let g) = rows[1] else { Issue.record("not groups"); return }
        #expect(local.isLocalSection && local.header == "LOCAL")
        #expect(g.isServer)
        #expect(g.header == "YORKSHIRE")
        #expect(g.stateChip == "TOKEN REFUSED")
        #expect(g.countText == "0 SESSIONS")
        #expect(g.serverIsOff)
        #expect(g.total == 0)
        #expect(SidebarModel.rows(lanes: [], telemetry: [:], servers: [:]).isEmpty)
    }

    @Test("a connected server's header counts its sessions across its projects, blocked first")
    func connectedHeader() {
        func t(_ id: String, _ cwd: String, _ state: AgentState) -> SessionTelemetry {
            SessionTelemetry(
                sessionId: id, server: "yorkshire", title: "", cwd: cwd, command: "claude",
                state: state, lastActivity: Date())
        }
        let telemetry: [SessionKey: SessionTelemetry] = [
            SessionKey(server: "yorkshire", id: "a"): t("a", "/home/a", .idle),
            SessionKey(server: "yorkshire", id: "b"): t("b", "/home/b", .idle),
        ]
        var rows = SidebarModel.rows(lanes: [], telemetry: telemetry, servers: ["yorkshire": .connected])
        var groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        #expect(groups.map(\.path) == [SidebarModel.localSection, "yorkshire:", "yorkshire:/home/a", "yorkshire:/home/b"])
        groups.removeFirst()
        #expect(groups[0].countText == "2 SESSIONS")
        #expect(groups[0].stateChip == nil)
        #expect(!groups[0].serverIsOff)

        let blocked = telemetry.merging([SessionKey(server: "yorkshire", id: "c"): t("c", "/home/a", .blocked)]) { $1 }
        rows = SidebarModel.rows(lanes: [], telemetry: blocked, servers: ["yorkshire": .connected])
        groups = rows.compactMap { if case .group(let g) = $0, !g.isLocalSection { return g } else { return nil } }
        #expect(groups[0].countText == "1 BLOCKED")
        #expect(groups[0].blocked == 1)
    }
}

// MARK: - Settings › Servers

/// The section in the window: one row per server whatever its state, each
/// fitting the content column, the words the spec asks for, and the tunnel
/// notice on a relaytty.com row. The sheet for a human is behind
/// `MAXPANE_SHOTS`; the layout holds in the default run.
@Suite("Settings › Servers", .serialized)
@MainActor
struct SettingsServersTests {
    private func spin(until cond: () -> Bool, _ seconds: TimeInterval = 6) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    /// A store over a file naming four servers: one the fake answers, one it
    /// refuses, one switched off, and — only when `tunnel` — one through
    /// relaytty.com with no token, for the notice. The tunnelled row is
    /// left out of the default run because its source would ask the network.
    private func book(_ server: FakeRelayServer, tunnel: Bool) throws -> (RelayServerBook, URL, RelayServerTokens.TokenBox) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-settings-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        var text = """
            theme = "dark"

            [[servers]]
            name = "yorkshire"
            url = "http://127.0.0.1:\(server.port)"

            [[servers]]
            name = "alien"
            url = "http://localhost:\(server.port)"

            [[servers]]
            name = "attic"
            url = "http://192.168.68.99:7680"
            enabled = false

            """
        if tunnel {
            text += "\n[[servers]]\nname = \"travel\"\nurl = \"https://nobody.relaytty.com\"\n"
        }
        try text.write(to: path, atomically: true, encoding: .utf8)
        let box = RelayServerTokens.TokenBox()
        RelayServerTokens.store = .memory(box)
        // yorkshire has the right token; alien, on the same fake by another
        // host name, has a wrong one.
        _ = RelayServerTokens.save("t0k3n", for: URL(string: "http://127.0.0.1:\(server.port)")!)
        _ = RelayServerTokens.save("wrong", for: URL(string: "http://localhost:\(server.port)")!)
        let store = ConfigStore(path: path, watches: false)
        let registry = SessionRegistry(sources: [])
        let servers = RelayServers(entries: [])
        let book = RelayServerBook(servers: servers, registry: registry, store: store, pollInterval: 60)
        book.reconcile()
        return (book, dir, box)
    }

    @Test("every row fits the column, and says connected · N, refused, or disabled")
    func layout() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543"), FakeRelayServer.session("4f2a0000")]
        let (book, dir, _) = try book(server, tunnel: false)
        defer {
            book.registry.stop()
            RelayServerTokens.store = .keychain
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(await spin(until: { book.registry.serverStates["yorkshire"] == .connected && book.registry.serverStates["alien"] == .refused }))
        #expect(await spin(until: { book.registry.sessionCount(server: "yorkshire") == 2 }))

        let popup = SettingsWindow(store: book.store, servers: book) { _ in }
        let panel = try #require(popup.window)
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let sections = try #require(scroll.documentView?.subviews.first)
        #expect(sections.fittingSize.width <= scroll.contentView.bounds.width, "a server row is wider than the window")
        let section = try #require(sections.subviews.compactMap { $0 as? ServersSection }.first)
        let rows = section.subviews.compactMap { $0 as? NSStackView }.flatMap { $0.arrangedSubviews.compactMap { $0 as? ServerRow } }
        #expect(rows.count == 3)
        let words = rows.map { $0.stateWord }
        #expect(words == ["connected · 2 sessions", "refused", "disabled"], Comment(rawValue: words.description))
        #expect(rows[1].detailText == "$ token refused — paste the Auth URL from the server's startup output")
        #expect(rows[0].detailText == nil)
        #expect(rows.allSatisfy { !$0.showsTunnelNotice })
        #expect(rows[1].offersPaste && !rows[0].offersPaste && !rows[2].offersPaste)
        #expect(book.entries.map(\.name) == ["yorkshire", "alien", "attic"])

        // A removed server's row goes; the others keep their objects.
        let kept = rows[0]
        book.remove("alien")
        let after = section.subviews.compactMap { $0 as? NSStackView }.flatMap { $0.arrangedSubviews.compactMap { $0 as? ServerRow } }
        #expect(after.map(\.currentName) == ["yorkshire", "attic"])
        #expect(after.first === kept)
        popup.reveal(.servers, animated: false)
        popup.mark(server: "yorkshire")
    }

    @Test("renders Settings › Servers, with the tunnel notice")
    func renderSheet() async throws {
        guard let shots = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED: set MAXPANE_SHOTS=<dir> to render Settings › Servers")
            return
        }
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543", agentState: "blocked"), FakeRelayServer.session("4f2a0000")]
        let (book, dir, _) = try book(server, tunnel: true)
        defer {
            book.registry.stop()
            RelayServerTokens.store = .keychain
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(await spin(until: { book.registry.serverStates["yorkshire"] == .connected && book.registry.serverStates["alien"] == .refused }))
        var open: [Popup] = []
        try AppearanceSheet.render(to: shots, named: "settings-servers") {
            let popup = SettingsWindow(store: book.store, servers: book) { _ in }
            open.append(popup)
            let content = try #require(popup.window?.contentView)
            content.layoutSubtreeIfNeeded()
            popup.reveal(.servers, animated: false)
            popup.mark(server: "alien")
            return content
        }
    }
}

/// The sidebar with two servers in it: one connected with a blocked agent
/// under a project, one refused with no rows, above and among the local
/// groups. A picture, for a human. Gated on `MAXPANE_SHOTS`.
@Suite("sidebar server header rendering")
@MainActor
struct SidebarServerRenderTests {
    @Test("renders the sidebar with server headers")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED: set MAXPANE_SHOTS=<dir> to render the sidebar's server headers")
            return
        }
        func t(_ id: String, _ server: String?, _ cwd: String, _ state: AgentState, _ title: String) -> SessionTelemetry {
            SessionTelemetry(
                sessionId: id, server: server, title: title, cwd: cwd, command: "claude",
                state: state, bytesPerSecond: state == .working ? 640 : 0, lastActivity: Date().addingTimeInterval(-40))
        }
        let telemetry: [SessionKey: SessionTelemetry] = [
            "0368d543": t("0368d543", nil, NSHomeDirectory() + "/code/max-pane", .working, "◐ Editing SidebarModel.swift"),
            SessionKey(server: "yorkshire", id: "0368d543"): t("0368d543", "yorkshire", "/home/spierce/m7out", .blocked, "Waiting on permission"),
            SessionKey(server: "yorkshire", id: "4f2a0000"): t("4f2a0000", "yorkshire", "/home/spierce", .idle, "bash"),
        ]
        let rows = SidebarModel.rows(
            lanes: [], telemetry: telemetry, servers: ["yorkshire": .connected, "attic": .refused])
        let heights = rows.map { row -> CGFloat in
            if case .group = row { return SidebarGroupView.height }
            return SidebarEntryView.height
        }
        try AppearanceSheet.render(to: dir, named: "sidebar-servers") {
            let width: CGFloat = 290
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

/// The Phase 2 path against a real relay-tty server through its tunnel:
/// the pasted startup line, a refused token, the paste that lifts it, and
/// the tunnel notice. Gated on `MAXPANE_REMOTE_VERIFY` (the base URL) and
/// `MAXPANE_REMOTE_TOKEN`, read at run time and never printed; the token
/// store is a dictionary, so the login keychain is untouched.
@Suite("the server book against the real server, when MAXPANE_REMOTE_VERIFY names it", .serialized)
@MainActor
struct LiveServerBookTests {
    @Test("paste the line, see the count; a wrong token is refused and a pasted one connects")
    func liveBook() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MAXPANE_REMOTE_VERIFY"], let token = env["MAXPANE_REMOTE_TOKEN"], !token.isEmpty else {
            print("SKIPPED live server book check — set MAXPANE_REMOTE_VERIFY=<base url> and MAXPANE_REMOTE_TOKEN to run it")
            return
        }
        func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return cond()
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-live-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try "".write(to: path, atomically: true, encoding: .utf8)
        let box = RelayServerTokens.TokenBox()
        RelayServerTokens.store = .memory(box)
        let store = ConfigStore(path: path, watches: false)
        let registry = SessionRegistry(sources: [])
        let book = RelayServerBook(servers: RelayServers(entries: []), registry: registry, store: store, pollInterval: 60)
        defer {
            registry.stop()
            RelayServerTokens.store = .keychain
            try? FileManager.default.removeItem(at: dir)
        }

        // Wrong token first, as the terminal would print it.
        let wrong = "Auth URL (1y): \(base)/api/auth/callback?token=\(String(token.dropLast(3)))xyz\n"
        guard case .success(let entry) = book.add(pasted: wrong, name: "") else { Issue.record("add refused"); return }
        #expect(entry.url == base)
        #expect(await spin(20) { registry.serverStates[entry.name] == .refused })
        var status = book.status(of: entry)
        #expect(status.kind == .refused)
        #expect(status.detail == "token refused — paste the Auth URL from the server's startup output")
        #expect(status.isTunnelled == RelayServerTokens.isTunnelled(URL(string: base)!))
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains(token.suffix(20)), "the token reached the file")

        // The right one, pasted on the row.
        #expect(book.pasteToken(entry.name, pasted: "\(base)/api/auth/callback?token=\(token)") == nil)
        #expect(await spin(20) { registry.serverStates[entry.name] == .connected })
        #expect(await spin(20) { registry.sessionCount(server: entry.name) > 0 })
        status = book.status(of: entry)
        #expect(status.kind == .connected)
        print("live server book: \(entry.name) connected with \(status.sessions) session(s), tunnelled=\(status.isTunnelled)")

        // The sidebar carries the header and the sessions under it.
        let rows = SidebarModel.rows(lanes: [], telemetry: registry.sessions, servers: registry.serverStates)
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        #expect(groups.first?.isServer == true)
        #expect(groups.first?.countText.hasSuffix("SESSION") == true || groups.first?.countText.hasSuffix("SESSIONS") == true || groups.first?.countText.hasSuffix("BLOCKED") == true)

        book.remove(entry.name)
        #expect(registry.remoteServers.isEmpty)
        #expect(box.values.isEmpty)
    }
}
