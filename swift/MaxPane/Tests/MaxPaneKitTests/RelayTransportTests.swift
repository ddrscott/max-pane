import Testing
import Foundation
import Network
@testable import RelayClient
@testable import MaxPaneKit

/// A stand-in for relay-tty's `/ws/sessions/:id` bridge on a loopback port:
/// Network.framework's WebSocket server, which does the upgrade itself, so
/// what these tests exercise is only what `WebSocketTransport` puts on the
/// wire and makes of what comes back.
final class FakeRelayWS: @unchecked Sendable {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "fake.relay.ws")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var binary: [[UInt8]] = []
    private var pings = 0
    /// Whether an application PING gets its PONG. Off to make a zombie.
    var answersPings = true

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let l = listener
        l.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = l.port!.rawValue
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func accept(_ conn: NWConnection) {
        lock.lock(); connections.append(conn); lock.unlock()
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let data, let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .binary {
                let bytes = [UInt8](data)
                if bytes.first == WSMsg.ping {
                    self.lock.lock(); self.pings += 1; let answer = self.answersPings; self.lock.unlock()
                    if answer { self.send(conn, [WSMsg.pong]) }
                } else {
                    self.lock.lock(); self.binary.append(bytes); self.lock.unlock()
                }
            }
            self.receive(conn)
        }
    }

    private func send(_ conn: NWConnection, _ bytes: [UInt8]) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        conn.send(content: Data(bytes), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// One binary message to every client: a payload, no length prefix.
    func sendBinary(_ bytes: [UInt8]) {
        lock.lock(); let cs = connections; lock.unlock()
        for c in cs { send(c, bytes) }
    }

    /// One text message, which a session socket never carries (§1) but
    /// `/ws/events` does.
    func sendText(_ text: String) {
        lock.lock(); let cs = connections; lock.unlock()
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        for c in cs { c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in }) }
    }

    /// A close frame with `code`, the way `/ws/share` refuses a token (4001).
    func close(code: UInt16, reason: String = "") {
        lock.lock(); let cs = connections; lock.unlock()
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = (try? NWProtocolWebSocket.CloseCode(rawValue: code)) ?? .privateCode(code)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        for c in cs { c.send(content: Data(reason.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in }) }
    }

    var received: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return binary }
    var pingsReceived: Int { lock.lock(); defer { lock.unlock() }; return pings }
    var clientCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    func waitUntil(_ deadline: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    func stop() {
        listener.cancel()
        lock.lock(); let cs = connections; connections = []; lock.unlock()
        for c in cs { c.cancel() }
    }
}

/// A `RelaySession` on a `WebSocketTransport` against the fake, with the
/// callbacks the tests read gathered under one lock.
final class Attached: @unchecked Sendable {
    let session: RelaySession
    let transport: WebSocketTransport
    private let lock = NSLock()
    private var resizes: [(Int, Int)] = []
    private var syncs: [Double] = []
    private var payloads: [UInt8] = []
    private var closed = false

    init(server: FakeRelayWS, sessionId: String = "0368d543", token: String? = "t0k3n",
         placement: RelayServer.TokenPlacement = .cookie,
         pingInterval: TimeInterval = 10, zombieAfter: TimeInterval = 45) {
        let queue = DispatchQueue(label: "test.relay.ws")
        let transport = WebSocketTransport(
            server: RelayServer(baseURL: server.baseURL, token: token, placement: placement),
            sessionId: sessionId, queue: queue, pingInterval: pingInterval, zombieAfter: zombieAfter)
        self.transport = transport
        session = RelaySession(id: sessionId, queue: queue, transport: transport)
        session.onResize = { [weak self] c, r in self?.record { $0.resizes.append((c, r)) } }
        session.onSync = { [weak self] v in self?.record { $0.syncs.append(v) } }
        session.onPayload = { [weak self] t, _ in self?.record { $0.payloads.append(t) } }
        session.onClosed = { [weak self] in self?.record { $0.closed = true } }
    }

