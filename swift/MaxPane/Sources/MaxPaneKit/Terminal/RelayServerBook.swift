import Foundation

/// The remote servers as one thing to manage: `config.toml` (name, URL,
/// enabled), the Keychain (the token), the registry (the session source
/// per server) and the strip (the panes attached through each) agree
/// because every add, remove, enable, rename and pasted token goes through
/// here — from Settings › Servers, from `maxpane server add`, and from a
/// hand edit of the file, which `ConfigStore` notices and which lands in
/// `reconcile` the same as a change made in the window.
///
/// Nothing here touches the network on the calling thread. "Test the
/// connection" is the new source's first `GET /api/sessions`, which runs on
/// its own `URLSession` and reports through the registry's state: the row
/// in Settings reads the answer off the registry when it arrives.
@MainActor
public final class RelayServerBook {
    public let servers: RelayServers
    public let registry: SessionRegistry
    public let store: ConfigStore
    private let pollInterval: TimeInterval
    private var observer: NSObjectProtocol?

    /// A server's endpoint came, went, or changed: the panes attached to
    /// sessions on it re-attach through the new adapter (or the "not
    /// configured" one). Set by the window controller.
    public var onServerChanged: ((String) -> Void)?
    /// After every reconcile, so Settings can redraw its rows.
    public var onChange: (() -> Void)?

    public init(servers: RelayServers, registry: SessionRegistry, store: ConfigStore, pollInterval: TimeInterval) {
        self.servers = servers
        self.registry = registry
        self.store = store
        self.pollInterval = pollInterval
        observer = NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Every server the file names, enabled or not, in file order.
    public var entries: [RelayServerEntry] { store.config.servers }

    // MARK: - keeping the three in step

    /// Bring the endpoints and the registry's sources to what the file says
    /// now. `tokenChanged` names servers whose Keychain item was just
    /// written, so their endpoint is rebuilt with the new credential even
    /// though the file did not change.
    public func reconcile(tokenChanged: Set<String> = []) {
        let delta = servers.reload(entries: store.config.enabledServers, tokenChanged: tokenChanged)
        for name in delta.removed { registry.removeRemote(named: name) }
        for name in delta.added {
            if let source = servers.source(named: name, pollInterval: pollInterval) {
                registry.addRemote(source)
            }
        }
        for name in Set(delta.removed).union(delta.added) { onServerChanged?(name) }
        if !delta.isEmpty { onChange?() }
    }

    // MARK: - what Settings shows

    public struct Status: Equatable {
        public enum Kind: Equatable {
            case connected
            case reconnecting
            case refused
            /// Config present, no Keychain item: the row offers Paste.
            case noToken
            case disabled
            /// The entry could not be used: the reason is `detail`.
            case skipped
        }
        public var kind: Kind
        /// The word after the dot.
        public var word: String
        /// Sessions the registry holds for it.
        public var sessions: Int
        /// The last error in one line, or why it was skipped; nil when
        /// there is nothing to say.
        public var detail: String?
        /// Through relaytty.com, where the WebSocket is not authenticated
        /// until relay-tty checks `?token=` (plan §1.4).
        public var isTunnelled: Bool
        public var hasToken: Bool
    }

    public func status(of entry: RelayServerEntry) -> Status {
        let tunnelled = entry.baseURL.map(RelayServerTokens.isTunnelled) ?? false
        let hasToken = servers.hasToken[entry.name] ?? false
        if let why = entry.complaint {
            return Status(kind: .skipped, word: "skipped", sessions: 0, detail: why, isTunnelled: tunnelled, hasToken: hasToken)
        }
        guard entry.enabled else {
            return Status(kind: .disabled, word: "disabled", sessions: 0, detail: nil, isTunnelled: tunnelled, hasToken: hasToken)
        }
        let sessions = registry.sessionCount(server: entry.name)
        let error = registry.serverErrors[entry.name]
        switch registry.serverStates[entry.name] {
        case .connected?:
            return Status(kind: .connected, word: "connected", sessions: sessions, detail: nil, isTunnelled: tunnelled, hasToken: hasToken)
        case .refused? where !hasToken:
            return Status(kind: .noToken, word: "no token", sessions: 0, detail: error, isTunnelled: tunnelled, hasToken: false)
        case .refused?:
            return Status(kind: .refused, word: "refused", sessions: 0, detail: error, isTunnelled: tunnelled, hasToken: hasToken)
        case .reconnecting?, nil:
            let word = hasToken ? "reconnecting" : "no token"
            return Status(
                kind: hasToken ? .reconnecting : .noToken, word: word, sessions: sessions,
                detail: error ?? (hasToken ? "connecting…" : "paste the Auth URL from the server's startup output"),
                isTunnelled: tunnelled, hasToken: hasToken)
        }
    }

    // MARK: - the operations

    /// Why an add was refused, in one line for the row it was typed on.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let text: String
        public var description: String { text }
    }

