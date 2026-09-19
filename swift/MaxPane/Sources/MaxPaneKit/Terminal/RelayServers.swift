import Foundation
import RelayClient

/// The remote relay-tty servers this app knows, by name, with their
/// credentials resolved: `config.toml` says where each one is, the Keychain
/// says how to prove who we are to it, and this is the one place the two
/// are put together.
///
/// Built at launch from `Config.servers` (ADR-0020) and reloaded whenever
/// the file changes (`reload`), so a server added in Settings or by hand
/// exists the moment the file is written. A server whose entry is unusable
/// is skipped with one line naming it; a server with no token in the
/// Keychain is kept — through relaytty.com the session WebSocket is
/// accepted without one today, and the HTTP list will say 401 in the
/// sidebar rather than this saying nothing.
@MainActor
public final class RelayServers {
    public private(set) var endpoints: [String: RelayServer] = [:]
    /// The names, in `config.toml` order.
    public private(set) var names: [String] = []
    /// Which servers have a token in the Keychain, by name. `false` is the
    /// "no token" row in Settings.
    public private(set) var hasToken: [String: Bool] = [:]
    private var entries: [String: RelayServerEntry] = [:]
    /// Each server's colour, by name, as the file has it now.
    public private(set) var colours: [String: ServerColour] = [:]
    private let token: (URL) -> String?

    public convenience init(entries: [RelayServerEntry]) {
        self.init(entries: entries, token: RelayServerTokens.token(for:))
    }

    /// `token` answers the Keychain's question, so a test can answer it
    /// without one.
    init(entries: [RelayServerEntry], token: @escaping (URL) -> String?) {
        self.token = token
        _ = reload(entries: entries, tokenChanged: [])
    }

    public convenience init(config: Config) {
        self.init(entries: config.enabledServers)
    }

    public var isEmpty: Bool { endpoints.isEmpty }

    /// What changed between the servers this held and `entries`, by name.
    /// A server whose URL or token changed is in both lists: the old
    /// endpoint goes, the new one comes.
    public struct Delta: Equatable {
        public var added: [String] = []
        public var removed: [String] = []
        /// Servers whose colour changed and nothing else: no endpoint is
        /// rebuilt and no lane re-attaches, so they are not in `isEmpty`.
        public var recoloured: [String] = []
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Bring the set to `entries`. The Keychain is read for a server that
    /// is new, whose URL changed, or whose name is in `tokenChanged` (the
    /// user just pasted one); every other server keeps the credential it
    /// had, so a settings keystroke elsewhere in the file costs no Keychain
    /// call. Returns what to start and what to stop.
    @discardableResult
    public func reload(entries next: [RelayServerEntry], tokenChanged: Set<String>) -> Delta {
        var delta = Delta()
        var kept: [String: RelayServer] = [:]
        var names: [String] = []
        var seen = Set<String>()
        for entry in next {
            if let why = entry.complaint {
                Log.warn("server \(entry.name.isEmpty ? "(unnamed)" : entry.name): \(why); skipped")
                continue
            }
            guard let base = entry.baseURL, seen.insert(entry.name).inserted else { continue }
            let previous = endpoints[entry.name]
            let unchanged = previous?.baseURL == base && !tokenChanged.contains(entry.name)
            if let previous, unchanged {
                kept[entry.name] = previous
            } else {
                let credential = token(base)
                if credential == nil {
                    Log.warn("server \(entry.name): no token in the Keychain for \(base.host ?? entry.url); paste the server's Auth URL in Settings › Servers")
                }
                kept[entry.name] = RelayServer(baseURL: base, token: credential, placement: .cookie)
                hasToken[entry.name] = credential != nil
                if previous != nil { delta.removed.append(entry.name) }
                delta.added.append(entry.name)
            }
            names.append(entry.name)
        }
        for name in self.names where kept[name] == nil {
            delta.removed.append(name)
            hasToken.removeValue(forKey: name)
        }
        endpoints = kept
        self.names = names
        // The server chip's tooltip is the URL's host; this is the one place
        // a name and a URL meet.
        ServerChip.hosts = kept.compactMapValues { $0.baseURL.host }
        entries = Dictionary(uniqueKeysWithValues: next.filter { kept[$0.name] != nil }.map { ($0.name, $0) })
        // The colours, to the one place every mark reads them. Only the
        // names this set holds are touched, so two sets (a test's and
        // another test's) never take each other's colours away.
        let colours = entries.mapValues(\.colour)
        delta.recoloured = colours.filter { self.colours[$0.key] != nil && self.colours[$0.key] != $0.value }.map(\.key).sorted()
        ServerColours.replace(self.colours, with: colours)
        self.colours = colours
        return delta
    }

    public func entry(named name: String) -> RelayServerEntry? { entries[name] }

    /// One list source per server, for the registry.
    public func sources(pollInterval: TimeInterval) -> [RemoteSessionSource] {
        names.compactMap { source(named: $0, pollInterval: pollInterval) }
    }

    public func source(named name: String, pollInterval: TimeInterval) -> RemoteSessionSource? {
        endpoints[name].map { RemoteSessionSource(name: name, endpoint: $0, pollInterval: pollInterval) }
    }

    /// What starts a session on `server`: this Mac's spawner for `nil`, a
    /// `RemoteSpawner` over the named server's endpoint, or nil for a name
    /// the file does not configure — the caller says so in one line rather
    /// than quietly starting the thing here.
    func spawner(for server: String?, config: Config) -> SessionSpawning? {
        guard let server else { return LocalSpawner(config: config) }
        return endpoints[server].map { RemoteSpawner(name: server, endpoint: $0) }
    }

    /// The adapter a pane attaches through: the WebSocket transport for a
    /// session on a named server, the Unix socket for a local one. A pane
    /// naming a server this app does not know gets the adapter anyway, so
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
