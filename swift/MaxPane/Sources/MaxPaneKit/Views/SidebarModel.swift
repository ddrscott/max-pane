import Foundation
import LanedCore

/// What the sidebar shows, worked out before any view exists.
///
/// The whole browser — grouping, counts, filtering, sort order, the labels — is
/// a pure function of (lanes, telemetry, controls). Keeping it here rather than
/// inside the table's delegate is what makes the interesting half testable
/// without an NSWindow, and it is also how the one-second age tick stays cheap:
/// rebuild the model, compare, and only touch AppKit when something moved.
///
/// `AgentState` is the authority on what a session is doing. Nothing here
/// second-guesses it: pty-host reads the terminal's tail, this reads pty-host.
enum SidebarModel {
    /// The sentinel group for web lanes that carry no project tag.
    ///
    /// A browser lane opened from nowhere has no directory, and filing it under
    /// `~` would be a lie — it is not a session living in the home directory.
    /// The high code point sorts it after every real path.
    static let looseWebGroup = "\u{FFFF}web"

    enum Kind: Equatable {
        /// A RelayTTY session, whether or not a lane is attached to it.
        case session
        /// A web lane. It has no session, so it has no agent state — but it is
        /// still something on the strip you need to be able to find.
        case web
        /// A lane whose panes are all evicted placeholders.
        case placeholder
    }

    /// The glyphs an agent writes into its own terminal title (Claude Code marks
    /// its titles `✳ …` and `◑ …`). They are not pty-host's opinion and they are
    /// not used as one — they are lifted out so the title column is text and the
    /// state column is state, instead of two glyphs fighting at the same x.
    static let titleGlyphs: Set<Character> =
        ["✳", "✻", "◑", "◐", "◒", "◓", "●", "○", "◆", "✓", "·", "⏺", "⚑"]

    /// `"◑ Pane terminal size"` → `("◑", "Pane terminal size")`.
    static func splitGlyph(_ title: String) -> (glyph: String?, title: String) {
        guard let first = title.first, titleGlyphs.contains(first) else { return (nil, title) }
        let rest = title.dropFirst().drop { $0 == " " }
        guard !rest.isEmpty else { return (nil, title) }
        return (String(first), String(rest))
    }

    /// One row under a group header.
    struct Entry: Equatable {
        var id: String
        var kind: Kind
        var title: String
        /// The lane on the strip, when there is one. `nil` means "click to attach".
        var laneId: String?
        var sessionId: String?
        /// pty-host's verdict, and the only source for the chip.
        var state: AgentState
        /// The state column's mark.
        var glyph: String
        /// `BLOCKED` / `WORKING` / `DONE` / `EXITED`, empty for idle and unknown.
        var chip: String
        /// The throughput slot: a rate when bytes are moving, "idle" when not.
        /// Deliberately *not* the state — a row can read `idle` here and carry a
        /// `BLOCKED` chip, and that pair is the one worth crossing the room for.
        var badge: String
        var badgeIsThroughput: Bool
        var age: String
        var isRunning: Bool
        var pinned: Bool
        /// Sort keys, resolved up front so the comparator stays total.
        var createdAt: Double
        var activityAt: Double

        var needsAttention: Bool { state == .blocked }
    }

    struct Group: Equatable {
        var path: String
        var running: Int
        var blocked: Int
        var total: Int
        var collapsed: Bool

        /// `~/code/max-pane` → `~/CODE/MAX-PANE`; the loose-web sentinel → `WEB`.
        var header: String {
            // The path as it really is. Upper-casing it was treating a
            // directory as a label, and paths are case-sensitive data — a group
            // called ~/CODE/MAX-PANE names nothing on this disk.
            path == SidebarModel.looseWebGroup ? "Web" : path
        }

        /// A collapsed group hides its rows, so the header has to carry the one
        /// fact you cannot afford to have hidden.
        var countText: String {
            if blocked > 0 { return "\(blocked) BLOCKED" }
            return running > 0 ? "\(running) RUNNING" : "\(total) CLOSED"
        }
    }

    enum Row: Equatable {
        case group(Group)
        case entry(Entry)
    }

    // MARK: - controls

    enum SortField: String, CaseIterable {
        /// The bar's default, and the only one that never slides a row out from
        /// under the pointer you are reaching for it with.
        case created
        case recent
        case name
        /// Full attention order: blocked, working, done, idle, unknown.
        case attention

