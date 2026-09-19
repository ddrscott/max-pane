import AppKit

/// Which colour each configured server has, by name: the one place a mark
/// asks (ADR-0025).
///
/// Written by `RelayServers.reload`, the one place a name meets its table in
/// `config.toml`, exactly as `ServerChip.hosts` is; read by `ServerMark`,
/// `ServerChip` and the sidebar's section header. A change posts `didChange`,
/// and every mark on screen re-reads its colour and cross-fades, so a colour
/// picked from the menu, typed into the file or sent over the socket is on
/// every surface in the same turn with nothing threaded through the models.
///
/// A name nobody configured is `slate`: a lane whose server was removed keeps
/// its chip, in grey.
@MainActor
enum ServerColours {
    static let didChange = Notification.Name("MaxPane.ServerColours.didChange")

    private(set) static var byName: [String: ServerColour] = [:]

    static func colour(of server: String) -> ServerColour { byName[server] ?? .fallback }

    /// Take `old`'s names out and put `new`'s in. Names, not the whole map:
    /// see `RelayServers.reload`.
    static func replace(_ old: [String: ServerColour], with new: [String: ServerColour]) {
        guard old != new else { return }
        for name in old.keys where new[name] == nil { byName.removeValue(forKey: name) }
        for (name, colour) in new { byName[name] = colour }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
