import Foundation
import RelayClient

/// Spike M7's one remote lane (`docs/spikes/07-m7-remote-relay.md`).
///
/// Read from the environment only, so the shipped app never sees it: with
/// `MAXPANE_SPIKE_REMOTE` unset, `current` is nil and nothing below is reached.
///
///     MAXPANE_SPIKE_REMOTE='https://<slug>.relaytty.com|<session-id>|<token>[|cookie|query|none]'
///
/// `wss://` is accepted for the base and means the same as `https://`. The
/// fourth field is where the token goes on the upgrade (default `cookie`).
/// At launch the session gets a lane at the end of the strip if it has none,
/// and that lane's pane attaches over `WebSocketTransport` instead of the
/// Unix socket. Not a feature: Phase 1 of the remote-relay plan replaces this
/// with servers in the ledger and a Settings row.
enum SpikeRemote {
    struct Target: Equatable {
        let server: RelayServer
        let sessionId: String
    }

    static let current: Target? = parse(ProcessInfo.processInfo.environment["MAXPANE_SPIKE_REMOTE"])

    static func parse(_ raw: String?) -> Target? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        var base = parts[0]
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        guard let url = URL(string: base), let scheme = url.scheme, url.host != nil,
              scheme == "https" || scheme == "http"
        else { return nil }
        let id = parts[1].lowercased()
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        let token = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        let placement = parts.count > 3
            ? RelayServer.TokenPlacement(rawValue: parts[3]) ?? .cookie
            : .cookie
        return Target(server: RelayServer(baseURL: url, token: token, placement: placement), sessionId: id)
    }

    /// The adapter for a pane whose session is the spike's, or nil.
    @MainActor
    static func adapter(for sessionId: String) -> RelayAttachmentAdapter? {
        guard let target = current, target.sessionId == sessionId else { return nil }
        return RelayAttachmentAdapter(sessionId: sessionId) { queue in
            WebSocketTransport(server: target.server, sessionId: sessionId, queue: queue)
        }
    }
}