        var label: String {
            switch self {
            case .created: return "CREATED"
            case .recent: return "RECENT"
            case .name: return "NAME"
            case .attention: return "ATTENTION"
            }
        }
    }

    /// The filter chips. `waiting` is the one that earns its place on a strip of
    /// ten agents: everything that is not producing output, blocked first.
    enum Scope: String, CaseIterable {
        case all, running, waiting, attached

        var label: String {
            switch self {
            case .all: return "ALL"
            case .running: return "RUN"
            case .waiting: return "WAITING"
            case .attached: return "ON STRIP"
            }
        }
    }

    struct Controls: Equatable {
        var sort: SortField = .created
        var descending = true
        var scope: Scope = .all
        var query = ""
        var collapsed: Set<String> = []
    }

    // MARK: - building

    /// Everything the strip and Relay know about, as one list of rows.
    ///
    /// Sessions come first because the bar's claim is that you can see *every*
    /// session, not only the ones you have already pulled onto the strip; lanes
    /// then contribute what Relay cannot know about — web panes, and pty lanes
    /// whose session has gone.
    static func rows(
        lanes: [Lane],
        telemetry: [String: SessionTelemetry],
        created: [String: Double] = [:],
        controls: Controls = Controls(),
        now: Date = Date()
    ) -> [Row] {
        var laneForSession: [String: Lane] = [:]
        for lane in lanes {
            for pane in lane.panes {
                if let sid = pane.relaySessionId, laneForSession[sid] == nil {
                    laneForSession[sid] = lane
                }
            }
        }

        var grouped: [String: [Entry]] = [:]
        for (id, t) in telemetry {
            let lane = laneForSession[id]
            let split = splitGlyph(displayTitle(t))
            // Only where pty-host has no opinion at all does the agent's own
            // title mark get to fill the glyph column — and never the chip.
            let glyph = t.state == .unknown ? (split.glyph ?? t.state.glyph) : t.state.glyph
            let entry = Entry(
                id: "session:\(id)",
                kind: .session,
                title: split.title,
                laneId: lane?.id,
                sessionId: id,
                state: t.state,
                glyph: glyph,
                chip: t.state.chipText,
                badge: t.badgeText,
                badgeIsThroughput: t.badgeIsThroughput,
                age: t.ageText,
                isRunning: t.isRunning,
                pinned: lane?.keepLive ?? false,
                createdAt: created[id] ?? (t.lastActivity?.timeIntervalSince1970 ?? 0),
                activityAt: t.lastActivity?.timeIntervalSince1970 ?? 0)
            grouped[t.groupPath, default: []].append(entry)
        }

        for lane in lanes {
            // A pty lane whose session Relay has already forgotten still deserves
            // a row; without one the strip would hold a lane the browser denies.
            let sessionIds = lane.panes.compactMap(\.relaySessionId)
            if sessionIds.contains(where: { telemetry[$0] != nil }) { continue }
            guard let pane = lane.panes.first else { continue }
            let kind: Kind
            switch pane.kind {
            case .pty: kind = .session
            case .web: kind = .web
            case .placeholder: kind = .placeholder
            }
            let live = lane.panes.contains { $0.state == .live }
            let state: AgentState = kind == .session ? .exited : .unknown
            let entry = Entry(
                id: "lane:\(lane.id)",
                kind: kind,
                title: laneTitle(lane),
                laneId: lane.id,
                sessionId: sessionIds.first,
                state: state,
                glyph: kind == .session ? state.glyph : "",
                chip: kind == .session ? state.chipText : "",
                badge: kind == .session ? "gone" : (live ? "web" : "evicted"),
                badgeIsThroughput: false,
                age: SessionTelemetry.age(
                    since: Date(timeIntervalSince1970: Double(lane.lastFocusAt) / 1000), now: now),
                // A pty lane the registry has no session for is a lane whose
                // process is gone, however live its pane still is — counting it
                // as running would put a phantom in the group's header.
                isRunning: kind == .session ? false : live,
                pinned: lane.keepLive,
                createdAt: Double(lane.createdAt) / 1000,
                activityAt: Double(lane.lastFocusAt) / 1000)
            grouped[group(for: lane), default: []].append(entry)
        }

        // Group order is alphabetical whatever the sort says. The sort control
        // orders sessions *within* a project; a browser whose project headers
        // jump around every time output arrives is not a browser.
        var out: [Row] = []
        for path in grouped.keys.sorted() {
            let kept = grouped[path]!.filter { matches($0, controls) }
            guard !kept.isEmpty else { continue }
            let collapsed = controls.collapsed.contains(path)
            out.append(.group(Group(
                path: path,
                running: kept.filter(\.isRunning).count,
                blocked: kept.filter(\.needsAttention).count,
                total: kept.count,
                collapsed: collapsed)))
            guard !collapsed else { continue }
            out.append(contentsOf: sorted(kept, controls).map(Row.entry))
        }
        return out
    }

