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

        var needsAttention: Bool { state == .blocked }
    }

    struct Group: Equatable {
        var path: String
        var running: Int
        var blocked: Int
        var total: Int
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

        /// The server this group is on — `yorkshire` of `yorkshire:/home` —
        /// or nil for a group on this Mac.
        var server: String? { LaneHeaderPath.splitServer(path)?.server }

        /// `~/code/max-pane` → `~/CODE/MAX-PANE`; the loose-web sentinel → `WEB`.
        var header: String {
            // The path as it really is. Upper-casing it was treating a
            // directory as a label, and paths are case-sensitive data — a group
            // called ~/CODE/MAX-PANE names nothing on this disk.
            if path == SidebarModel.looseWebGroup { return "Web" }
            if path == SidebarModel.bookmarksGroup { return "Bookmarks" }
            return path
        }

        /// A collapsed group hides its rows, so the header has to carry the one
        /// fact you cannot afford to have hidden.
        var countText: String {
            if let countOverride { return countOverride }
            let count = blocked > 0 ? "\(blocked) BLOCKED" : (running > 0 ? "\(running) RUNNING" : "\(total) CLOSED")
            // A remote group whose server is not reachable says so ahead of
            // the count, because the count is then what the server last
            // said, not what is true now.
            if let serverState, serverState != .connected { return "\(serverState.label) · \(count)" }
            return count
        }

        /// The header's state is worth a colour: the server is not connected.
        var serverIsOff: Bool { serverState.map { $0 != .connected } ?? false }
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
            let glyph = t.state == .unknown ? (split.glyph ?? t.state.glyph) : t.state.glyph
            let entry = Entry(
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
            let state: AgentState = kind == .session ? .exited : .unknown
            let entry = Entry(
                id: "lane:\(lane.id)",
                kind: kind,
                title: laneTitle(lane),
                laneId: lane.id,
                // This row is the lane, not a session — so it names the pane the
                // lane's own header names, which is its first.
                paneId: pane.id,
                sessionKey: sessionKeys.first,
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
        var out: [Row] = bookmarkRows(bookmarks, controls)
        for path in grouped.keys.sorted() {
            let kept = grouped[path]!.filter { matches($0, controls) }
            guard !kept.isEmpty else { continue }
            let collapsed = controls.collapsed.contains(path)
            out.append(.group(Group(
                path: path,
                running: kept.filter(\.isRunning).count,
                blocked: kept.filter(\.needsAttention).count,
                total: kept.count,
                collapsed: collapsed,
                countOverride: nil,
                serverState: LaneHeaderPath.splitServer(path).flatMap { servers[$0.server] })))
            guard !collapsed else { continue }
            out.append(contentsOf: sorted(kept, controls).map(Row.entry))
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
            if was.state != e.state || was.chip != e.chip
                || was.badgeIsThroughput != e.badgeIsThroughput { return true }
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