    /// `pasted` is the line the server printed, or a bare URL. `name` empty
    /// takes the host's first label. The token, when there is one, goes to
    /// the Keychain before the file is written, so the source built from
    /// the file finds it on its first read.
    @discardableResult
    public func add(pasted: String, name given: String) -> Result<RelayServerEntry, Refusal> {
        guard let parsed = RelayServerTokens.parse(pasted) else {
            return .failure(Refusal(text: "paste the server's Auth URL: https://host/api/auth/callback?token=…"))
        }
        let name = given.trimmingCharacters(in: .whitespaces).isEmpty
            ? RelayServerTokens.defaultName(for: parsed.base)
            : given.trimmingCharacters(in: .whitespaces)
        let entry = RelayServerEntry(name: name, url: parsed.base.absoluteString, enabled: true)
        if let why = entry.complaint { return .failure(Refusal(text: why)) }
        if entries.contains(where: { $0.name == name }) {
            return .failure(Refusal(text: "a server is already named \(name); rename it or pick another name"))
        }
        if let token = parsed.token, !RelayServerTokens.save(token, for: parsed.base) {
            return .failure(Refusal(text: "could not store the token in the Keychain for \(parsed.host)"))
        }
        // The write is noticed by `reconcile` (the store's own notification),
        // which reads the Keychain for a server it has not seen and starts
        // its source: that first fetch is the connection test.
        store.addServer(entry)
        if let error = store.writeError {
            return .failure(Refusal(text: "could not write \(store.path.path): \(error)"))
        }
        return .success(entry)
    }

    /// The table leaves the file and the token leaves the Keychain — unless
    /// another server is on the same host, whose token it also is. The
    /// registry and the panes follow through `reconcile`.
    public func remove(_ name: String) {
        guard let entry = entries.first(where: { $0.name == name }) else { return }
        if let base = entry.baseURL,
           !entries.contains(where: { $0.name != name && $0.baseURL?.host == base.host && $0.baseURL?.port == base.port }) {
            RelayServerTokens.remove(for: base)
        }
        store.removeServer(named: name)
    }

    public func setEnabled(_ name: String, _ enabled: Bool) {
        store.setServerEnabled(named: name, enabled)
    }

    /// The ledger's panes and `old:path` tags first, then the file, whose
    /// write reaches `reconcile`: the old name's source stops, the new
    /// name's starts, and the panes — already renamed — re-attach through
    /// the new endpoint. The other order would have re-attached them as
    /// "not configured" a beat before the ledger caught up. Returns why it
    /// could not, or nil.
    public func rename(_ old: String, to new: String, ledger: ((String, String) -> Void)?) -> String? {
        let name = new.trimmingCharacters(in: .whitespaces)
        if name == old { return nil }
        if let why = RelayServerEntry(name: name, url: "https://x").complaint { return why }
        guard entries.contains(where: { $0.name == old }) else { return "no server named \(old)" }
        if entries.contains(where: { $0.name == name }) { return "a server is already named \(name)" }
        ledger?(old, name)
        guard store.renameServer(from: old, to: name) else { return "no server named \(old)" }
        if let error = store.writeError { return "could not write \(store.path.path): \(error)" }
        return nil
    }

    /// A new token for a server that exists: the Keychain item is replaced
    /// and the endpoint rebuilt, so a refused source starts again with the
    /// new credential. The URL in the pasted line, if any, is not adopted —
    /// the row's URL is what the file says.
    public func pasteToken(_ name: String, pasted: String) -> String? {
        guard let entry = entries.first(where: { $0.name == name }), let base = entry.baseURL else {
            return "no server named \(name)"
        }
        guard let parsed = RelayServerTokens.parse(pasted), let token = parsed.token else {
            return "that line has no token; paste the Auth URL from the server's startup output"
        }
        if parsed.base.host != base.host {
            return "that URL is for \(parsed.host), not \(base.host ?? entry.url)"
        }
        guard RelayServerTokens.save(token, for: base) else {
            return "could not store the token in the Keychain for \(base.host ?? entry.url)"
        }
        reconcile(tokenChanged: [name])
        return nil
    }
}
