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

    /// The collapse key for the bookmarks section. Not a project path, and in
    /// the private-use plane for the same reason `looseWebGroup` is: a real
    /// directory can be called anything, and the one thing it cannot be called
    /// is this.
    static let bookmarksGroup = "\u{FFFE}bookmarks"

    /// The `// LOCAL` section header's path: not a directory, and not a
    /// server. It exists only while at least one server is configured, so
    /// this Mac and each server read as parallel blocks; with none, the
    /// sidebar is exactly what it was before servers existed.
    static let localSection = "\u{FFFD}local"

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
        /// The pane inside that lane this row is actually about.
        ///
        /// A lane holds a stack since ⇧⌘D, and a row names one session — so
        /// "the lane" is not a precise enough answer for a click that hands over
        /// the keyboard. Resolved here rather than in the view because it is the
        /// same kind of decision as every other column: a fact about the rows,
        /// worth a test.
        var paneId: String?
        /// The session this row is about, on whichever server; nil for a web
        /// lane. `sessionId` is its id alone, for the tooltip and the clipboard.
        var sessionKey: SessionKey?
        var sessionId: String? { sessionKey?.id }
        /// The remote server the session is on, for the row's server chip;
        /// nil for this Mac, and then there is no chip.
        var server: String? { sessionKey?.server }
        /// The session's server is not answering: the row goes to the
        /// at-rest grey, carries no state, and reads `offline` where the
        /// state text was. What it last said is not repeated as if it were
        /// still so.
        var offline = false
        /// `SessionTelemetry.state` — relay's verdict corrected by the title —
        /// and the only source for the chip.
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
        /// A web row's sound. Anything but `.silent` takes the leading
        /// square's place with the speaker (the owner's design, ADR-0035). A
        /// session's row never carries it: its square is agent state, and
        /// that is not to be covered; a page split under a terminal is
        /// reached from the lane header and the pane's own chrome.
        var audio: AudioMark = .silent

        var needsAttention: Bool { state == .blocked }
    }

    /// Where a click on a folded header's state text goes: the first row
    /// under it in that state, in the order the rows would be drawn. The
    /// same three facts a row's click uses — a lane to reveal, or a session
    /// to attach — and nothing that changes on the age tick, so a folded
    /// header does not rebuild every second.
    struct Target: Equatable {
        var laneId: String?
        var paneId: String?
        var sessionKey: SessionKey?
    }

    /// One piece of a folded header's roll-up: `1 BLOCKED` in the blocked
    /// green, `2 DONE` in orange, `3 WORKING` in the working green, and the
    /// grey tail — `4 LANES HIDDEN`, `2 RUNNING` — with no state at all.
    struct Segment: Equatable {
        var text: String
        var state: AgentState?
    }

    struct Group: Equatable {
        var path: String
        var running: Int
        var blocked: Int
        var total: Int
        /// Rows under this header that are DONE and WORKING. Counted always,
        /// read only while the header is folded: an open group's rows say it
        /// themselves.
        var done = 0
        var working = 0
        var collapsed: Bool
        /// What the header says instead of the session count. One caller: the
        /// bookmarks section, whose rows are not sessions and for which
        /// "0 CLOSED" would be both true and meaningless.
        var countOverride: String?
        /// How the remote server this group is on is doing; nil for a local
        /// group, and for a remote whose state is not known. Printed in the
        /// header when it is anything but connected: a header that said
        /// CONNECTED all day would spend a word on something always true.
        var serverState: ServerState?
        /// Why the server is not connected, in one line; the header's
        /// tooltip. Nil while connected. Never carries the token.
        var serverError: String?
        /// How many lanes this header's collapse is keeping off the strip
        /// (ADR-0024). Zero when it is open, when the setting is off, and
        /// when every lane under it is held on screen by something else: a
        /// dock, or a pane from a group that is still open.
        var hiddenLanes = 0
        /// The lanes this folded header is hiding that are making sound, by
        /// id. Anything here puts a speaker on the header, and a click on it
        /// mutes them: a sound from a lane that is not on the strip has
        /// nowhere else to be found.
        var audibleLanes: [String] = []
        /// The first BLOCKED and the first DONE row under a folded header, for
        /// a click on `N BLOCKED` / `N DONE` to go to. Nil while open, and
        /// when there is none.
        var blockedTarget: Target?
        var doneTarget: Target?

        /// A section header — a server's, or `// LOCAL` — rather than a
        /// project group: it heads a block and has no rows of its own.
        /// Folding one folds every project under it.
        var isSection: Bool { isServer || isLocalSection }
        var isLocalSection: Bool { path == SidebarModel.localSection }

        /// The server's state as a chip, when it is anything but connected:
        /// `RECONNECTING`, `UNREACHABLE`, `TOKEN REFUSED`. A header that said
        /// CONNECTED all day would spend a word on something always true.
        var stateChip: String? {
            guard isServer, let serverState, serverState.isOff else { return nil }
            return serverState.label
        }

        /// The server this group is on — `yorkshire` of `yorkshire:/home` —
        /// or nil for a group on this Mac.
        var server: String? { LaneHeaderPath.splitServer(path)?.server }

        /// The server's own header — `yorkshire:` with no path — which sits
        /// above that server's project groups and carries its state. One per
        /// enabled server, whether or not it has sessions; a click on it
        /// opens Settings › Servers rather than folding anything.
        var isServer: Bool { LaneHeaderPath.splitServer(path).map { $0.path.isEmpty } ?? false }

        static func serverPath(_ name: String) -> String { name + ":" }

        /// `~/code/max-pane` → `~/CODE/MAX-PANE`; the loose-web sentinel → `WEB`.
        var header: String {
            // The path as it really is. Upper-casing it was treating a
            // directory as a label, and paths are case-sensitive data — a group
            // called ~/CODE/MAX-PANE names nothing on this disk.
            if path == SidebarModel.looseWebGroup { return "Web" }
            if path == SidebarModel.bookmarksGroup { return "Bookmarks" }
            if isLocalSection { return "LOCAL" }
            if isServer { return (server ?? path).uppercased() }
            // A remote project is its path on that server. The section above
            // it and the chip on every row say which server; `WSL:` in front
            // of each path as well was the same word three times. The path
            // is as the server gave it — never `~` for this Mac's `$HOME`.
            if let remote = LaneHeaderPath.splitServer(path) { return remote.path }
            return path
        }

        /// The grey count: what is under the header, with no state in it.
        ///
        /// An open group says what it always said, BLOCKED included, because
        /// its rows are on show and the header's one word is a summary. A
        /// folded group is different: its rows are gone, so every state they
        /// carried rolls up onto the header as its own segment (`rollUp`),
        /// and this is only the tail — how many lanes the fold is holding
        /// off the strip, or how many sessions are in it.
        var countText: String {
            if let countOverride { return countOverride }
            // A collapse that is holding lanes off the strip says so, in the
            // place the count was: what is missing from the strip is the
            // thing to know.
            if hiddenLanes > 0 { return "\(hiddenLanes) LANE\(hiddenLanes == 1 ? "" : "S") HIDDEN" }
            if isSection {
                // The section's line: what it holds. `total` is its session
                // count across every project in it. A server's state is its
                // own chip beside this (`stateChip`), not a word in its place.
                if blocked > 0, !collapsed { return "\(blocked) BLOCKED" }
                return "\(total) SESSION\(total == 1 ? "" : "S")"
            }
            // Under a server that is not answering, RUNNING is a claim nobody
            // can back. What is known is how many there were.
            if serverIsOffline { return "\(total) OFFLINE" }
            if blocked > 0, !collapsed { return "\(blocked) BLOCKED" }
            return running > 0 ? "\(running) RUNNING" : "\(total) CLOSED"
        }

        /// `2 BLOCKED`, beside the grey count, on a folded header. An open
        /// header's `countText` already leads with it.
        var blockedText: String? {
            guard collapsed, blocked > 0 else { return nil }
            return "\(blocked) BLOCKED"
        }

        /// `2 DONE`, on a folded header: the one state the owner set a colour
        /// aside for, and the one a fold used to swallow.
        var doneText: String? {
            guard collapsed, done > 0 else { return nil }
            return "\(done) DONE"
        }

        /// `2 WORKING`, on a folded header. An open group never says it: the
        /// green mark on each row already does.
        var workingText: String? {
            guard collapsed, working > 0 else { return nil }
            return "\(working) WORKING"
        }

        /// The folded header's right-hand slot, loudest first: BLOCKED, then
        /// DONE, then WORKING, then the grey count. An open header is one
        /// segment, its `countText`. The view drops the grey tail first when
        /// the header has not the width for all of it.
        var rollUp: [Segment] {
            var out: [Segment] = []
            if let blockedText { out.append(Segment(text: blockedText, state: .blocked)) }
            if let doneText { out.append(Segment(text: doneText, state: .done)) }
            if let workingText { out.append(Segment(text: workingText, state: .working)) }
            out.append(Segment(text: countText, state: nil))
            return out
        }

        /// `1 BLOCKED · 2 DONE · 3 LANES HIDDEN`: the roll-up as one line, for
        /// tests and the tooltip.
        var rollUpText: String { rollUp.map(\.text).joined(separator: " · ") }

        /// The state the header's leading mark takes: the brightest one under
        /// a folded header, by the row rule — blocked, else done, else
        /// working — and nil (grey) for anything else, and for an open group.
        var markState: AgentState? {
            guard collapsed else { return nil }
            if blocked > 0 { return .blocked }
            if done > 0 { return .done }
            if working > 0 { return .working }
            return nil
        }

        /// The header's state is worth a colour: the server is not connected.
        var serverIsOff: Bool { isServer && (serverState?.isOff ?? false) }
        /// A project group on a server that is not connected.
        var serverIsOffline: Bool { !isSection && (serverState?.isOff ?? false) }
    }

    /// One node of the bookmarks tree, as a row.
    ///
    /// Flat with a depth, because `Bookmark` arrives flat with a depth and the
    /// table is flat — see the wire type's doc for why the tree is never
    /// rebuilt on this side.
    struct BookmarkRow: Equatable {
        var id: String
        /// The folder it is in, `nil` for a row on the bar itself.
        ///
        /// Derivable from `depth` by walking the list, and carried anyway
        /// because the drop target has to count a row's siblings and a rule that
        /// says "rebuild the tree first" is one nobody will follow the second
        /// time.
        var parentId: String?
        var title: String
        /// The host and path for a page; how many things are in it for a
        /// folder.
        var detail: String
        /// `nil` for a folder.
        var url: String?
        var depth: Int
        var isFolder: Bool
        var collapsed: Bool
    }

    enum Row: Equatable {
        case group(Group)
        case entry(Entry)
        case bookmark(BookmarkRow)
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
        telemetry: [SessionKey: SessionTelemetry],
        created: [SessionKey: Double] = [:],
        bookmarks: [Bookmark] = [],
        controls: Controls = Controls(),
        servers: [String: ServerState] = [:],
        serverErrors: [String: String] = [:],
        hiddenLanes: Set<String> = [],
        audio: [String: AudioMark] = [:],
        now: Date = Date()
    ) -> [Row] {
        // The *pane* as well as the lane: a click on a row has to be able to
        // hand the keyboard to the pane whose session the row names, and in a
        // split lane that is not the same thing as the lane's first pane.
        var laneForSession: [SessionKey: (lane: Lane, pane: Pane)] = [:]
        for lane in lanes {
            for pane in lane.panes {
                if let key = pane.sessionKey, laneForSession[key] == nil {
                    laneForSession[key] = (lane, pane)
                }
            }
        }

        var grouped: [String: [Entry]] = [:]
        for (key, t) in telemetry {
            let attached = laneForSession[key]
            let lane = attached?.lane
            let split = splitGlyph(displayTitle(t))
            // Only where pty-host has no opinion at all does the agent's own
            // title mark get to fill the glyph column — and never the chip.
            // An offline row says `—`: not the agent's own title mark, which
            // is as stale as everything else the server last said.
            let glyph = t.isOffline
                ? "—"
                : (t.state == .unknown ? (split.glyph ?? t.state.glyph) : t.state.glyph)
            var entry = Entry(
                id: "session:\(key)",
                kind: .session,
                title: split.title,
                laneId: lane?.id,
                paneId: attached?.pane.id,
                sessionKey: key,
                state: t.state,
                glyph: glyph,
                chip: t.state.chipText,
                badge: t.badgeText,
                badgeIsThroughput: t.badgeIsThroughput,
                age: t.ageText,
                isRunning: t.isRunning,
                pinned: lane?.keepLive ?? false,
                createdAt: created[key] ?? (t.lastActivity?.timeIntervalSince1970 ?? 0),
                activityAt: t.lastActivity?.timeIntervalSince1970 ?? 0)
            entry.offline = t.isOffline
            grouped[t.groupPath, default: []].append(entry)
        }

        for lane in lanes {
            // A pty lane whose session Relay has already forgotten still deserves
            // a row; without one the strip would hold a lane the browser denies.
            let sessionKeys = lane.panes.compactMap(\.sessionKey)
            if sessionKeys.contains(where: { telemetry[$0] != nil }) { continue }
            guard let pane = lane.panes.first else { continue }
            let kind: Kind
            switch pane.kind {
            case .pty: kind = .session
            case .web: kind = .web
            case .placeholder: kind = .placeholder
            }
            let live = lane.panes.contains { $0.state == .live }
            // A remote lane the registry has never seen a session for, on a
            // server that is not answering: the server was gone at launch.
            // That is `offline`, not `gone` — nobody knows it exited.
            let offline = kind == .session
                && (sessionKeys.first?.server.flatMap { servers[$0] }?.isOff ?? false)
            let state: AgentState = (kind == .session && !offline) ? .exited : .unknown
            var entry = Entry(
                id: "lane:\(lane.id)",
                kind: kind,
                title: laneTitle(lane),
                laneId: lane.id,
                // This row is the lane, not a session — so it names the pane the
                // lane's own header names, which is its first.
                paneId: pane.id,
                sessionKey: sessionKeys.first,
                state: state,
                glyph: kind == .session ? (offline ? "—" : state.glyph) : "",
                chip: kind == .session ? state.chipText : "",
                badge: kind == .session ? (offline ? "offline" : "gone") : (live ? "web" : "evicted"),
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
            entry.offline = offline
            if kind != .session { entry.audio = audio[lane.id] ?? .silent }
            grouped[group(for: lane), default: []].append(entry)
        }

        // Group order is alphabetical whatever the sort says. The sort control
        // orders sessions *within* a project; a browser whose project headers
        // jump around every time output arrives is not a browser.
        // The bar, above the sessions.
        //
        // # Why the bookmarks live here and not in a window of their own
        //
        // Because this is the surface that already groups things, and because
        // "the strip is the bookmarks bar" was only ever wrong about the part
        // you are *not* looking at. A bar is eight folders that are always
        // where you left them; a window you have to open is a folder you have
        // to remember. The sidebar is already open, already vertical — which is
        // what a 420 pt column has room for — and already collapses a section
        // you are not using.
        //
        // What it is not is a fourth palette. Typing at a bookmark is ⌘O's job
        // and always was; this is for the eight targets the hand already knows.
        //
        // Local groups first, alphabetical; then each remote server, by
        // name, as its own header (its state, and a click to Settings) with
        // its project groups under it — so a box's lanes read as one block
        // rather than sorting in among the local paths by the accident of
        // where its name falls against `~` and `/`. A server the registry
        // watches (`servers`) gets a header with or without sessions: refused
        // or reconnecting is a header with the state and no rows. A disabled
        // server is not in `servers` and not here.
        var out: [Row] = bookmarkRows(bookmarks, controls)
        var byServer: [String: [String]] = [:]
        var local: [String] = []
        for path in grouped.keys.sorted() {
            if let server = LaneHeaderPath.splitServer(path)?.server {
                byServer[server, default: []].append(path)
            } else {
                local.append(path)
            }
        }
        // Lanes, not rows: a split lane is two rows and one lane, and the
        // header counts what is missing from the strip.
        func hiding(_ entries: [Entry]) -> Int {
            guard !hiddenLanes.isEmpty else { return 0 }
            return Set(entries.compactMap(\.laneId)).intersection(hiddenLanes).count
        }
        func sounding(_ entries: [Entry]) -> [String] {
            guard !hiddenLanes.isEmpty, !audio.isEmpty else { return [] }
            return Set(entries.compactMap(\.laneId)).intersection(hiddenLanes)
                .filter { audio[$0] == .audible }.sorted()
        }
        // The first row in a state, in the order the rows would be drawn
        // under the header: for a project its sort order, for a section each
        // project in turn. What a click on the folded header's `N BLOCKED`
        // or `N DONE` goes to.
        func target(_ entries: [Entry], in state: AgentState) -> Target? {
            entries.first { $0.state == state }
                .map { Target(laneId: $0.laneId, paneId: $0.paneId, sessionKey: $0.sessionKey) }
        }
        func rolledUp(_ group: Group, over ordered: [Entry]) -> Group {
            var group = group
            group.done = ordered.filter { $0.state == .done }.count
            group.working = ordered.filter { $0.state == .working }.count
            guard group.collapsed else { return group }
            group.blockedTarget = target(ordered, in: .blocked)
            group.doneTarget = target(ordered, in: .done)
            return group
        }
        func emit(_ path: String) {
            let kept = grouped[path]!.filter { matches($0, controls) }
            guard !kept.isEmpty else { return }
            let collapsed = controls.collapsed.contains(path)
            let ordered = sorted(kept, controls)
            out.append(.group(rolledUp(Group(
                path: path,
                running: kept.filter(\.isRunning).count,
                blocked: kept.filter(\.needsAttention).count,
                total: kept.count,
                collapsed: collapsed,
                countOverride: nil,
                serverState: LaneHeaderPath.splitServer(path).flatMap { servers[$0.server] },
                hiddenLanes: collapsed ? hiding(grouped[path]!) : 0,
                audibleLanes: collapsed ? sounding(grouped[path]!) : []), over: ordered)))
            guard !collapsed else { return }
            out.append(contentsOf: ordered.map(Row.entry))
        }
        // A section's rows in drawn order: each project in turn, sorted.
        func ordered(_ paths: [String]) -> [Entry] {
            paths.flatMap { sorted(grouped[$0]!.filter { matches($0, controls) }, controls) }
        }
        // `// LOCAL`, only beside at least one server: the blocks are then
        // parallel. With none configured there is no header and nothing
        // else here changes, pixel for pixel.
        let localFolded = !servers.isEmpty && controls.collapsed.contains(localSection)
        if !servers.isEmpty {
            let entries = local.filter { $0 != looseWebGroup }
                .flatMap { grouped[$0]! }.filter { $0.kind == .session && matches($0, controls) }
            out.append(.group(rolledUp(Group(
                path: localSection,
                running: entries.filter(\.isRunning).count,
                blocked: entries.filter(\.needsAttention).count,
                total: entries.count,
                collapsed: localFolded,
                countOverride: nil,
                serverState: nil,
                hiddenLanes: localFolded
                    ? hiding(local.filter { $0 != looseWebGroup }.flatMap { grouped[$0]! }) : 0,
                audibleLanes: localFolded
                    ? sounding(local.filter { $0 != looseWebGroup }.flatMap { grouped[$0]! }) : []),
                over: ordered(local.filter { $0 != looseWebGroup }).filter { $0.kind == .session })))
        }
        // A folded section folds every project under it. The loose web group
        // is under no section — `// LOCAL` never counted it — and stays.
        for path in local where !localFolded || path == looseWebGroup { emit(path) }
        for server in Set(servers.keys).union(byServer.keys).sorted() {
            let paths = byServer[server] ?? []
            let entries = paths.flatMap { grouped[$0]! }.filter { matches($0, controls) }
            let folded = controls.collapsed.contains(Group.serverPath(server))
            out.append(.group(rolledUp(Group(
                path: Group.serverPath(server),
                running: entries.filter(\.isRunning).count,
                blocked: entries.filter(\.needsAttention).count,
                total: entries.count,
                collapsed: folded,
                countOverride: nil,
                serverState: servers[server],
                serverError: serverErrors[server],
                hiddenLanes: folded ? hiding(paths.flatMap { grouped[$0]! }) : 0,
                audibleLanes: folded ? sounding(paths.flatMap { grouped[$0]! }) : []), over: ordered(paths))))
            guard !folded else { continue }
            for path in paths { emit(path) }
        }
        return out
    }

    /// The bookmarks section: a header, then the tree, folders foldable.
    ///
    /// Returns nothing at all when there are no bookmarks. An empty section is
    /// a row that can only ever say "you have none", every launch, above the
    /// thing the sidebar is actually for.
    ///
    /// The sort and scope controls are deliberately not applied. They are about
    /// sessions — "running", "waiting on you", newest first — and none of them
    /// means anything about a kept page; more to the point, the order of a bar
    /// *is* the thing, and a control that reordered it would be undoing the one
    /// property that lets a hand find a folder without reading it. The query
    /// box does apply, because "where did I put that" is the same question here
    /// as it is over sessions.
    static func bookmarkRows(_ bookmarks: [Bookmark], _ controls: Controls) -> [Row] {
        guard !bookmarks.isEmpty else { return [] }
        let query = controls.query.trimmingCharacters(in: .whitespaces).lowercased()

        // How many things each folder holds, so a collapsed folder still says
        // how much it is hiding. Counted over the whole subtree rather than the
        // immediate children: `Work` holding one folder of forty reads as
        // "1 ITEM" otherwise.
        var subtree: [String: Int] = [:]
        var ancestors: [String] = []
        var depthOf: [String: Int] = [:]
        for row in bookmarks {
            let depth = Int(row.depth)
            ancestors.removeLast(max(0, ancestors.count - depth))
            for id in ancestors { subtree[id, default: 0] += 1 }
            if row.isFolder { ancestors.append(row.id); depthOf[row.id] = depth }
        }

        // A bookmark survives the query on its own; a folder survives on
        // anything beneath it, which is why this is computed bottom-up before
        // anything is emitted.
        var keep: Set<String> = []
        if !query.isEmpty {
            var stack: [(id: String, depth: Int)] = []
            for row in bookmarks {
                let depth = Int(row.depth)
                stack.removeLast(max(0, stack.count - depth))
                let hit = row.title.lowercased().contains(query)
                    || (row.url?.lowercased().contains(query) ?? false)
                if hit && !row.isFolder {
                    keep.insert(row.id)
                    for up in stack { keep.insert(up.id) }
                }
                if row.isFolder { stack.append((row.id, depth)) }
            }
            if keep.isEmpty { return [] }
        }

        let sectionCollapsed = controls.collapsed.contains(bookmarksGroup)
        let pages = bookmarks.filter { !$0.isFolder && (query.isEmpty || keep.contains($0.id)) }
        var out: [Row] = [.group(Group(
            path: bookmarksGroup,
            running: 0, blocked: 0, total: pages.count,
            collapsed: sectionCollapsed,
            countOverride: "\(pages.count) KEPT"))]
        guard !sectionCollapsed else { return out }

        // The depth at which everything is hidden, because a folder above it is
        // folded. `Int.max` means nothing is.
        //
        // Strictly less than, not less-than-or-equal: folding a folder at depth
        // 0 hides depth 1 downwards, and a row *at* depth 1 is the first thing
        // that has to stay hidden. `<=` there reopened the fold on its own
        // first child, which looked like the triangle doing nothing.
        var hiddenBelow = Int.max
        for row in bookmarks {
            let depth = Int(row.depth)
            if depth < hiddenBelow { hiddenBelow = Int.max }
            guard depth < hiddenBelow else { continue }
            if !query.isEmpty && !keep.contains(row.id) { continue }
            // A search opens every folder it matched inside. A folded folder
            // with a hit in it is a search that found nothing, as far as the
            // screen is concerned.
            let folded = query.isEmpty && controls.collapsed.contains(row.id)
            out.append(.bookmark(BookmarkRow(
                id: row.id,
                parentId: row.parentId,
                title: row.title,
                detail: row.isFolder
                    ? Self.itemCount(subtree[row.id] ?? 0)
                    : row.url.map(OmniText.handle) ?? "",
                url: row.url,
                depth: depth,
                isFolder: row.isFolder,
                collapsed: folded)))
            if row.isFolder && folded { hiddenBelow = depth + 1 }
        }
        return out
    }

    /// `1 ITEM`, `12 ITEMS`. The header above it counts in the singular too,
    /// and a bar with one thing on it is the state every bar starts in.
    static func itemCount(_ n: Int) -> String {
        "\(n) ITEM" + (n == 1 ? "" : "S")
    }

    // MARK: - reordering

    /// A row's place among the siblings being drawn, for a menu that has to say
    /// whether there is anywhere left to move it.
    static func siblingPlace(rows: [Row], id: String) -> (index: Int, count: Int)? {
        var kept: [BookmarkRow] = []
        for row in rows {
            if case .bookmark(let b) = row { kept.append(b) }
        }
        guard let mine = kept.first(where: { $0.id == id }) else { return nil }
        let siblings = kept.filter { $0.parentId == mine.parentId }
        guard let at = siblings.firstIndex(where: { $0.id == id }) else { return nil }
        return (at, siblings.count)
    }

    /// Where a drag would put the row if it were dropped here.
    struct DropTarget: Equatable {
        /// The folder it lands in; `nil` is the bar itself.
        var parentId: String?
        /// Where among that folder's children — counted *without* the dragged
        /// row, which is the convention `Core::move_bookmark` takes. `nil` is
        /// the end.
        var index: UInt32?
    }

    /// Resolve an `NSTableView` drop onto a place in the tree, or `nil` for a
    /// drop that should not be offered at all.
    ///
    /// This is the whole of the drag that is worth testing, and the reason it is
    /// a function over rows rather than code inside `acceptDrop`: the table
    /// speaks in row numbers over a *flat* list with folders folded into it, the
    /// ledger speaks in (parent, index) over siblings, and every interesting
    /// mistake lives in the translation.
    ///
    /// ## The rule for a gap
    ///
    /// **The gap above a row belongs to that row's sibling list, at that row's
    /// place in it.** The alternative — read the row *above* the gap — is what
    /// makes an outline impossible to drop into: the gap between the last child
    /// of a folder and the next folder is ambiguous, it means both "last inside"
    /// and "after the folder", and only one of the two can be a gap. Taking the
    /// row below resolves every such gap outwards, to the shallower level, which
    /// is the one there is otherwise no way to reach. "Last inside" is reachable
    /// the other way, by dropping *onto* the folder, which appends.
    ///
    /// Anything below the last kept row is the end of the bar; anything in the
    /// sessions underneath is not a drop at all.
    static func dropTarget(
        rows: [Row], dragging id: String, row target: Int, onto: Bool
    ) -> DropTarget? {
        let kept: [(index: Int, row: BookmarkRow)] = rows.enumerated().compactMap {
            guard case .bookmark(let b) = $0.element else { return nil }
            return ($0.offset, b)
        }
        guard let first = kept.first, let last = kept.last,
              let dragged = kept.first(where: { $0.row.id == id })?.row
        else { return nil }

        // Among the rows on screen, which is the same list as among all of them:
        // folding a folder hides its descendants, never a row's siblings.
        func siblingIndex(of wanted: BookmarkRow) -> Int {
            var n = 0
            for k in kept {
                if k.row.id == wanted.id { break }
                if k.row.parentId == wanted.parentId { n += 1 }
            }
            return n
        }

        // A folder dropped inside itself is the one move that detaches a branch
        // from the bar. The ledger refuses it too — this refuses it a step
        // earlier, so the drop indicator never appears somewhere the drop would
        // fail.
        func insideTheDraggedRow(_ parent: String?) -> Bool {
            var cursor = parent
            for _ in 0..<64 {
                guard let node = cursor else { return false }
                if node == id { return true }
                cursor = kept.first(where: { $0.row.id == node })?.row.parentId
            }
            return false
        }

        if onto {
            guard target >= first.index, target <= last.index,
                  case .bookmark(let folder) = rows[target],
                  folder.isFolder, folder.id != id, !insideTheDraggedRow(folder.id)
            else { return nil }
            return DropTarget(parentId: folder.id, index: nil)
        }

        guard target <= last.index + 1 else { return nil }
        // A gap above the section header is the top of the bar, not a refusal:
        // it is where the pointer is when you drag the first folder upwards.
        let at = max(target, first.index)

        var parent: String?
        var index: Int
        if at <= last.index, case .bookmark(let below) = rows[at] {
            parent = below.parentId
            index = siblingIndex(of: below)
        } else {
            parent = nil
            index = kept.filter { $0.row.parentId == nil }.count
        }
        guard !insideTheDraggedRow(parent) else { return nil }

        if dragged.parentId == parent {
            let from = siblingIndex(of: dragged)
            // The table counted a list that still has the dragged row in it.
            if from < index { index -= 1 }
            // Both gaps either side of a row put it back where it is. Refusing
            // keeps the indicator off a move that would do nothing.
            if index == from { return nil }
        }
        return DropTarget(parentId: parent, index: UInt32(index))
    }

    /// The group a lane files under: its project tag, abbreviated the same way a
    /// session's cwd is, so a web lane opened from `~/code/max-pane` lands beside
    /// the agent that opened it.
    static func group(for lane: Lane) -> String {
        guard let root = lane.projectRoot, !root.isEmpty else { return looseWebGroup }
        return SessionTelemetry.abbreviate(root)
    }

    /// True when a row that is in both lists now says something different about
    /// what its session is doing — state, chip or whether the badge is a rate.
    ///
    /// The sidebar fades on this and not on every change: the age column moves
    /// every second, and a list that shimmers once a second is noise.
    static func statusChanged(from old: [Row], to new: [Row]) -> Bool {
        var before: [String: Entry] = [:]
        for case .entry(let e) in old { before[e.id] = e }
        for case .entry(let e) in new {
            guard let was = before[e.id] else { continue }
            if was.state != e.state || was.chip != e.chip || was.offline != e.offline
                || was.badgeIsThroughput != e.badgeIsThroughput || was.audio != e.audio { return true }
        }
        // A folded header's speaker arriving or leaving, or its roll-up
        // changing: a state appearing on, or clearing from, a fold.
        var headers: [String: (sounding: Bool, rollUp: String)] = [:]
        for case .group(let g) in old { headers[g.path] = (!g.audibleLanes.isEmpty, g.rollUpText) }
        for case .group(let g) in new {
            guard let was = headers[g.path] else { continue }
            if was.sounding != !g.audibleLanes.isEmpty || was.rollUp != g.rollUpText { return true }
        }
        // A server going quiet or coming back is a change of state too.
        var chips: [String: String?] = [:]
        for case .group(let g) in old where g.isServer { chips[g.path] = g.stateChip }
        for case .group(let g) in new where g.isServer {
            if let was = chips[g.path], was != g.stateChip { return true }
        }
        return false
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

    // MARK: - which lanes a collapse hides (ADR-0024)

    /// The sidebar groups a lane files under: where its rows are.
    ///
    /// The same rule `rows` follows, so a header hides exactly the lanes whose
    /// rows fold under it. A session the registry knows files under its own
    /// directory, which is its cwd and may not be the lane's project tag; a
    /// lane none of whose sessions the registry knows — a web lane, a
    /// terminal whose session has gone, a remote one not heard from yet —
    /// files under its tag. A split lane can therefore be in two groups.
    static func groups(of lane: Lane, telemetry: [SessionKey: SessionTelemetry]) -> Set<String> {
        let known = lane.panes.compactMap(\.sessionKey).compactMap { telemetry[$0]?.groupPath }
        return known.isEmpty ? [group(for: lane)] : Set(known)
    }

    /// The section a group sits under: its server's header, or `// LOCAL`.
    static func section(of group: String) -> String {
        LaneHeaderPath.splitServer(group).map { Group.serverPath($0.server) } ?? localSection
    }

    /// Whether `group` is folded, by its own header or by its section's.
    ///
    /// `// LOCAL` exists only beside a server (`hasServers`). Without one
    /// there is no header to click, so a stored fold of it folds nothing —
    /// otherwise removing the last server would strand every local lane
    /// behind a header that is no longer drawn.
    static func isFolded(_ group: String, collapsed: Set<String>, hasServers: Bool) -> Bool {
        if collapsed.contains(group) { return true }
        let section = section(of: group)
        if section == localSection && !hasServers { return false }
        return collapsed.contains(section)
    }

    /// The lanes the collapsed headers take off the strip.
    ///
    /// A lane goes only when **every** group it is in is folded: a split
    /// lane with one pane in an open group is still a lane you are working
    /// in. An untagged lane — the loose web group, `-` in `maxpane ls` —
    /// never goes: it belongs to no project, so no project being put away
    /// can take it, and folding `Web` folds its rows as it always did.
    static func hiddenLanes(
        lanes: [Lane], telemetry: [SessionKey: SessionTelemetry],
        collapsed: Set<String>, hasServers: Bool
    ) -> Set<String> {
        guard !collapsed.isEmpty else { return [] }
        var out: Set<String> = []
        for lane in lanes {
            let groups = groups(of: lane, telemetry: telemetry)
            if groups.contains(looseWebGroup) { continue }
            if groups.allSatisfy({ isFolded($0, collapsed: collapsed, hasServers: hasServers) }) {
                out.insert(lane.id)
            }
        }
        return out
    }

    /// The headers to open so that `lane` is on the strip again: every
    /// folded key that covers one of its groups. Opening all of them, not
    /// just enough of them, because "the group expands, then you are there"
    /// should leave the sidebar showing the row you came for.
    static func keysToExpand(
        toShow lane: Lane, telemetry: [SessionKey: SessionTelemetry], collapsed: Set<String>
    ) -> Set<String> {
        var keys: Set<String> = []
        for group in groups(of: lane, telemetry: telemetry) {
            keys.formUnion([group, section(of: group)])
        }
        return keys.intersection(collapsed)
    }

    // MARK: - counts for the footer

    /// "2/10 SESSIONS" — how many of everything Relay is running are on the
    /// strip. The second number is the bar's "10 sessions"; the first is the one
    /// that tells you what you are *not* watching.
    static func footerCount(telemetry: [SessionKey: SessionTelemetry], lanes: [Lane]) -> String {
        let total = telemetry.count
        let attachedKeys = Set(lanes.flatMap(\.panes).compactMap(\.sessionKey))
        let on = telemetry.keys.filter { attachedKeys.contains($0) }.count
        let word = total == 1 ? "SESSION" : "SESSIONS"
        return "\(on)/\(total) \(word)"
    }

    /// Sessions waiting on a human, for the footer's alarm.
    static func blockedCount(_ telemetry: [SessionKey: SessionTelemetry]) -> Int {
        telemetry.values.filter { $0.isRunning && $0.needsAttention }.count
    }
}
