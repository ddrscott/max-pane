import CryptoKit
import Foundation
import LanedCore
import Network
import Testing
@testable import MaxPaneKit
@testable import RelayClient

// serial pass: a real loopback server, and waits measured against the wall
// clock. The whole suite runs in `scripts/test.sh`'s second, --no-parallel
// pass; see README, "The serial pass".

// MARK: - a fake relay-tty server, HTTP and WebSocket on one loopback port

/// Enough of relay-tty's server to exercise `RemoteSessionSource`: `GET
/// /api/sessions` answering JSON, a `/ws/events` upgrade done by hand, and
/// the cookie check both do. Raw TCP, because one port has to answer both
/// an HTTP request and an upgrade, which `NWProtocolWebSocket` on a listener
/// cannot.
final class FakeRelayServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "fake.relay.http")
    private let lock = NSLock()
    private var events: [NWConnection] = []
    private var requests: [String] = []
    var token = "t0k3n"
    /// What `/api/sessions` answers with, as the JSON rows.
    var sessions: [[String: Any]] = []
    /// Every `POST /api/sessions` body, decoded, in order.
    private var posted: [[String: Any]] = []
    /// Every id a `DELETE /api/sessions/:id` removed, in order.
    private var deleted: [String] = []
    var deletedIds: [String] { lock.lock(); defer { lock.unlock() }; return deleted }
    var spawnBodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return posted }
    /// The home the fake server starts a session in when the body names no
    /// `cwd` — what relay-tty does with `process.env.HOME`.
    var home = "/home/fake"
    /// Answer every spawn with this status and `{"error": …}` instead of 201.
    var spawnRefusal: (status: Int, error: String)?
    /// Every `POST /api/upload`, in order: the name the client sent, the name
    /// it was stored under, and the bytes.
    private var uploaded: [(sent: String, stored: String, body: Data)] = []
    var uploads: [(sent: String, stored: String, body: Data)] { lock.lock(); defer { lock.unlock() }; return uploaded }
    /// Where the fake server "writes" an upload: relay-tty's default,
    /// `~/.relay-tty/uploads`, under `home`.
    var uploadDir: String { "\(home)/.relay-tty/uploads" }
    /// Answer every upload with this status and `{"error": …}` instead of 200.
    var uploadRefusal: (status: Int, error: String)?
    /// How long to sit on an upload before answering it.
    var uploadDelay: TimeInterval = 0
    /// The id the next spawn gets.
    var nextSpawnId = "5eed0001"
    /// Whether the server checks the cookie at all (LAN-direct does; a
    /// tunnel does not, for the WebSocket).
    var requiresCookie = true
    /// The tunnel's usual death: the TCP connection is accepted and nothing
    /// is ever said on it — no response to a request, no pong to a ping.
    var silent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _silent }
        set { lock.lock(); _silent = newValue; lock.unlock() }
    }
    private var _silent = false
    /// How long to sit on the next `GET /api/sessions` before answering it,
    /// once each: a slow response, not a dead server.
    var listDelays: [TimeInterval] {
        get { lock.lock(); defer { lock.unlock() }; return _delays }
        set { lock.lock(); _delays = newValue; lock.unlock() }
    }
    private var _delays: [TimeInterval] = []
    /// Accepted connections nobody answered, held so they stay open.
    private var parked: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port!.rawValue
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var requestLines: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    var eventClients: Int { lock.lock(); defer { lock.unlock() }; return events.count }

    func stop() {
        listener.cancel()
        lock.lock(); let cs = events + parked; events = []; parked = []; lock.unlock()
        for c in cs { c.cancel() }
    }

    func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn, buffered: Data())
    }

    private func readHead(_ conn: NWConnection, buffered: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { return }
            var buf = buffered
            buf.append(data)
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                // A POST carries a body: read to Content-Length before answering.
                let wanted = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[range.upperBound...]
                if body.count >= wanted {
                    self.handle(conn, head: head, body: Data(body.prefix(wanted)))
                } else {
                    self.readBody(conn, head: head, wanted: wanted, buffered: Data(body))
                }
            } else if !done {
                self.readHead(conn, buffered: buf)
            }
        }
    }

    private func readBody(_ conn: NWConnection, head: String, wanted: Int, buffered: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { return }
            var buf = buffered
            buf.append(data)
            if buf.count >= wanted {
                self.handle(conn, head: head, body: Data(buf.prefix(wanted)))
            } else if !done {
                self.readBody(conn, head: head, wanted: wanted, buffered: buf)
            }
        }
    }

    private func handle(_ conn: NWConnection, head: String, body: Data = Data()) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        lock.lock(); requests.append(requestLine); lock.unlock()
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if silent {
            lock.lock(); parked.append(conn); lock.unlock()
            return
        }
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let authorised = !requiresCookie || headers["cookie"] == "session=\(token)"
        let isUpgrade = headers["upgrade"]?.lowercased() == "websocket"

        guard authorised else {
            respond(conn, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        if isUpgrade, path.hasPrefix("/ws/events") {
            let key = headers["sec-websocket-key"] ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            lock.lock(); events.append(conn); lock.unlock()
            drainFrames(conn)
            return
        }
        let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
        if method == "POST", path == "/api/sessions" {
            let request = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            lock.lock(); posted.append(request); lock.unlock()
            if let refusal = spawnRefusal {
                let out = try! JSONSerialization.data(withJSONObject: ["error": refusal.error])
                respond(conn, "HTTP/1.1 \(refusal.status) Nope\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
                return
            }
            // What relay-tty does: `$SHELL` resolved, no cwd means HOME, a
            // session row in `pending` until pty-host writes its file.
            let command = (request["command"] as? String) == "$SHELL" ? "/usr/bin/zsh" : (request["command"] as? String ?? "")
            let session = Self.session(
                nextSpawnId, cwd: request["cwd"] as? String ?? home, command: command,
                args: request["args"] as? [String] ?? [],
                cols: request["cols"] as? Int ?? 80, rows: request["rows"] as? Int ?? 24)
            lock.lock(); sessions.append(session); lock.unlock()
            let out = try! JSONSerialization.data(withJSONObject: ["session": session, "url": "\(baseURL)/sessions/\(nextSpawnId)"])
            respond(conn, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
            return
        }
        if method == "POST", path == "/api/upload" {
            // relay-tty's `router.post("/upload")`: the name from X-Filename,
            // basename only; a name already there gets a suffix; the answer
            // is the absolute path it was written to.
            func answer(_ status: String, _ object: [String: Any]) {
                let out = try! JSONSerialization.data(withJSONObject: object)
                queue.asyncAfter(deadline: .now() + uploadDelay) { [weak self] in
                    self?.respond(conn, "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
                }
            }
            if let refusal = uploadRefusal {
                answer("\(refusal.status) Nope", ["error": refusal.error])
                return
            }
            guard let sent = headers["x-filename"], !sent.isEmpty else {
                answer("400 Bad Request", ["error": "X-Filename header required"])
                return
            }
            let safe = (sent as NSString).lastPathComponent
            lock.lock()
            var stored = safe
            if uploaded.contains(where: { $0.stored == stored }) {
                let ext = (safe as NSString).pathExtension
                stored = "\((safe as NSString).deletingPathExtension)-\(String(format: "%06x", uploaded.count))" + (ext.isEmpty ? "" : ".\(ext)")
            }
            uploaded.append((sent: sent, stored: stored, body: body))
            lock.unlock()
            answer("200 OK", ["ok": true, "path": "\(uploadDir)/\(stored)", "name": stored, "size": body.count])
            return
        }
        if method == "DELETE", path.hasPrefix("/api/sessions/") {
            // relay-tty's `router.delete("/sessions/:id")`: owner only (the
            // cookie check above), 404 for an id it does not hold, else the
            // pty-host is SIGTERMed and the row dropped, `{"ok": true}`.
            let id = String(path.dropFirst("/api/sessions/".count))
            lock.lock()
            let index = sessions.firstIndex { ($0["id"] as? String) == id }
            if let index { sessions.remove(at: index); deleted.append(id) }
            lock.unlock()
            guard index != nil else {
                let out = Data("{\"error\":\"Session not found\"}".utf8)
                respond(conn, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
                return
            }
            let out = Data("{\"ok\":true}".utf8)
            respond(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
            return
        }
        if method == "GET", path.hasPrefix("/api/sessions/") {
            let id = String(path.dropFirst("/api/sessions/".count).prefix { $0 != "?" })
            lock.lock(); let found = sessions.first { ($0["id"] as? String) == id }; lock.unlock()
            guard let found else {
                let out = Data("{\"error\":\"Session not found\"}".utf8)
                respond(conn, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
                return
            }
            let out = try! JSONSerialization.data(withJSONObject: ["session": found])
            respond(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n", out)
            return
        }
        if path.hasPrefix("/api/sessions") {
            lock.lock()
            let rows = sessions
            let delay = _delays.isEmpty ? 0 : _delays.removeFirst()
            lock.unlock()
            let body = try! JSONSerialization.data(withJSONObject: ["sessions": rows])
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.respond(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n", body)
            }
            return
        }
        respond(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    private func respond(_ conn: NWConnection, _ head: String, _ body: Data = Data()) {
        var out = Data(head.utf8)
        out.append(body)
        // A FIN after the bytes, not a cancel: a cancel can RST the socket
        // before the client has read the response.
        conn.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Read and discard the client's frames (it sends none but pings and a
    /// close), so the connection stays alive.
    ///
    /// A protocol ping (opcode 9) gets its pong (opcode 10) with the same
    /// payload, as any WebSocket server's does — unless the server has gone
    /// `silent`, which is the point of that.
    private func drainFrames(_ conn: NWConnection, buffered: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, error == nil, !done else {
                self?.lock.lock(); self?.events.removeAll { $0 === conn }; self?.lock.unlock()
                return
            }
            var buf = buffered
            if let data { buf.append(data) }
            // Client frames are masked: [fin|opcode][mask|len][ext len][key x4][payload].
            while buf.count >= 2 {
                let bytes = [UInt8](buf)
                let opcode = bytes[0] & 0x0f
                var length = Int(bytes[1] & 0x7f)
                var at = 2
                if length == 126 {
                    guard bytes.count >= 4 else { break }
                    length = Int(bytes[2]) << 8 | Int(bytes[3]); at = 4
                } else if length == 127 {
                    break   // nothing the client sends here is that long
                }
                let masked = bytes[1] & 0x80 != 0
                let total = at + (masked ? 4 : 0) + length
                guard bytes.count >= total else { break }
                var payload = Array(bytes[(at + (masked ? 4 : 0))..<total])
                if masked {
                    let key = Array(bytes[at..<at + 4])
                    for i in payload.indices { payload[i] ^= key[i % 4] }
                }
                if opcode == 9, !self.silent {
                    conn.send(content: self.frame(opcode: 10, Data(payload)), completion: .contentProcessed { _ in })
                }
                buf = Data(bytes[total...])
            }
            self.drainFrames(conn, buffered: buf)
        }
    }

    /// One unmasked server frame to every `/ws/events` client.
    private func frame(opcode: UInt8, _ payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else {
            out.append(126)
            out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xff))
        }
        out.append(payload)
        return out
    }

    func sendText(_ text: String) {
        lock.lock(); let cs = events; lock.unlock()
        for c in cs { c.send(content: frame(opcode: 1, Data(text.utf8)), completion: .contentProcessed { _ in }) }
    }

    func sendBinary(_ bytes: [UInt8]) {
        lock.lock(); let cs = events; lock.unlock()
        for c in cs { c.send(content: frame(opcode: 2, Data(bytes)), completion: .contentProcessed { _ in }) }
    }

    /// A `SESSION_UPDATE` frame carrying this session.
    func sendUpdate(_ session: [String: Any]) {
        let json = try! JSONSerialization.data(withJSONObject: session)
        sendBinary([WSMsg.sessionUpdate] + [UInt8](json))
    }

    static func session(_ id: String, cwd: String = "/home/spierce", status: String = "running",
                        agentState: String = "idle", title: String? = nil,
                        command: String = "claude", args: [String] = [],
                        cols: Int = 80, rows: Int = 24) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "command": command, "args": args, "cwd": cwd, "createdAt": 1_700_000_000_000,
            "lastActivity": 1_700_000_100_000, "status": status, "cols": cols, "rows": rows,
            "pid": 4242, "agentState": agentState,
        ]
        if let title { row["title"] = title }
        return row
    }
}

// MARK: - the remote source

@Suite("remote session source, against a fake relay server")
@MainActor
struct RemoteSessionSourceTests {
    private func source(_ server: FakeRelayServer, token: String? = "t0k3n") -> RemoteSessionSource {
        RemoteSessionSource(
            name: "yorkshire",
            endpoint: RelayServer(baseURL: server.baseURL, token: token, placement: .cookie),
            pollInterval: 60)
    }

    /// Yield the main actor until `cond` holds: the source's work arrives as
    /// main-actor tasks, which a nested run loop inside a test cannot run.
    private func spin(until cond: () -> Bool, _ seconds: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    @Test("the list arrives with the cookie on the request, and only running sessions are kept")
    func listsWithCookie() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [
            FakeRelayServer.session("0368d543", agentState: "blocked"),
            FakeRelayServer.session("deadbeef", status: "exited"),
        ]
        let src = source(server)
        var seen: [[RelaySessionInfo]] = []
        src.onChange = { seen.append($0) }
        src.start()
        defer { src.stop() }

        #expect(await spin(until: { !seen.isEmpty }))
        #expect(seen.last?.map(\.id) == ["0368d543"])
        #expect(seen.last?.first?.agentState == "blocked")
        #expect(src.state == .connected)
        #expect(server.requestLines.contains { $0.hasPrefix("GET /api/sessions?includeExited=1") })
    }

    @Test("a 401 says the token was refused and stops retrying")
    func refusedStops() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543")]
        let src = source(server, token: "wrong")
        var states: [ServerState] = []
        src.onStateChange = { states.append($0) }
        src.start()
        defer { src.stop() }

        #expect(await spin(until: { src.state == .refused }), Comment(rawValue: "requests: \(server.requestLines) state: \(src.state)"))
        let fetches = src.fetches
        src.refresh()
        src.refresh()
        #expect(src.fetches == fetches, "a refused source kept asking")
        #expect(states.last == .refused)
        #expect(ServerState.refused.label == "TOKEN REFUSED")
    }

    @Test("\"sessions-changed\" on /ws/events fetches again; a SESSION_UPDATE patches in place; an exit drops the row")
    func eventsPatch() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543", cwd: "/home/spierce")]
        let src = source(server)
        var latest: [RelaySessionInfo] = []
        src.onChange = { latest = $0 }
        src.start()
        defer { src.stop() }
        #expect(await spin(until: { !latest.isEmpty && server.eventClients == 1 }), Comment(rawValue: "requests: \(server.requestLines) clients: \(server.eventClients) latest: \(latest.count) state: \(src.state) fetches: \(src.fetches)"))

        // A membership change: the text frame, then a refetch that sees the
        // second session.
        server.sessions.append(FakeRelayServer.session("cafe0001", cwd: "/srv"))
        let before = src.fetches
        server.sendText("sessions-changed")
        #expect(await spin(until: { src.fetches > before && latest.count == 2 }))

        // Metadata: one session's cwd moves, without a fetch.
        let fetches = src.fetches
        server.sendUpdate(FakeRelayServer.session("0368d543", cwd: "/home/spierce/m7out", agentState: "working"))
        #expect(await spin(until: { latest.first { $0.id == "0368d543" }?.cwd == "/home/spierce/m7out" }))
        #expect(src.fetches == fetches)
        #expect(latest.first { $0.id == "0368d543" }?.agentState == "working")

        // An exit on the wire is a row gone.
        server.sendUpdate(FakeRelayServer.session("cafe0001", status: "exited"))
        #expect(await spin(until: { latest.map(\.id) == ["0368d543"] }))
        #expect(src.updatesApplied == 2)
    }

    @Test("a text frame that is not the one word, and a binary frame that is not SESSION_UPDATE, change nothing")
    func noise() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("0368d543")]
        let src = source(server)
        var latest: [RelaySessionInfo] = []
        src.onChange = { latest = $0 }
        src.start()
        defer { src.stop() }
        #expect(await spin(until: { !latest.isEmpty && server.eventClients == 1 }))
        let fetches = src.fetches
        server.sendText("hello")
        server.sendBinary([WSMsg.pong])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(src.fetches == fetches)
        #expect(src.updatesApplied == 0)
    }
}

// MARK: - one namespace per server

@Suite("sessions are keyed on (server, id)")
@MainActor
struct SessionKeyTests {
    /// A source that says what it is told, on demand.
    final class FakeSource: SessionSource {
        let server: String?
        var onChange: (([RelaySessionInfo]) -> Void)?
        var onStateChange: ((ServerState) -> Void)?
        var state: ServerState = .connected
        init(_ server: String?) { self.server = server }
        func start() {}
        func stop() {}
        func refresh() {}
        func report(_ infos: [RelaySessionInfo]) { onChange?(infos) }
        func become(_ state: ServerState) { self.state = state; onStateChange?(state) }
    }

    private func info(_ id: String, cwd: String, agentState: String = "idle", title: String = "") -> RelaySessionInfo {
        let json = """
        {"id":"\(id)","command":"claude","args":[],"cwd":"\(cwd)","createdAt":1700000000000,"status":"running",
         "cols":80,"rows":24,"pid":1,"agentState":"\(agentState)","title":"\(title)","lastActivity":1700000100000}
        """
        return try! JSONDecoder().decode(RelaySessionInfo.self, from: Data(json.utf8))
    }

    @Test("the same id on two servers and locally is three sessions, and nothing crosses")
    func nothingCrosses() {
        let local = FakeSource(nil), york = FakeSource("yorkshire"), alien = FakeSource("alien")
        let registry = SessionRegistry(sources: [local, york, alien])
        local.report([info("0368d543", cwd: NSHomeDirectory() + "/code", agentState: "working")])
        york.report([info("0368d543", cwd: "/home/spierce", agentState: "blocked")])
        alien.report([info("0368d543", cwd: "/srv", agentState: "idle")])

        #expect(registry.sessions.count == 3)
        #expect(registry.telemetry(for: "0368d543")?.state == .working)
        #expect(registry.telemetry(for: SessionKey(server: "yorkshire", id: "0368d543"))?.state == .blocked)
        #expect(registry.telemetry(for: SessionKey(server: "alien", id: "0368d543"))?.state == .idle)
        #expect(registry.blockedCount == 1)

        // Attached is per pair.
        registry.setAttached([SessionKey(server: "yorkshire", id: "0368d543")])
        #expect(registry.telemetry(for: "0368d543")?.isAttached == false)
        #expect(registry.telemetry(for: SessionKey(server: "yorkshire", id: "0368d543"))?.isAttached == true)
        #expect(registry.telemetry(for: SessionKey(server: "alien", id: "0368d543"))?.isAttached == false)

        // DONE is per pair: the local one finishes; the remote ones do not.
        local.report([info("0368d543", cwd: NSHomeDirectory() + "/code", agentState: "idle", title: "✳ Claude Code")])
        #expect(registry.telemetry(for: "0368d543")?.state == .done)
        #expect(registry.telemetry(for: SessionKey(server: "yorkshire", id: "0368d543"))?.state == .blocked)
        registry.acknowledge(SessionKey(server: "alien", id: "0368d543"))
        #expect(registry.telemetry(for: "0368d543")?.state == .done, "acknowledging another server's session cleared this one")
        registry.acknowledge("0368d543")
        #expect(registry.telemetry(for: "0368d543")?.state == .idle)

        // One server going quiet leaves its slice alone; one reporting fewer
        // sessions loses only its own.
        york.report([])
        #expect(registry.sessions.count == 2)
        #expect(registry.telemetry(for: SessionKey(server: "alien", id: "0368d543")) != nil)

        // Groups: a remote group is server:path, never abbreviated against
        // this Mac's home.
        let paths = registry.grouped().map(\.path)
        #expect(paths.contains("alien:/srv"))
        #expect(paths.contains("~/code"))
        #expect(registry.remoteServers == ["yorkshire", "alien"])
    }

    @Test("a server's state reaches the registry, and the local server has none")
    func serverStates() {
        let local = FakeSource(nil), york = FakeSource("yorkshire")
        let registry = SessionRegistry(sources: [local, york])
        #expect(registry.serverStates == ["yorkshire": .connected])
        var notified = 0
        _ = registry.observe { _ in notified += 1 }
        york.become(.reconnecting)
        #expect(registry.serverStates["yorkshire"] == .reconnecting)
        #expect(notified == 2)
        local.become(.reconnecting)
        #expect(registry.serverStates.count == 1)
    }

    @Test("a key prints as id, or server:id, and a literal is a local id")
    func keyDescription() {
        #expect(SessionKey(id: "0368d543").description == "0368d543")
        #expect(SessionKey(server: "yorkshire", id: "0368d543").description == "yorkshire:0368d543")
        let literal: SessionKey = "0368d543"
        #expect(literal == SessionKey(server: nil, id: "0368d543"))
        #expect(!literal.isRemote)
        #expect(SessionKey(server: "yorkshire", id: "a") != SessionKey(server: "alien", id: "a"))
    }

    @Test("a remote session's group and header path carry the server's name where the directory sits")
    func remotePaths() {
        let remote = SessionTelemetry(sessionId: "0368d543", server: "yorkshire", cwd: NSHomeDirectory())
        #expect(remote.groupPath == "yorkshire:" + NSHomeDirectory(), "a remote home is not this Mac's home")
        #expect(remote.headerPath == "yorkshire:" + NSHomeDirectory())
        let local = SessionTelemetry(sessionId: "0368d543", cwd: NSHomeDirectory())
        #expect(local.groupPath == "~")
        #expect(local.headerPath == NSHomeDirectory())
        #expect(SessionTelemetry(sessionId: "x", server: "yorkshire", cwd: "").groupPath == "yorkshire")
    }

    @Test("the header keeps the server's name when the path has to shrink")
    func headerFit() {
        #expect(LaneHeaderPath.fit("yorkshire:/home/spierce/m7out", maxChars: 40) == "yorkshire:/home/spierce/m7out")
        // "yorkshire:" is ten cells; the path shrinks in what is left.
        #expect(LaneHeaderPath.fit("yorkshire:/home/spierce/m7out", maxChars: 25) == "yorkshire:…/spierce/m7out")
        #expect(LaneHeaderPath.fit("yorkshire:/home/spierce/m7out", maxChars: 22) == "yorkshire:…/m7out")
        #expect(LaneHeaderPath.fit("yorkshire:/home/spierce/m7out", maxChars: 16) == "yorkshire:…m7out")
        #expect(LaneHeaderPath.fit("yorkshire:/home/spierce", maxChars: 9) == "yorkshire")
        #expect(LaneHeaderPath.fit("yorkshire:" + NSHomeDirectory(), maxChars: 80) == "yorkshire:" + NSHomeDirectory(), "abbreviated a remote path against the local home")
        #expect(LaneHeaderPath.splitServer("/opt/thing") == nil)
        #expect(LaneHeaderPath.splitServer("~/code:x") == nil)
        #expect(LaneHeaderPath.splitServer("yorkshire:/x")?.server == "yorkshire")
    }
}

// MARK: - the strip, the sidebar and ⌘O

@Suite("a remote session on the strip and in the sidebar")
@MainActor
struct RemoteLaneTests {
    private func store() throws -> StripStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
    }

    private func telemetry(_ id: String, server: String? = nil, cwd: String, state: AgentState = .idle) -> SessionTelemetry {
        SessionTelemetry(
            sessionId: id, server: server, title: "claude", cwd: cwd, command: "claude", state: state,
            lastActivity: Date(timeIntervalSince1970: 100))
    }

    @Test("attaching a remote session makes a pane that knows its server, and the same id locally is another pane")
    func attachRemote() throws {
        let store = try store()
        try store.attachSessionAtEnd(SessionKey(server: "yorkshire", id: "0368d543"))
        try store.attachSessionAtEnd("0368d543")

        let panes = store.state.lanes.flatMap(\.panes)
        #expect(panes.map(\.relayServer) == ["yorkshire", nil])
        #expect(panes.map(\.sessionKey) == [SessionKey(server: "yorkshire", id: "0368d543"), "0368d543"])
        #expect(store.lane(holdingSession: SessionKey(server: "yorkshire", id: "0368d543"))?.id == store.state.lanes[0].id)
        #expect(store.lane(holdingSession: "0368d543")?.id == store.state.lanes[1].id)
        #expect(store.lane(holdingSession: SessionKey(server: "alien", id: "0368d543")) == nil)
        #expect(throws: (any Error).self) {
            try store.attachSessionAtEnd(SessionKey(server: "yorkshire", id: "0368d543"))
        }
    }

    @Test("the sidebar groups a remote session under server:path below the server's own header, which carries the state, and matches it to its own lane only")
    func sidebarRows() throws {
        let store = try store()
        try store.attachSessionAtEnd(SessionKey(server: "yorkshire", id: "0368d543"))
        let lanes = store.allLanes
        let t: [SessionKey: SessionTelemetry] = [
            SessionKey(server: "yorkshire", id: "0368d543"): telemetry("0368d543", server: "yorkshire", cwd: "/home/spierce", state: .blocked),
            "0368d543": telemetry("0368d543", cwd: NSHomeDirectory() + "/code/max-pane"),
        ]
        let rows = SidebarModel.rows(lanes: lanes, telemetry: t, servers: ["yorkshire": .connected])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        let entries = rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }

        // `// LOCAL` and its groups; then the server's header and its groups.
        #expect(groups.map(\.path) == [SidebarModel.localSection, "~/code/max-pane", "yorkshire:", "yorkshire:/home/spierce"])
        #expect(groups[0].header == "LOCAL" && groups[0].countText == "1 SESSION")
        #expect(groups[1].server == nil)
        #expect(groups[1].countText == "1 RUNNING")
        #expect(groups[2].isServer)
        #expect(groups[2].server == "yorkshire")
        #expect(groups[2].header == "YORKSHIRE")
        #expect(groups[2].countText == "1 BLOCKED")
        #expect(groups[3].server == "yorkshire")
        #expect(!groups[3].isServer)
        // The path stops repeating the server; the key (and the ledger's tag) keeps it.
        #expect(groups[3].header == "/home/spierce")
        #expect(groups[3].countText == "1 BLOCKED")
        let remote = try #require(entries.first { $0.sessionKey?.server == "yorkshire" })
        let local = try #require(entries.first { $0.sessionKey?.server == nil })
        #expect(remote.laneId == lanes[0].id, "the remote row did not find its lane")
        #expect(local.laneId == nil, "the local row was matched to the remote lane of the same id")
        #expect(remote.id != local.id)
        #expect(SidebarModel.footerCount(telemetry: t, lanes: lanes) == "1/2 SESSIONS")
    }

    @Test("⌘O offers a remote session with its server on the row, and attaches it by its pair")
    func omniRow() {
        let t = telemetry("0368d543", server: "yorkshire", cwd: "/home/spierce")
        let rows = OmniRanking.build(query: "", scope: .sessions, recents: [], pages: [], bookmarks: [], sessions: [t], destination: "")
        let candidate = rows.compactMap(\.candidate).first { $0.kind == .session }
        #expect(candidate?.action == .attach(SessionKey(server: "yorkshire", id: "0368d543")))
        // The server is the row's chip; the detail line is a local row's shape.
        #expect(candidate?.server == "yorkshire")
        #expect(candidate?.detail.hasPrefix("0368d543 · ") == true, Comment(rawValue: candidate?.detail ?? ""))
        #expect(candidate?.detail.contains("yorkshire") == false)
    }

    @Test("the header of a remote lane names the server as its chip and shows the path alone")
    func headerModel() {
        let lane = Lane(
            id: "L", ordinal: 1, widthPt: 500, title: nil, projectRoot: "yorkshire:/home/spierce",
            projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1,
            isPrivate: false,
            panes: [Pane(
                id: "P", laneId: "L", position: 0, kind: .pty, relaySessionId: "0368d543", relayServer: "yorkshire",
                url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1,
                zoom: 1, mobile: false, muted: false, volume: 100)])
        let with = LaneHeaderModel(lane: lane, telemetry: telemetry("0368d543", server: "yorkshire", cwd: "/home/spierce/m7out"))
        #expect(with.path == "/home/spierce/m7out")
        #expect(with.server == "yorkshire")
        let without = LaneHeaderModel(lane: lane, telemetry: nil)
        #expect(without.path == "/home/spierce")
        #expect(without.server == "yorkshire", "the ledger's pane says which server when the registry cannot")
        // The ledger's tag is untouched: this is presentation.
        #expect(lane.projectRoot == "yorkshire:/home/spierce")
    }

    @Test("the adapter for a pane is chosen by its server")
    func adapterChoice() {
        let servers = RelayServers(
            entries: [RelayServerEntry(name: "yorkshire", url: "https://x.relaytty.com")],
            token: { _ in "tok" })
        #expect(servers.names == ["yorkshire"])
        #expect(servers.endpoints["yorkshire"]?.token == "tok")
        #expect(servers.endpoints["yorkshire"]?.webSocketURL(sessionId: "0368d543").absoluteString == "wss://x.relaytty.com/ws/sessions/0368d543")
        #expect(servers.adapter(for: "0368d543").server == nil)
        #expect(servers.adapter(for: SessionKey(server: "yorkshire", id: "0368d543")).server == "yorkshire")
        #expect(servers.adapter(for: SessionKey(server: "nowhere", id: "0368d543")).server == "nowhere")
        // An unusable entry is skipped, not fatal.
        let bad = RelayServers(entries: [RelayServerEntry(name: "", url: "https://x"), RelayServerEntry(name: "a:b", url: "https://x"), RelayServerEntry(name: "ok", url: "ftp://x")], token: { _ in nil })
        #expect(bad.isEmpty)
    }

    @Test("a reconnect's replay that is longer than the gap is the whole ring")
    func fullReplayTell() {
        // Resumed from 2518, SYNC says 2578: a delta is at most 60 bytes.
        #expect(!RelayAttachmentAdapter.isFullReplay(bytes: 60, resumedFrom: 2518, sync: 2578))
        #expect(!RelayAttachmentAdapter.isFullReplay(bytes: 0, resumedFrom: 2518, sync: 2518))
        #expect(RelayAttachmentAdapter.isFullReplay(bytes: 2578, resumedFrom: 2518, sync: 2578), "spike M7 §3, the 60 s outage")
        #expect(RelayAttachmentAdapter.isFullReplay(bytes: 2848, resumedFrom: 2668, sync: 2848), "the 180 s outage")
    }
}