    private func record(_ f: (Attached) -> Void) { lock.lock(); f(self); lock.unlock() }
    var resizeCount: Int { lock.lock(); defer { lock.unlock() }; return resizes.count }
    var lastResize: (Int, Int)? { lock.lock(); defer { lock.unlock() }; return resizes.last }
    var syncCount: Int { lock.lock(); defer { lock.unlock() }; return syncs.count }
    var lastSync: Double? { lock.lock(); defer { lock.unlock() }; return syncs.last }
    var payloadTypes: [UInt8] { lock.lock(); defer { lock.unlock() }; return payloads }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

@Suite("relay WebSocket transport", .serialized)
struct RelayTransportTests {
    @Test("RESUME leaves as one binary message with no length prefix, first")
    func resumeIsFirstAndUnprefixed() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let a = Attached(server: server)
        try a.session.connect(mode: .resume(offset: 4096, maxReplayBytes: 262_144))
        #expect(server.waitUntil { !server.received.isEmpty })
        let first = server.received.first!
        // [0x10][f64 offset][f64 max]: 17 bytes, and byte 0 is the type, not a length.
        #expect(first.count == 17)
        #expect(first[0] == WSMsg.resume)
        #expect(first == encodeResume(offset: 4096, maxReplayBytes: 262_144))
        // The Unix socket wraps the same bytes; the WS must not.
        #expect(lengthPrefixed(first).count == 21)
        #expect(encodeFrame(WSMsg.resume, Array(first[1...])) == lengthPrefixed(first))
        a.session.close()
    }