    /// The group a lane files under: its project tag, abbreviated the same way a
    /// session's cwd is, so a web lane opened from `~/code/max-pane` lands beside
    /// the agent that opened it.
    static func group(for lane: Lane) -> String {
        guard let root = lane.projectRoot, !root.isEmpty else { return looseWebGroup }
        return SessionTelemetry.abbreviate(root)
    }

    static func displayTitle(_ t: SessionTelemetry) -> String {
        if !t.title.isEmpty { return t.title }
        if !t.command.isEmpty { return t.command }
        return t.sessionId
    }

    /// A web lane is best identified by its host; the full URL never fits.
    static func laneTitle(_ lane: Lane) -> String {
        if let title = lane.title, !title.isEmpty { return title }
        if let url = lane.panes.first?.url { return URL(string: url)?.host ?? url }
        return "untitled"
    }

    static func matches(_ entry: Entry, _ controls: Controls) -> Bool {
        switch controls.scope {
        case .all: break
        case .running: if !entry.isRunning { return false }
        case .waiting:
            // "Waiting" is every *session* that is not producing output — the
            // set you scan to find the agent that stopped asking. A web lane is
            // never waiting on you, so it is not in it.
            if entry.kind != .session { return false }
            if entry.state == .working || entry.state == .exited { return false }
        case .attached: if entry.laneId == nil { return false }
        }
        let q = controls.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return entry.title.lowercased().contains(q)
            || (entry.sessionId?.lowercased().contains(q) ?? false)
    }

    static func sorted(_ entries: [Entry], _ controls: Controls) -> [Entry] {
        let ascending = !controls.descending
        return entries.sorted { a, b in
            // Blocked first, under every sort and in both directions. An agent
            // that has drawn a prompt and stopped is the reason this list is on
            // screen; a sort order that can bury it makes the list a list.
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            let lhs: Bool
            switch controls.sort {
            case .created:
                if a.createdAt == b.createdAt { return a.id < b.id }
                lhs = a.createdAt < b.createdAt
            case .recent:
                if a.activityAt == b.activityAt { return a.id < b.id }
                lhs = a.activityAt < b.activityAt
            case .name:
                let x = a.title.lowercased(), y = b.title.lowercased()
                if x == y { return a.id < b.id }
                lhs = x < y
            case .attention:
                // `AgentState.rank`: blocked, working, done, idle, unknown.
                // Rank ascending is the useful direction, so the arrow flips it
                // rather than burying the rows that matter.
                if a.state.rank != b.state.rank {
                    return ascending ? a.state.rank > b.state.rank : a.state.rank < b.state.rank
                }
                // Inside a rank, recency — so the row you just looked at stays
                // put instead of swapping with its peer.
                if a.activityAt == b.activityAt { return a.id < b.id }
                lhs = a.activityAt < b.activityAt
            }
            return ascending ? lhs : !lhs
        }
    }

    // MARK: - counts for the footer

    /// "2/10 SESSIONS" — how many of everything Relay is running are on the
    /// strip. The second number is the bar's "10 sessions"; the first is the one
    /// that tells you what you are *not* watching.
    static func footerCount(telemetry: [String: SessionTelemetry], lanes: [Lane]) -> String {
        let total = telemetry.count
        let attachedIds = Set(lanes.flatMap(\.panes).compactMap(\.relaySessionId))
        let on = telemetry.keys.filter { attachedIds.contains($0) }.count
        let word = total == 1 ? "SESSION" : "SESSIONS"
        return "\(on)/\(total) \(word)"
    }

    /// Sessions waiting on a human, for the footer's alarm.
    static func blockedCount(_ telemetry: [String: SessionTelemetry]) -> Int {
        telemetry.values.filter { $0.isRunning && $0.needsAttention }.count
    }
}