// MARK: - config and the token

@Suite("[[servers]] in config.toml, and the token")
@MainActor
struct RemoteConfigTests {
    @Test("an array of tables parses, keeps its comments through an edit, and appends and removes cleanly")
    func arrayOfTables() {
        var doc = TomlDocument("""
        theme = "dark"

        # the home box
        [[servers]]
        name = "yorkshire"   # tunnel
        url = "https://yourslug.relaytty.com"

        [[servers]]
        name = "alien"
        url = "http://192.168.68.56:44936"
        enabled = false

        [keys]
        closePane = []
        """)
        #expect(doc.unreadable.isEmpty)
        #expect(doc.arrayTables("servers") == ["servers[0]", "servers[1]"])
        #expect(doc.entry("name", in: "servers[0]")?.value == .success(.string("yorkshire")))
        #expect(doc.entry("enabled", in: "servers[1]")?.value == .success(.bool(false)))
        #expect(doc.entry("closePane", in: "keys") != nil)
        #expect(doc.entry("theme")?.value == .success(.string("dark")))

        doc.set("url", in: "servers[0]", to: .string("https://new.relaytty.com"))
        #expect(doc.text.contains("url = \"https://new.relaytty.com\""))
        #expect(doc.text.contains("name = \"yorkshire\"   # tunnel"), "the comment on the line moved")
        #expect(doc.text.contains("# the home box\n[[servers]]"))

        doc.appendArrayTable("servers", [(key: "name", value: .string("third")), (key: "url", value: .string("https://t")), (key: "enabled", value: .bool(true))])
        #expect(doc.arrayTables("servers").count == 3)
        #expect(doc.text.hasSuffix("[[servers]]\nname = \"third\"\nurl = \"https://t\"\nenabled = true\n"))

        doc.removeArrayTable("servers[1]")
        #expect(doc.arrayTables("servers").count == 2)
        #expect(!doc.text.contains("alien"))
        #expect(doc.text.contains("# the home box\n[[servers]]\nname = \"yorkshire\""))
        #expect(doc.entry("name", in: "servers[1]")?.value == .success(.string("third")))
        #expect(doc.text.contains("url = \"https://new.relaytty.com\"\n\n[keys]"), Comment(rawValue: doc.text))
    }

