import Testing
import Foundation
@testable import RelayClient
@testable import MaxPaneKit

/// A connection that is over must be freed.
///
/// MaxPane runs for days. When `RelayAttachmentAdapter` captured its
/// `RelaySession` strongly in the session's own callbacks, every connection
/// it ever made stayed in memory with its transport's 256 KiB read buffer:
/// a copy that had been up four and a half days held 54 000 of them in
/// 16 GB. `WebSocketTransport` never invalidated its `URLSession`, which
/// holds its delegate, so remote connections stayed too.
@Suite("a finished relay connection is freed", .serialized)
@MainActor
struct RelayAttachmentLeakTests {
    /// A wire that fails to open, or opens and can be hung up on.
    private final class Wire: RelayTransport {
        var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?
        var onClosed: ((RelayClose) -> Void)?
        var tConnected: Double = 0
        var tFirstSent: Double = 0
        let queue: DispatchQueue
        let refuses: Bool
        init(queue: DispatchQueue, refuses: Bool) { self.queue = queue; self.refuses = refuses }
        func open(firstPayload: [UInt8]) throws {
            if refuses { throw UnixSocketTransport.ConnectError.connectFailed(ECONNREFUSED) }
        }
        func send(_ payload: [UInt8]) {}
        func close() {}
        func hangUp() { queue.async { self.onClosed?(RelayClose(kind: .closed)) } }
    }

    private final class Weak { weak var wire: AnyObject? ; init(_ w: AnyObject) { wire = w } }

    private func freed(_ refs: [Weak], within seconds: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if refs.allSatisfy({ $0.wire == nil }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return refs.allSatisfy { $0.wire == nil }
    }

    @Test("a connect that fails, the dead-session retry loop, frees its session and transport")
    func failedConnect() async {
        var made: [Weak] = []
        let adapter = RelayAttachmentAdapter(sessionId: "leak-refused") { queue in
            let w = Wire(queue: queue, refuses: true)
            made.append(Weak(w))
            return w
        }
        adapter.connect()
        adapter.disconnect()        // no retry after this one
        #expect(made.count == 1)
        #expect(await freed(made), "a refused connect stayed in memory")
    }

    @Test("a connection the other end closes is freed once the adapter lets go of it")
    func closedConnection() async {
        var made: [Wire] = []
        var refs: [Weak] = []
        let adapter = RelayAttachmentAdapter(sessionId: "leak-closed") { queue in
            let w = Wire(queue: queue, refuses: false)
            made.append(w)
            refs.append(Weak(w))
            return w
        }
        var changes: [Bool] = []
        adapter.onConnectionChange = { changes.append($0) }
        adapter.connect()
        made.first?.hangUp()
        made.removeAll()
        let end = Date().addingTimeInterval(10)
        while changes.isEmpty, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        adapter.disconnect()        // cancel the reconnect it scheduled
        #expect(changes == [false])
        #expect(await freed(refs), "a closed connection stayed in memory")
    }

    @Test("a WebSocket transport is freed after it closes")
    func webSocketFreed() async throws {
        let server = try FakeRelayWS()
        defer { server.stop() }
        var refs: [Weak] = []
        do {
            let t = WebSocketTransport(
                server: RelayServer(baseURL: server.baseURL, token: "t0k3n"),
                sessionId: "leak-ws", queue: DispatchQueue(label: "test.leak.ws"))
            refs.append(Weak(t))
            try t.open(firstPayload: [WSMsg.observe])
            #expect(server.waitUntil { server.clientCount == 1 })
            t.close()
        }
        #expect(await freed(refs), "the URLSession kept its delegate after close")
    }
}
