import AppKit
import Foundation

/// What needs a person, in the order a person should go to it (ADR-0037).
///
/// One ring: every BLOCKED session in strip order, then every DONE session in
/// strip order. ⌘J walks it forwards from the lane the keyboard is in and
/// ⇧⌘J backwards, both wrapping at the ends, so pressing ⌘J until it comes
/// back to where it started has visited every prompt and then every finish.
/// A session's place in the ring is its lane's place on the strip — folded
/// (ADR-0024) and docked lanes included, in the ledger's order — because
/// "the next one along" is a question about the strip, not about time.
///
/// Pure, so the rule is one function a test can call with a handful of keys.
enum AttentionOrder {
    struct Entry: Equatable {
        let key: SessionKey
        let state: AgentState
        /// The lane's index in `allLanes`.
        let laneIndex: Int
    }

    /// The ring: BLOCKED in lane order, then DONE in lane order. Anything
    /// else is left out.
    static func ring(_ entries: [Entry]) -> [SessionKey] {
        let blocked = entries.filter { $0.state == .blocked }.sorted { $0.laneIndex < $1.laneIndex }
        let done = entries.filter { $0.state == .done }.sorted { $0.laneIndex < $1.laneIndex }
        return (blocked + done).map(\.key)
    }

    /// The next stop after the focused lane, or nil with nothing to go to.
    ///
    /// From a lane that is in the ring, the one after it (wrapping). From
    /// any other lane, the first BLOCKED lane to the right of it on the
    /// strip, wrapping round to the left; with none BLOCKED, the first DONE
    /// the same way. The focused lane's own session, when it is the only
    /// one, is the answer: ⌘J then goes nowhere, which is the truth.
    static func next(_ entries: [Entry], from focusedLane: Int?, focusedSession: SessionKey?) -> SessionKey? {
        let ring = ring(entries)
        guard !ring.isEmpty else { return nil }
        if let focusedSession, let at = ring.firstIndex(of: focusedSession) {
            return ring[(at + 1) % ring.count]
        }
        let origin = focusedLane ?? -1
        for state in [AgentState.blocked, .done] {
            let ordered = entries.filter { $0.state == state }.sorted { $0.laneIndex < $1.laneIndex }
            guard !ordered.isEmpty else { continue }
            return (ordered.first { $0.laneIndex > origin } ?? ordered[0]).key
        }
        return nil
    }

    /// The stop before the focused lane: the ring walked the other way, so
    /// ⇧⌘J undoes ⌘J. From a lane that is not in the ring, the last DONE to
    /// the left of it (wrapping), else the last BLOCKED the same way.
    static func previous(_ entries: [Entry], from focusedLane: Int?, focusedSession: SessionKey?) -> SessionKey? {
        let ring = ring(entries)
        guard !ring.isEmpty else { return nil }
        if let focusedSession, let at = ring.firstIndex(of: focusedSession) {
            return ring[(at + ring.count - 1) % ring.count]
        }
        let origin = focusedLane ?? Int.max
        for state in [AgentState.done, .blocked] {
            let ordered = entries.filter { $0.state == state }.sorted { $0.laneIndex < $1.laneIndex }
            guard !ordered.isEmpty else { continue }
            return (ordered.last { $0.laneIndex < origin } ?? ordered[ordered.count - 1]).key
        }
        return nil
    }
}

/// The Dock badge: the number of agents waiting on a person, and nothing
/// when there are none. BLOCKED only — a DONE is news, not a request, and a
/// badge that never reaches zero is a badge nobody reads.
enum AttentionBadge {
    static func label(blocked: Int) -> String? {
        blocked > 0 ? String(blocked) : nil
    }
}

/// An agent stopped while nobody was looking: the notification (ADR-0037).
///
/// Hangs off `SessionRegistry.onStateChange`, so it fires on the transition
/// into BLOCKED or DONE — once per transition, never for a session's first
/// reading, and never for a session on a server that is not answering, whose
/// shown state is `.unknown` (ADR-0023). One notification per session: a
/// DONE that follows a BLOCKED replaces the earlier banner rather than
/// stacking under it, and the banner is taken down again the moment the
/// session moves on — answered, looked at, working again — so the list in
/// Notification Center never says something the sidebar has stopped saying.
///
/// **Away** is `NSApp.isActive == false` and nothing else. A lane folded
/// away or scrolled off the strip is still in a window that is in front,
/// where the sidebar chip, the status bar's count and the Dock badge are all
/// on screen; a banner on top of them would be a fourth voice for one fact.
/// `always` adds the frontmost case for every pane but the one with the
/// keyboard, which is the one you are looking at.
///
/// Posting goes through the same `NotificationPosting` seam a page's
/// notification does, so a test hands this a recorder and nothing reaches
/// the owner's Notification Center.
@MainActor
final class AgentNotifier {
    static let prefix = "maxpane.agent."