    @Test("Config reads the servers, defaults enabled, and skips the ones it cannot use with a reason")
    func decodesServers() {
        let (config, problems) = ConfigFile.decode(TomlDocument("""
        [[servers]]
        name = "yorkshire"
        url = "https://yourslug.relaytty.com/"

        [[servers]]
        name = "alien"
        url = "http://192.168.68.56:44936"
        enabled = false
        colour = "green"

        [[servers]]
        url = "https://nameless"

        [[servers]]
        name = "badurl"
        url = "relaytty.com"

        [[servers]]
        name = "yorkshire"
        url = "https://twice"
        """))
        #expect(config.servers == [
            RelayServerEntry(name: "yorkshire", url: "https://yourslug.relaytty.com/", enabled: true),
            RelayServerEntry(name: "alien", url: "http://192.168.68.56:44936", enabled: false),
        ])
        #expect(config.enabledServers.map(\.name) == ["yorkshire"])
        #expect(config.servers[0].baseURL?.absoluteString == "https://yourslug.relaytty.com")
        #expect(problems.map(\.key) == ["servers[1].colour", "servers[2]", "servers[3]", "servers[4]"])
        #expect(problems[1].reason.contains("needs a name"))
        #expect(problems[2].reason.contains("http://"))
        #expect(problems[3].reason.contains("already named"))
        #expect(ConfigFile.decode(TomlDocument("")).config.servers.isEmpty)
        #expect(Config() == ConfigFile.decode(TomlDocument("")).config, "an empty file is today's app")
    }

    @Test("the startup URL splits into the base and the token, and anything else is refused")
    func startupURL() {
        let parsed = RelayServerTokens.parseStartupURL("https://yourslug.relaytty.com/api/auth/callback?token=eyJhb.Ci0.sig-_x")
        #expect(parsed?.base.absoluteString == "https://yourslug.relaytty.com")
        #expect(parsed?.token == "eyJhb.Ci0.sig-_x")
        #expect(RelayServerTokens.parseStartupURL("http://localhost:44936/?token=abc\n")?.base.absoluteString == "http://localhost:44936")
        #expect(RelayServerTokens.parseStartupURL("https://yourslug.relaytty.com") == nil)
        #expect(RelayServerTokens.parseStartupURL("https://x/api/auth/callback?token=") == nil)
        #expect(RelayServerTokens.parseStartupURL("ftp://x/?token=abc") == nil)
        #expect(RelayServerTokens.parseStartupURL("https://x/?token=a%20b") == nil)
    }

    @Test("the control socket parses server add and server ls")
    func requests() {
        guard case .addServer(let name, let url)? = OpenServer.parse(#"{"op":"server-add","name":"yorkshire","url":"https://x/api/auth/callback?token=t"}"#) else {
            Issue.record("server-add did not parse"); return
        }
        #expect(name == "yorkshire")
        #expect(url == "https://x/api/auth/callback?token=t")
        #expect(OpenServer.parse(#"{"op":"server-add","name":"","url":"https://x"}"#) == nil)
        guard case .listServers? = OpenServer.parse(#"{"op":"server-ls"}"#) else {
            Issue.record("server-ls did not parse"); return
        }
    }

    @Test("ConfigStore.addServer writes a table, and rewrites the URL of a server that exists")
    func storeAddsServer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-servers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml")
        try "theme = \"dark\"\n".write(to: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path, watches: false)

        store.addServer(RelayServerEntry(name: "yorkshire", url: "https://a"))
        store.addServer(RelayServerEntry(name: "alien", url: "https://b", enabled: false))
        store.addServer(RelayServerEntry(name: "yorkshire", url: "https://c"))
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text == "theme = \"dark\"\n\n[[servers]]\nname = \"yorkshire\"\nurl = \"https://c\"\nenabled = true\n\n[[servers]]\nname = \"alien\"\nurl = \"https://b\"\nenabled = false\n", Comment(rawValue: text))
        #expect(store.config.servers.map(\.url) == ["https://c", "https://b"])
    }
}