    @Test("inbound payloads are unprefixed too: RESIZE then SYNC complete the handshake")
    func inboundNoPrefix() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let a = Attached(server: server)
        try a.session.connect()
        #expect(server.waitUntil { server.clientCount == 1 && !server.received.isEmpty })
        server.sendBinary(encodeResize(cols: 120, rows: 40))       // what the bridge forwards, verbatim
        #expect(server.waitUntil { a.resizeCount == 1 })
        #expect(a.lastResize! == (120, 40))
        var sync = [WSMsg.sync]
        let raw = Double(568).bitPattern
        for s in stride(from: 56, through: 0, by: -8) { sync.append(UInt8((raw >> UInt64(s)) & 0xff)) }
        server.sendBinary(sync)
        #expect(server.waitUntil { a.syncCount == 1 })
        #expect(a.lastSync == 568)
        #expect(a.session.handshakeDone)
        #expect(a.session.offset == 568)
        #expect(a.session.timings.tResumeSent > 0)
        a.session.close()
    }

    @Test("input goes out as [0x00][bytes], nothing added either side")
    func inputUnprefixed() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let a = Attached(server: server)
        try a.session.connect()
        #expect(server.waitUntil { server.received.count == 1 })
        a.session.sendInput(Array("ls\r".utf8))
        #expect(server.waitUntil { server.received.count == 2 })
        #expect(server.received[1] == [0x00] + Array("ls\r".utf8))
        a.session.close()
    }

    @Test("text frames are dropped, and counted, and the binary after them still lands")
    func textDropped() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let a = Attached(server: server)
        try a.session.connect()
        #expect(server.waitUntil { server.clientCount == 1 && !server.received.isEmpty })
        server.sendText("sessions-changed")
        server.sendText("\u{01}not a frame")
        server.sendBinary(encodeResize(cols: 80, rows: 24))
        #expect(server.waitUntil { a.resizeCount == 1 })
        #expect(a.transport.textFramesDropped == 2)
        #expect(a.payloadTypes == [WSMsg.resize])
        a.session.close()
    }

    @Test("PING every interval, PONG counted, nothing reaches handle's cases")
    func pingCadence() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let a = Attached(server: server, pingInterval: 0.05, zombieAfter: 45)
        try a.session.connect()
        #expect(server.waitUntil { server.clientCount == 1 })
        #expect(server.waitUntil(3) { server.pingsReceived >= 5 })
        #expect(server.waitUntil(3) { a.transport.pongsReceived >= 5 })
        // The PONGs came through the payload path (0x21) and were ignored by handle.
        #expect(a.payloadTypes.allSatisfy { $0 == WSMsg.pong })
        #expect(a.resizeCount == 0 && a.syncCount == 0)
        #expect(!a.isClosed)
        a.session.close()
    }

    @Test("no inbound frame for zombieAfter closes as a zombie, and that is retryable")
    func zombie() throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        server.answersPings = false
        let a = Attached(server: server, pingInterval: 0.05, zombieAfter: 0.3)
        try a.session.connect()
        #expect(server.waitUntil { server.clientCount == 1 })
        #expect(server.waitUntil(3) { a.isClosed })
        #expect(a.session.closeReason?.kind == .zombie)
        #expect(a.session.closeReason?.isFinal == false)
        #expect(server.pingsReceived >= 3)
    }

    @Test("close 4001 and 1008 are final; 1000 is not")
    func closeCodes() throws {
        for (code, final) in [(UInt16(4001), true), (1008, true), (1000, false)] {
            let server = try FakeRelayWS()
            let a = Attached(server: server)
            try a.session.connect()
            #expect(server.waitUntil { server.clientCount == 1 && !server.received.isEmpty })
            server.close(code: code, reason: "invalid-or-expired")
            #expect(server.waitUntil(3) { a.isClosed }, "no close for \(code)")
            let reason = a.session.closeReason
            #expect(reason?.isFinal == final, "code \(code): \(String(describing: reason))")
            #expect(reason?.code == Int(code), "code \(code) arrived as \(String(describing: reason))")
            server.stop()
        }
    }

    @Test("the credential rides the upgrade as a Cookie header, or the query, as asked")
    func tokenPlacement() {
        let base = URL(string: "https://yourslug.relaytty.com")!
        let cookie = RelayServer(baseURL: base, token: "abc", placement: .cookie)
        #expect(cookie.webSocketURL(sessionId: "0368d543").absoluteString == "wss://yourslug.relaytty.com/ws/sessions/0368d543")
        let query = RelayServer(baseURL: base, token: "abc", placement: .query)
        #expect(query.webSocketURL(sessionId: "0368d543").absoluteString == "wss://yourslug.relaytty.com/ws/sessions/0368d543?token=abc")
        let plain = RelayServer(baseURL: URL(string: "http://localhost:44864")!, token: nil)
        #expect(plain.webSocketURL(sessionId: "0368d543").absoluteString == "ws://localhost:44864/ws/sessions/0368d543")
    }

    @Test("a refused credential stops the adapter reconnecting; a plain close does not")
    @MainActor
    func adapterStopsOnFinal() async throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        let target = RelayServer(baseURL: server.baseURL, token: "bad")
        let adapter = RelayAttachmentAdapter(sessionId: "0368d543") { queue in
            WebSocketTransport(server: target, sessionId: "0368d543", queue: queue)
        }
        var changes: [Bool] = []
        adapter.onConnectionChange = { changes.append($0) }
        adapter.connect()
        #expect(server.waitUntil { server.clientCount == 1 && !server.received.isEmpty })
        server.close(code: 4001, reason: "invalid-or-expired")
        try await Task.sleep(for: .seconds(1.5))     // past the 0.5 s first backoff
        #expect(server.clientCount == 1, "reconnected after a final close")
        #expect(changes == [false])
        adapter.disconnect()
    }

    @Test("MAXPANE_SPIKE_REMOTE parses, and its absence is nil")
    func spikeEnv() {
        #expect(SpikeRemote.parse(nil) == nil)
        #expect(SpikeRemote.parse("") == nil)
        #expect(SpikeRemote.parse("nonsense") == nil)
        let t = SpikeRemote.parse("wss://yourslug.relaytty.com|0368D543|tok")
        #expect(t?.server.baseURL.absoluteString == "https://yourslug.relaytty.com")
        #expect(t?.sessionId == "0368d543")
        #expect(t?.server.token == "tok")
        #expect(t?.server.placement == .cookie)
        let q = SpikeRemote.parse("http://localhost:44864|0368d543||query")
        #expect(q?.server.token == nil)
        #expect(q?.server.placement == .query)
        #expect(SpikeRemote.current == nil, "the test process must not carry the spike variable")
    }
}
