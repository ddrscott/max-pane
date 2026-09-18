import Foundation
import RelayClient

/// The remote relay-tty servers this launch knows, by name, with their
/// credentials resolved: `config.toml` says where each one is, the Keychain
/// says how to prove who we are to it, and this is the one place the two
/// are put together.
///
/// Built once at launch from `Config.servers` (ADR-0020). A server whose
/// entry is unusable is skipped with one line naming it; a server with no
/// token in the Keychain is kept — through relaytty.com the session
/// WebSocket is accepted without one today, and the HTTP list will say 401
/// in the sidebar rather than this saying nothing.
@MainActor
public final class RelayServers {
    public private(set) var endpoints: [String: RelayServer] = [:]
    /// The names, in `config.toml` order.
    public private(set) var names: [String] = []

    public convenience init(entries: [RelayServerEntry]) {
        self.init(entries: entries, token: RelayServerTokens.token(for:))
    }

    /// `token` answers the Keychain's question, so a test can answer it
    /// without one.
    init(entries: [RelayServerEntry], token: (URL) -> String?) {
        for entry in entries {
            if let why = entry.complaint {
                Log.warn("server \(entry.name.isEmpty ? "(unnamed)" : entry.name): \(why); skipped")
                continue
            }
            guard let base = entry.baseURL else { continue }
            let credential = token(base)
            if credential == nil {
                Log.warn("server \(entry.name): no token in the Keychain for \(base.host ?? entry.url); run maxpane server add")
            }
            endpoints[entry.name] = RelayServer(baseURL: base, token: credential, placement: .cookie)
            names.append(entry.name)
        }
    }

    public convenience init(config: Config) {
        self.init(entries: config.enabledServers)
    }

    public var isEmpty: Bool { endpoints.isEmpty }

    /// One list source per server, for the registry.
    public func sources(pollInterval: TimeInterval) -> [RemoteSessionSource] {
        names.compactMap { name in
            endpoints[name].map { RemoteSessionSource(name: name, endpoint: $0, pollInterval: pollInterval) }
        }
    }

    /// The adapter a pane attaches through: the WebSocket transport for a
    /// session on a named server, the Unix socket for a local one. A pane
    /// naming a server this launch does not know gets the adapter anyway, so
    /// the lane keeps its place and the banner says why, rather than the
    /// pane silently attaching to a local session of the same id.
    func adapter(for key: SessionKey) -> RelayAttachmentAdapter {
        guard let server = key.server else { return RelayAttachmentAdapter(sessionId: key.id) }
        guard let endpoint = endpoints[server] else {
            Log.warn("session \(key): server \(server) is not in config.toml; the lane will not attach")
            return RelayAttachmentAdapter(sessionId: key.id, server: server) { _ in UnknownServerTransport() }
        }
        return RelayAttachmentAdapter(sessionId: key.id, server: server) { queue in
            WebSocketTransport(server: endpoint, sessionId: key.id, queue: queue)
        }
    }
}

/// The transport for a pane whose server is not configured: it fails at
/// once, finally, so the adapter stops and the pane says so in one line.
final class UnknownServerTransport: RelayTransport {
    var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?
    var onClosed: ((RelayClose) -> Void)?
    let tConnected: Double = 0
    let tFirstSent: Double = 0

    func open(firstPayload: [UInt8]) throws {
        onClosed?(RelayClose(kind: .authRefused, code: 0, reason: "server not configured"))
    }
    func send(_ payload: [UInt8]) {}
    func close() {}
}