// MARK: - the real server, by hand

/// The whole remote path against a real relay-tty server: the list over
/// HTTP, a refused token, and one session attached through the app's own
/// adapter and transport. Gated on `MAXPANE_REMOTE_VERIFY` naming the base
/// URL, because it needs a server and a token (`MAXPANE_REMOTE_TOKEN`, read
/// at run time and never printed). `MAXPANE_REMOTE_SESSION` picks the
/// session; otherwise the first running one.
@Suite("the real server, when MAXPANE_REMOTE_VERIFY names it")
@MainActor
struct LiveRemoteTests {
    @Test("list, refuse a wrong token, attach one session and type into it")
    func liveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MAXPANE_REMOTE_VERIFY"].flatMap(URL.init(string:)) else {
            print("SKIPPED live remote check — set MAXPANE_REMOTE_VERIFY=<base url> and MAXPANE_REMOTE_TOKEN to run it")
            return
        }
        let token = env["MAXPANE_REMOTE_TOKEN"]
        func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return cond()
        }

        // 1. The list, with the cookie.
        let source = RemoteSessionSource(name: "live", endpoint: RelayServer(baseURL: base, token: token), pollInterval: 60)
        var list: [RelaySessionInfo] = []
        source.onChange = { list = $0 }
        source.start()
        defer { source.stop() }
        #expect(await spin(20, { source.state == .connected && !list.isEmpty }), "no list from \(base) — state \(source.state)")
        print("live: \(base.host ?? "") answered with \(list.count) running session(s): " +
              list.map { "\($0.id) \($0.agentState ?? "-") \($0.cwd)" }.joined(separator: "; "))

        // 2. A wrong token is refused on HTTP, through the tunnel and LAN-direct alike.
        let wrong = RemoteSessionSource(name: "live-wrong", endpoint: RelayServer(baseURL: base, token: "eyJ.WRONG.WRONG"), pollInterval: 60)
        wrong.start()
        defer { wrong.stop() }
        #expect(await spin(20, { wrong.state == .refused }), "a wrong token was not refused — state \(wrong.state)")
        print("live: a wrong token is \(wrong.state)")

        // 3. Attach through the adapter and the WebSocket transport.
        let id = env["MAXPANE_REMOTE_SESSION"] ?? list.first!.id
        let endpoint = RelayServer(baseURL: base, token: token)
        let adapter = RelayAttachmentAdapter(sessionId: id, server: "live") { queue in
            WebSocketTransport(server: endpoint, sessionId: id, queue: queue)
        }
        var connected = false, bytes = 0, resizes: [(Int, Int)] = [], refused: String?
        adapter.onConnectionChange = { connected = $0 }
        adapter.onData = { bytes += $0.count }
        adapter.onHostResize = { resizes.append(($0, $1)) }
        adapter.onRefused = { refused = $0 }
        adapter.connect()
        defer { adapter.disconnect() }
        #expect(await spin(20, { connected }), "the session socket did not hand shake — refused: \(refused ?? "no")")
        #expect(await spin(5, { bytes > 0 }), "no replay bytes")
        let before = bytes
        adapter.send(Array("\r".utf8)[...])
        #expect(await spin(10, { bytes > before }), "typing an Enter produced no output")
        print("live: attached \(id): host \(resizes.last.map { "\($0.0)x\($0.1)" } ?? "?"), \(before) B replayed, \(bytes - before) B after Enter")
    }
}