    let poster: NotificationPosting
    /// Whether the app is in front. The real thing asks `NSApp`; a test says.
    var isAppActive: () -> Bool = { NSApp.isActive }
    /// The setting as it is now, not as it was at launch.
    var mode: () -> AgentNotify
    /// The session whose pane has the keyboard, for `always`.
    var focusedSession: () -> SessionKey? = { nil }
    /// The last line with anything on it in the session's terminal, for the
    /// body. Nil for a session with no pane, or one that has printed nothing.
    var lastLine: (SessionKey) -> String? = { _ in nil }
    /// A click: go to the session. The real thing activates the app and
    /// attaches; a test records.
    var onActivate: (SessionKey) -> Void = { _ in }
    /// Asked once, before the first post, so macOS's permission question is
    /// about something.
    var ensureAuthorized: () -> Void = {}

    /// The notifications on screen, by identifier, for the click.
    private(set) var posted: [String: SessionKey] = [:]

    init(poster: NotificationPosting, mode: @escaping () -> AgentNotify) {
        self.poster = poster
        self.mode = mode
    }

    static func identifier(_ key: SessionKey) -> String { prefix + key.description }

    /// The banner's three lines. Title: the session's title, or its command
    /// when it has none. Subtitle: the state and the directory, `$HOME`
    /// abbreviated. Body: the last line the agent printed, which for a prompt
    /// is the question and for a finish is usually the answer's last line.
    static func content(for t: SessionTelemetry, state: AgentState, lastLine: String?)
        -> (title: String, subtitle: String, body: String) {
        let title = t.title.trimmingCharacters(in: .whitespaces).isEmpty ? t.command : t.title
        let path = t.server.map { "\($0):\(t.cwd)" } ?? SessionTelemetry.abbreviate(t.cwd)
        let subtitle = "\(state.chipText) · \(path)"
        let body = lastLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (title, subtitle, body.isEmpty ? (state == .blocked ? "Waiting on you" : "Finished") : body)
    }

    /// Whether a transition to `state` posts, under `mode`.
    static func shouldPost(state: AgentState, mode: AgentNotify, appActive: Bool, isFocused: Bool) -> Bool {
        guard state == .blocked || state == .done else { return false }
        switch mode {
        case .never: return false
        case .away: return !appActive
        case .always: return !(appActive && isFocused)
        }
    }

    /// A session's shown state changed — `SessionRegistry.onStateChange`.
    func stateChanged(_ t: SessionTelemetry, to state: AgentState) {
        let identifier = Self.identifier(t.key)
        guard state == .blocked || state == .done, t.isRunning else {
            // Moved on: whatever banner was up is stale.
            if posted.removeValue(forKey: identifier) != nil { poster.remove(identifiers: [identifier]) }
            return
        }
        guard Self.shouldPost(
            state: state, mode: mode(), appActive: isAppActive(), isFocused: focusedSession() == t.key)
        else { return }
        ensureAuthorized()
        let (title, subtitle, body) = Self.content(for: t, state: state, lastLine: lastLine(t.key))
        posted[identifier] = t.key
        poster.post(identifier: identifier, title: title, subtitle: subtitle, body: body, icon: nil) { error in
            if let error { Log.warn("notifications: agent banner not posted: \(error.localizedDescription)") }
        }
    }

    /// A banner was clicked, or swiped away. A click goes to the session,
    /// through `onActivate`; either way the entry is forgotten.
    func activated(identifier: String, dismissed: Bool) {
        guard let key = posted.removeValue(forKey: identifier) else {
            Log.debug("notifications: \(identifier) is no agent's now")
            return
        }
        guard !dismissed else { return }
        onActivate(key)
    }
}
