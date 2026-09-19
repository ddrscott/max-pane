import Foundation

/// The colour a remote server is known by (ADR-0025).
///
/// Identity, never state. State is green and DONE is Signal Orange
/// (ADR-0015); a server's colour says *which machine*, and it is carried by
/// one mark — a small solid square, `ServerMark` — and by the tint of the
/// server chip where the name is needed. It is never on a status square, a
/// focus outline, a lane border or terminal content.
///
/// Eight names, fixed, so `color = "violet"` in `config.toml` means the same
/// thing on every machine and in every appearance; the values are
/// `Theme.server(_:)`'s, one per appearance. The work item suggested `amber`
/// and `teal`; both read as state in the render sheet (amber beside DONE's
/// orange and the web bars' warning amber, teal beside the greens), so the
/// two that replaced them are `lemon` and `ink`.
public enum ServerColour: String, Codable, CaseIterable, Sendable {
    /// No colour: today's at-rest grey. What a server with no `color` key
    /// reads as, and what a bad value falls back to.
    case slate
    case cyan, blue, violet, magenta, rose, lemon, ink

    public static let fallback = ServerColour.slate

    /// As the menu and the tooltip print it.
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Every name, for a message that has to list them.
    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The colour a server gets without anyone opening a menu: the first of
    /// the palette no other server is using, so two servers are told apart
    /// from the moment the second is added. `slate` is "no colour" and is
    /// never handed out. With all seven taken, the least used, earliest
    /// first.
    public static func firstUnused(by used: [ServerColour]) -> ServerColour {
        let hues = allCases.filter { $0 != .slate }
        if let free = hues.first(where: { !used.contains($0) }) { return free }
        let counts = Dictionary(grouping: used, by: { $0 }).mapValues(\.count)
        return hues.min { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .cyan
    }
}
