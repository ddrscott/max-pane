import Foundation
import LanedCore

/// Everything a lane header says, resolved from the two sources that know it.
///
/// Separated from the view because the interesting decisions here are all
/// choices about *what* to show — which of two titles wins, what goes in the one
/// spare column when a session is quiet — and those are worth a test rather than
/// a screenshot.
///
/// The header answers the supervision question the bar answers: of the ten
/// panes on this strip, which one is alive, which one is working, which one has
/// been sitting on a prompt for thirteen hours, and which directory is it in.
struct LaneHeaderModel: Equatable {
    var kind: PaneGlyph = .web
    /// Fills the status square. Liveness only — the same thing the bar's green
    /// dot means — so it never has to be read together with the state chip.
    var isLive: Bool = false
    /// What the agent is doing, or nil for a lane with no Relay session behind
    /// it. `idle` and `unknown` are states with nothing to say — they carry no
    /// chip and no glyph — which is what keeps the one that does say something
    /// worth looking at.
    var state: AgentState?
    /// The remote server this lane's session is on, for the server chip
    /// beside the path; nil for a lane on this Mac.
    var server: String?
    /// How that server is doing when it is anything but connected, else
    /// nil. It takes the state chip's place — `RECONNECTING` where `BLOCKED`
    /// would be — because a dead server is the state of every lane on it,
    /// and nothing the session last said can be vouched for (ADR-0023).
    var serverOff: ServerState?
    var title: String = "untitled"
    /// Unabbreviated and untruncated. The view decides how much of it fits.
    /// A remote lane's is the path alone, as the server gave it: the chip
    /// says which server, and the path stops repeating it.
    var path: String = ""
    /// Throughput while output is moving, otherwise how long it has been quiet.
    /// Never the state's name, because the chip two columns to the left already
    /// said that.
    var badge: String = ""
    var badgeIsThroughput: Bool = false
    /// ⇧⌘P's flag: this lane's pages are never destroyed to reclaim memory.
    /// Named for the ledger's field (ADR-0010) rather than for the glyph it
    /// draws, because the header carries two markers since docking arrived and
    /// "pinned" could honestly have meant either of them.
    var keepLive: Bool = false
    /// Which edge this lane is held at, and what it does to the strip there.
    /// `nil` for a lane that scrolls with everything else.
    var dock: Dock?
    /// A private lane (⇧⌘N). The header says `PRIVATE` in the chip column,
    /// grey and outlined: content, not colour, because the greens are spent
    /// on focus and state and this is neither — it is what the lane *is*.
    var isPrivate: Bool = false
    var isTerminal: Bool = false
    /// The long form, for the hover tip — the header is the only place the full
    /// path exists, so truncating it must not destroy it.
    var tooltip: String = ""

    /// The markers at the right-hand end of the header, as one string.
    ///
    /// Two facts share one column: which edge this lane is held at, and whether
    /// its pages are protected from eviction. They belong together because both
    /// are structural — neither says anything about what the lane is *doing* —
    /// and because a header on a 240 pt dock has one spare column, not two.
    ///
    /// The dock glyph is **filled when the dock takes its room out of the strip
    /// and hollow when it floats over it**, so the shape carries the mode and
    /// the marker answers "which edge" and "at whose expense" with no word and
    /// no colour. The greens are spent on focus and state; a permanent
    /// green mark on a lane that is docked all day would spend it on something
    /// that is true all the time.
    var markerText: String { markerText(drawnMode: nil) }

    /// `drawnMode` is the mode the dock is actually being *drawn* in, when the
    /// window cannot afford the one the ledger holds — an inset dock in an
    /// 800 pt window floats until the window grows (`DockGeometry`). The header
    /// reports the screen in front of the user, not the preference behind it:
    /// a filled marker beside a dock that is visibly covering a lane is the
    /// header contradicting the window.
    func markerText(drawnMode: DockMode?) -> String {
        var text = ""
        switch (dock?.side, dock.map { drawnMode ?? $0.mode }) {
        case (.left, .inset):    text += "◀"
        case (.left, .overlay):  text += "◁"
        case (.right, .inset):   text += "▶"
        case (.right, .overlay): text += "▷"
        default: break
        }
        if keepLive { text += "▪" }
        return text
    }

    init() {}

    init(lane: LaneHeaderSource, telemetry: SessionTelemetry?, serverState: ServerState? = nil) {
        kind = lane.kind
        server = telemetry?.server ?? lane.server
        let connection = telemetry?.connection ?? serverState
        serverOff = (server != nil && connection?.isOff == true) ? connection : nil
        isTerminal = lane.kind == .pty
        keepLive = lane.keepLive
        dock = lane.dock
        isPrivate = lane.isPrivate

        // The ledger's title is the one the user can rename, so it wins; the
        // session's own name is the fallback for a lane that was just attached
        // and has not been titled yet. The command is the last real answer —
        // RelayTTY's own header does `session.title || command + args`, and
        // "htop" identifies a lane where "untitled" does not.
        title = [lane.title, telemetry?.title, lane.host, telemetry?.command]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "untitled"

        // The session's cwd is the truth — it follows `cd`. The project root is
        // a fallback for lanes with no session (a web lane, a dead terminal).
        // A remote session's is its cwd on that server. The ledger's tag is
        // `server:path` and stays so; the header shows the path and lets the
        // chip name the server (ADR-0023).
        let root = lane.projectRoot.map { root in
            server != nil ? (LaneHeaderPath.splitServer(root)?.path ?? root) : root
        }
        path = [telemetry?.cwd, root]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? ""

        if let telemetry {
            // An offline session is not known to be running: the square goes
            // hollow with the rest of the row.
            isLive = telemetry.isRunning && !telemetry.isOffline
            state = telemetry.state
            badge = telemetry.badgeIsThroughput
                ? telemetry.throughputText
                // "13h ago" → "13h". Three characters of "ago" buys nothing in a
                // column that is four characters wide.
                : telemetry.ageText.replacingOccurrences(of: " ago", with: "")
            badgeIsThroughput = telemetry.badgeIsThroughput
            tooltip = [
                telemetry.title.isEmpty ? title : telemetry.title,
                telemetry.headerPath,
                // The rate only while it is working, as on the badge: an idle
                // session's sixty-second trickle is not news.
                [telemetry.isOffline ? "offline" : telemetry.state.rawValue, telemetry.ageText,
                 telemetry.badgeIsThroughput ? telemetry.throughputText : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                telemetry.command,
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if lane.hasRelaySession, let serverOff {
            // The server was already gone when this lane was restored, so the
            // registry has never heard of its session. That is not the same
            // as the session having exited, and the header must not say so.
            isLive = false
            state = nil
            tooltip = [title, path, serverOff.label.lowercased()].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if lane.hasRelaySession {
            // A pty lane that names a session Relay has never heard of: the
            // session is gone, not quiet. Saying "live" here is the one lie the
            // header must not tell, because it is the reason the dot exists.
            isLive = false
            state = .exited
            tooltip = [title, path, "session gone"].filter { !$0.isEmpty }.joined(separator: "\n")
        } else {
            // No session behind this lane at all: liveness is whatever the pane
            // itself reports, which is all a web pane ever has.
            isLive = lane.hasLivePane
            tooltip = [title, path].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

/// The slice of a `Lane` the header reads. A protocol so the model can be tested
/// without building a whole ledger snapshot — the header does not care where its
/// strings came from.
protocol LaneHeaderSource {
    var kind: PaneGlyph { get }
    var title: String? { get }
    var host: String? { get }
    var projectRoot: String? { get }
    var keepLive: Bool { get }
    var dock: Dock? { get }
    var hasLivePane: Bool { get }
    /// True when a pane on this lane names a Relay session, whether or not
    /// Relay still knows about it.
    var hasRelaySession: Bool { get }
    var isPrivate: Bool { get }
    /// The remote server the lane's session is on, from the ledger's pane.
    var server: String? { get }
}

extension LaneHeaderSource {
    /// A source that does not say is not private — `Lane` says for itself.
    var isPrivate: Bool { false }
    var server: String? { nil }
}

extension Lane: LaneHeaderSource {
    var kind: PaneGlyph {
        switch panes.first?.kind {
        case .pty: return .pty
        case .web: return .web
        case .placeholder: return .placeholder
        case nil: return .web
        }
    }

    /// A web lane with no title is best identified by its host, not its URL.
    var host: String? { panes.first?.url.flatMap { URL(string: $0)?.host } }

    var hasLivePane: Bool { panes.contains { $0.state == .live } }

    var server: String? { panes.first(where: { $0.kind == .pty })?.relayServer }

    var hasRelaySession: Bool {
        panes.contains { $0.kind == .pty && $0.relaySessionId != nil }
    }
}
