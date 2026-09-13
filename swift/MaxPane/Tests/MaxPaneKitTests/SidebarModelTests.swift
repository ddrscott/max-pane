import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// The sidebar's claim is that you can see *every* session, grouped by project,
/// and tell at a glance which one wants you. That claim is a pure function —
/// these are the cases that would quietly break it.
@Suite("sidebar session browser")
struct SidebarModelTests {
    private func telemetry(
        _ id: String, title: String, cwd: String, state: AgentState = .idle,
        bps: Double = 0, activity: TimeInterval = 0, running: Bool = true
    ) -> SessionTelemetry {
        SessionTelemetry(
            sessionId: id, title: title, cwd: cwd, command: "claude",
            state: state, bytesPerSecond: bps,
            lastActivity: Date(timeIntervalSince1970: activity),
            isRunning: running)
    }

    private func lane(
        _ id: String, session: String? = nil, url: String? = nil,
        project: String? = nil, created: Int64 = 0, pinned: Bool = false,
        kind: PaneKind = .pty, state: PaneState = .live
    ) -> Lane {
        Lane(
            id: id, ordinal: 1, widthPt: 500, title: url == nil ? nil : nil,
            projectRoot: project, projectSource: .cwd,
            createdAt: created, lastFocusAt: created, keepLive: pinned, dock: nil, span: 1,
            panes: [Pane(
                id: "p-" + id, laneId: id, position: 0, kind: kind,
                relaySessionId: session, url: url, scrollY: nil,
                dataStoreId: nil, snapshotPath: nil, state: state, heightWeight: 1, zoom: 1)])
    }

    private func entries(_ rows: [SidebarModel.Row]) -> [SidebarModel.Entry] {
        rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
    }

    private func groups(_ rows: [SidebarModel.Row]) -> [SidebarModel.Group] {
        rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    @Test("every session gets a row, grouped by directory, whether or not it has a lane")
    func groupsEverySession() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "trifecta ask", cwd: home + "/code/trifecta"),
            "b": telemetry("b", title: "max pane", cwd: home + "/code/max-pane"),
            "c": telemetry("c", title: "shell", cwd: home),
        ]
        let rows = SidebarModel.rows(lanes: [lane("L1", session: "b")], telemetry: t)

        #expect(groups(rows).map(\.path) == ["~", "~/code/max-pane", "~/code/trifecta"])
        #expect(entries(rows).count == 3)
        // Only the session with a lane is on the strip; the other two are still
        // listed, and listed as attachable.
        #expect(entries(rows).filter { $0.laneId != nil }.map(\.sessionId) == ["b"])
        #expect(entries(rows).filter { $0.laneId == nil }.count == 2)
    }

    @Test("group headers count what is running in that project")
    func runningCounts() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "one", cwd: home + "/life"),
            "b": telemetry("b", title: "two", cwd: home + "/life"),
            "c": telemetry("c", title: "dead", cwd: home + "/life", state: .exited, running: false),
        ]
        let rows = SidebarModel.rows(lanes: [], telemetry: t)
        let group = groups(rows).first!
        #expect(group.running == 2)
        #expect(group.total == 3)
        #expect(group.header == "~/life")
    }

    @Test("a collapsed group keeps its header and count but drops its rows")
    func collapse() {
        let home = NSHomeDirectory()
        let t = ["a": telemetry("a", title: "one", cwd: home + "/life")]
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let rows = SidebarModel.rows(lanes: [], telemetry: t, controls: controls)
        #expect(groups(rows).count == 1)
        #expect(groups(rows).first?.running == 1)
        #expect(entries(rows).isEmpty)
    }

    @Test("the badge is throughput when output is moving and \"idle\" when it is not")
    func badge() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "busy", cwd: home, state: .working, bps: 1740),
            "b": telemetry("b", title: "waiting", cwd: home, state: .idle),
        ]
        let rows = SidebarModel.rows(lanes: [], telemetry: t)
        let busy = entries(rows).first { $0.sessionId == "a" }!
        let waiting = entries(rows).first { $0.sessionId == "b" }!
        #expect(busy.badge == "1.7KB/s")
        #expect(busy.badgeIsThroughput)
        #expect(waiting.badge == "idle")
        #expect(!waiting.badgeIsThroughput)
    }

    @Test("a web lane files under its project tag, beside the agent that opened it")
    func webLaneInProject() {
        let home = NSHomeDirectory()
        let t = ["a": telemetry("a", title: "agent", cwd: home + "/code/max-pane")]
        let web = lane("W1", url: "https://google.com/search?q=x",
                       project: home + "/code/max-pane", kind: .web)
        let rows = SidebarModel.rows(lanes: [web], telemetry: t)
        #expect(groups(rows).map(\.path) == ["~/code/max-pane"])
        #expect(entries(rows).contains { $0.kind == .web && $0.title == "google.com" })
    }

    @Test("an untagged web lane sorts into its own group, last")
    func looseWebLane() {
        let home = NSHomeDirectory()
        let t = ["a": telemetry("a", title: "agent", cwd: home + "/code/max-pane")]
        let web = lane("W1", url: "https://example.com", kind: .web)
        let rows = SidebarModel.rows(lanes: [web], telemetry: t)
        #expect(groups(rows).map(\.header) == ["~/code/max-pane", "Web"])
        #expect(groups(rows).last?.path == SidebarModel.looseWebGroup)
    }

    @Test("a pty lane whose session Relay has forgotten is still listed")
    func orphanLane() {
        let orphan = lane("L9", session: "ghost", project: NSHomeDirectory() + "/code/x")
        let rows = SidebarModel.rows(lanes: [orphan], telemetry: [:])
        #expect(entries(rows).count == 1)
        #expect(entries(rows).first?.state == .exited)
        #expect(entries(rows).first?.laneId == "L9")
        // Its pane may still be live, but its process is not: the group header
        // must not count it as running.
        #expect(entries(rows).first?.isRunning == false)
        #expect(groups(rows).first?.running == 0)
    }

    @Test("sort orders rows within a group without reordering the groups")
    func sorting() {
        let home = NSHomeDirectory()
        let t = [
            "old": telemetry("old", title: "zulu", cwd: home, activity: 100),
            "new": telemetry("new", title: "alpha", cwd: home, activity: 900),
        ]
        let created = ["old": 10.0, "new": 90.0]

        var byCreated = SidebarModel.Controls()
        byCreated.sort = .created
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, created: created, controls: byCreated))
            .map(\.sessionId) == ["new", "old"])

        byCreated.descending = false
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, created: created, controls: byCreated))
            .map(\.sessionId) == ["old", "new"])

        var byName = SidebarModel.Controls()
        byName.sort = .name
        byName.descending = false
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, created: created, controls: byName))
            .map(\.title) == ["alpha", "zulu"])

        var byRecent = SidebarModel.Controls()
        byRecent.sort = .recent
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, created: created, controls: byRecent))
            .map(\.sessionId) == ["new", "old"])
    }

    @Test("a blocked agent floats to the top of its group under every sort")
    func blockedFirstAlways() {
        let home = NSHomeDirectory()
        let t = [
            "busy": telemetry("busy", title: "aaa busy", cwd: home, state: .working,
                              bps: 4000, activity: 900),
            "stuck": telemetry("stuck", title: "zzz stuck", cwd: home, state: .blocked,
                               activity: 10),
            "quiet": telemetry("quiet", title: "mmm quiet", cwd: home, state: .idle,
                               activity: 500),
        ]
        let created = ["busy": 300.0, "stuck": 1.0, "quiet": 200.0]

        // Oldest by creation, last alphabetically, least recently active — and
        // still first, because it is the one that has stopped and is waiting.
        for field in SidebarModel.SortField.allCases {
            for descending in [true, false] {
                var controls = SidebarModel.Controls()
                controls.sort = field
                controls.descending = descending
                let order = entries(SidebarModel.rows(
                    lanes: [], telemetry: t, created: created, controls: controls))
                    .map(\.sessionId)
                #expect(order.first == "stuck", "\(field) descending=\(descending) gave \(order)")
            }
        }
    }

    @Test("attention sort ranks the rest blocked → working → done → idle")
    func attentionSort() {
        let home = NSHomeDirectory()
        let t = [
            "busy": telemetry("busy", title: "busy", cwd: home, state: .working, activity: 10),
            "quiet": telemetry("quiet", title: "quiet", cwd: home, state: .idle, activity: 900),
            "finished": telemetry("finished", title: "finished", cwd: home, state: .done, activity: 500),
        ]
        var controls = SidebarModel.Controls()
        controls.sort = .attention
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, controls: controls))
            .map(\.sessionId) == ["busy", "finished", "quiet"])
    }

    @Test("the chip is the agent state and the badge is the throughput, separately")
    func chipAndBadgeAreDifferentColumns() {
        let home = NSHomeDirectory()
        // The pair worth crossing the room for: nothing coming out of it, and it
        // is waiting on a human.
        let t = ["s": telemetry("s", title: "waiting on you", cwd: home, state: .blocked)]
        let row = entries(SidebarModel.rows(lanes: [], telemetry: t)).first!
        #expect(row.badge == "idle")
        #expect(!row.badgeIsThroughput)
        #expect(row.chip == "BLOCKED")
        #expect(row.needsAttention)

        let moving = ["s": telemetry("s", title: "building", cwd: home, state: .working, bps: 1740)]
        let busy = entries(SidebarModel.rows(lanes: [], telemetry: moving)).first!
        #expect(busy.badge == "1.7KB/s")
        #expect(busy.chip == "WORKING")

        // Idle and unknown get no chip at all, so the chips that appear mean
        // something.
        let quiet = ["s": telemetry("s", title: "shell", cwd: home, state: .idle)]
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: quiet)).first?.chip == "")
    }

    @Test("a group header counts what is blocked in it, because collapsing hides rows")
    func groupBlockedCount() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "one", cwd: home + "/life", state: .blocked),
            "b": telemetry("b", title: "two", cwd: home + "/life", state: .working),
        ]
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let group = groups(SidebarModel.rows(lanes: [], telemetry: t, controls: controls)).first!
        #expect(group.blocked == 1)
        #expect(group.countText == "1 BLOCKED")
        #expect(SidebarModel.blockedCount(t) == 1)
    }

    @Test("the agent's own title glyph moves out of the title column")
    func glyphSplit() {
        #expect(SidebarModel.splitGlyph("◑ Pane terminal size").glyph == "◑")
        #expect(SidebarModel.splitGlyph("◑ Pane terminal size").title == "Pane terminal size")
        #expect(SidebarModel.splitGlyph("✳ trifecta ask").title == "trifecta ask")
        #expect(SidebarModel.splitGlyph("spierce@mbp-m3pro:~").glyph == nil)
        // A title that is nothing but a glyph keeps it, or the row loses its name.
        #expect(SidebarModel.splitGlyph("✳").title == "✳")

        // pty-host has an opinion: it wins, and the title's own mark is dropped.
        let known = telemetry("s", title: "◑ Pane terminal size", cwd: NSHomeDirectory(), state: .blocked)
        let row = entries(SidebarModel.rows(lanes: [], telemetry: ["s": known])).first!
        #expect(row.title == "Pane terminal size")
        #expect(row.glyph == AgentState.blocked.glyph)

        // pty-host has none: the title's mark fills the column, but never the
        // chip — an inferred BLOCKED would be worse than none.
        let guess = telemetry("s", title: "◑ Pane terminal size", cwd: NSHomeDirectory(), state: .unknown)
        let inferred = entries(SidebarModel.rows(lanes: [], telemetry: ["s": guess])).first!
        #expect(inferred.glyph == "◑")
        #expect(inferred.chip == "")
    }

    @Test("scopes narrow to what the strip is missing, what is running, and what wants you")
    func scopes() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "busy", cwd: home, state: .working, bps: 900),
            "b": telemetry("b", title: "waiting", cwd: home, state: .idle),
            "c": telemetry("c", title: "dead", cwd: home, state: .exited, running: false),
        ]
        let lanes = [lane("L1", session: "a")]

        var controls = SidebarModel.Controls()
        controls.scope = .running
        #expect(entries(SidebarModel.rows(lanes: lanes, telemetry: t, controls: controls)).count == 2)

        controls.scope = .waiting
        // A web lane is never waiting on you, so it stays out of this one.
        let web = lane("W1", url: "https://example.com", kind: .web)
        #expect(entries(SidebarModel.rows(lanes: lanes + [web], telemetry: t, controls: controls))
            .map(\.sessionId) == ["b"])

        controls.scope = .attached
        #expect(entries(SidebarModel.rows(lanes: lanes, telemetry: t, controls: controls))
            .map(\.sessionId) == ["a"])
    }

    @Test("the query matches title or session id and empties groups it excludes")
    func query() {
        let home = NSHomeDirectory()
        let t = [
            "alpha-id": telemetry("alpha-id", title: "trifecta ask", cwd: home + "/code/a"),
            "beta-id": telemetry("beta-id", title: "max pane", cwd: home + "/code/b"),
        ]
        var controls = SidebarModel.Controls()
        controls.query = "TRIFECTA"
        let rows = SidebarModel.rows(lanes: [], telemetry: t, controls: controls)
        #expect(entries(rows).map(\.sessionId) == ["alpha-id"])
        // The group with nothing left in it disappears rather than showing an
        // empty header.
        #expect(groups(rows).count == 1)

        controls.query = "beta-id"
        #expect(entries(SidebarModel.rows(lanes: [], telemetry: t, controls: controls))
            .map(\.sessionId) == ["beta-id"])
    }

    @Test("the footer says how many sessions exist and how many are on the strip")
    func footer() {
        let home = NSHomeDirectory()
        let t = [
            "a": telemetry("a", title: "one", cwd: home),
            "b": telemetry("b", title: "two", cwd: home),
            "c": telemetry("c", title: "three", cwd: home),
        ]
        #expect(SidebarModel.footerCount(telemetry: t, lanes: [lane("L1", session: "b")]) == "1/3 SESSIONS")
        #expect(SidebarModel.footerCount(telemetry: [:], lanes: []) == "0/0 SESSIONS")
    }

    /// Two pty panes stacked in one lane, the way ⇧⌘D leaves them.
    private func stacked(_ id: String, sessions: [String]) -> Lane {
        Lane(
            id: id, ordinal: 1, widthPt: 500, title: nil,
            projectRoot: nil, projectSource: .cwd,
            createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1,
            panes: sessions.enumerated().map { position, session in
                Pane(
                    id: "\(id)-p\(position)", laneId: id, position: UInt32(position), kind: .pty,
                    relaySessionId: session, url: nil, scrollY: nil,
                    dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1)
            })
    }

    @Test("a row names the pane its own session is in, not the lane's first")
    func rowNamesItsOwnPane() {
        // The bug this guards: clicking the second session of a split lane
        // handed the keyboard to the first, because a row only knew its lane.
        let home = NSHomeDirectory()
        let t = [
            "top": telemetry("top", title: "one", cwd: home + "/code/split"),
            "bottom": telemetry("bottom", title: "two", cwd: home + "/code/split"),
        ]
        let rows = SidebarModel.rows(lanes: [stacked("L1", sessions: ["top", "bottom"])], telemetry: t)
        let byId = Dictionary(uniqueKeysWithValues: entries(rows).map { ($0.sessionId!, $0) })
        #expect(byId["top"]?.paneId == "L1-p0")
        #expect(byId["bottom"]?.paneId == "L1-p1")
        // Both still name the one lane they share.
        #expect(byId["top"]?.laneId == "L1")
        #expect(byId["bottom"]?.laneId == "L1")
    }

    @Test("a row for a session that is not on the strip names no pane at all")
    func detachedRowNamesNoPane() {
        // It is still a click-to-attach row, and a pane id invented for it would
        // be a focus target that does not exist.
        let home = NSHomeDirectory()
        let t = ["a": telemetry("a", title: "one", cwd: home)]
        let entry = entries(SidebarModel.rows(lanes: [], telemetry: t)).first
        #expect(entry?.laneId == nil)
        #expect(entry?.paneId == nil)
    }

    @Test("a lane row with no session behind it names the lane's first pane")
    func webRowNamesItsPane() {
        let rows = SidebarModel.rows(
            lanes: [lane("W1", url: "https://example.com", kind: .web)], telemetry: [:])
        #expect(entries(rows).first?.paneId == "p-W1")
    }

    @Test("the age column reads the way the bar's does")
    func ages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-6), now: now) == "6s ago")
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-46_800), now: now) == "13h ago")
    }
}

// MARK: - the bar

/// The bookmarks section. What it has to get right is not the pixels: it is
/// that a folded folder hides exactly its own subtree, that a folded folder
/// still says how much it is hiding, and that a search opens the folders it
/// matched inside — because a hit behind a closed triangle is a search that
/// found nothing as far as the screen is concerned.
@Suite("the sidebar's bookmarks")
@MainActor
struct SidebarBookmarkTests {
    /// The tree as `Core::bookmarks` hands it over: flat, in draw order, with
    /// the depth already worked out.
    private func tree() -> [Bookmark] {
        func node(_ id: String, _ title: String, _ url: String?, _ depth: UInt32) -> Bookmark {
            Bookmark(
                id: id, parentId: nil, isFolder: url == nil, url: url, title: title,
                position: 0, addedAt: 0, depth: depth)
        }
        return [
            node("work", "Work", nil, 0),
            node("board", "The board", "https://board.example.com/x", 1),
            node("rust", "Rust", nil, 1),
            node("std", "std", "https://doc.rust-lang.org/std/", 2),
            // Normalized, the way the ledger stores it: `normalize_url`
            // collapses the bare trailing slash.
            node("loose", "Loose", "https://loose.example.com", 0),
        ]
    }

    private func titles(_ rows: [SidebarModel.Row]) -> [String] {
        rows.compactMap { if case .bookmark(let b) = $0 { return b.title } else { return nil } }
    }

    @Test("no bookmarks means no section, rather than a row saying you have none")
    func emptyIsInvisible() {
        #expect(SidebarModel.bookmarkRows([], SidebarModel.Controls()).isEmpty)
    }

    @Test("the header counts the pages, not the folders")
    func headerCountsPages() {
        let rows = SidebarModel.bookmarkRows(tree(), SidebarModel.Controls())
        guard case .group(let header) = rows[0] else { Issue.record("no header"); return }
        #expect(header.header == "Bookmarks")
        #expect(header.countText == "3 KEPT")
    }

    @Test("folding a folder hides its subtree and nothing after it")
    func foldingHidesTheSubtree() {
        var controls = SidebarModel.Controls()
        #expect(titles(SidebarModel.bookmarkRows(tree(), controls))
            == ["Work", "The board", "Rust", "std", "Loose"])

        controls.collapsed = ["work"]
        #expect(titles(SidebarModel.bookmarkRows(tree(), controls)) == ["Work", "Loose"])

        // The nested case: folding the inner folder leaves the outer one open.
        controls.collapsed = ["rust"]
        #expect(titles(SidebarModel.bookmarkRows(tree(), controls))
            == ["Work", "The board", "Rust", "Loose"])
    }

    @Test("a folded folder says how much it is hiding, counting all the way down")
    func foldedFolderCarriesItsCount() {
        let rows = SidebarModel.bookmarkRows(tree(), SidebarModel.Controls())
        let details = Dictionary(uniqueKeysWithValues: rows.compactMap {
            if case .bookmark(let b) = $0 { return (b.title, b.detail) } else { return nil }
        })
        // `Work` holds a page, a folder, and the page inside that folder —
        // "1 ITEM" would be the immediate-children answer and it is the wrong
        // one for a row whose whole job is to say what is behind it.
        #expect(details["Work"] == "3 ITEMS")
        #expect(details["Rust"] == "1 ITEM")
        #expect(details["Loose"] == "loose.example.com")
    }

    @Test("folding the section itself leaves the header and nothing else")
    func sectionFolds() {
        var controls = SidebarModel.Controls()
        controls.collapsed = [SidebarModel.bookmarksGroup]
        let rows = SidebarModel.bookmarkRows(tree(), controls)
        #expect(rows.count == 1)
        guard case .group(let header) = rows[0] else { Issue.record("no header"); return }
        #expect(header.countText == "3 KEPT", "a folded section still has to say what it holds")
    }

    @Test("a search keeps the folders above a hit and opens them")
    func searchOpensWhatItMatched() {
        var controls = SidebarModel.Controls()
        controls.query = "rust-lang"
        // `std` is two folders deep and both of them were folded.
        controls.collapsed = ["work", "rust"]
        #expect(titles(SidebarModel.bookmarkRows(tree(), controls)) == ["Work", "Rust", "std"])
    }

    @Test("a search that matches nothing shows no section at all")
    func searchWithNoHitsHidesTheSection() {
        var controls = SidebarModel.Controls()
        controls.query = "zzqq"
        #expect(SidebarModel.bookmarkRows(tree(), controls).isEmpty)
    }

    @Test("the bar is above the sessions")
    func barComesFirst() {
        let rows = SidebarModel.rows(lanes: [], telemetry: [:], bookmarks: tree())
        guard case .group(let first) = rows[0] else { Issue.record("no header"); return }
        #expect(first.path == SidebarModel.bookmarksGroup)
    }

    /// The sort control orders sessions within a project. A bar's order *is*
    /// the thing — eight folders that have been in eight places for years — so
    /// nothing here may touch it.
    @Test("the session sort controls do not reorder the bar")
    func sortDoesNotReachTheBar() {
        var controls = SidebarModel.Controls()
        controls.sort = .name
        controls.descending = false
        #expect(titles(SidebarModel.bookmarkRows(tree(), controls))
            == ["Work", "The board", "Rust", "std", "Loose"])
    }
}

/// The bar, drawn. A bookmark row is 24 pt in a 290 pt column carrying a
/// triangle, a mark, a name and a count — whether that is *legible* is not
/// something an assertion can answer, so this writes the picture and a human
/// looks at it. Gated on `MAXPANE_SHOTS` like every other sheet.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("sidebar bookmark rendering")
@MainActor
struct SidebarBookmarkRenderTests {
    @Test("renders the bar at the widths the sidebar is dragged to")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        func node(_ id: String, _ title: String, _ url: String?, _ depth: UInt32) -> Bookmark {
            Bookmark(
                id: id, parentId: nil, isFolder: url == nil, url: url, title: title,
                position: 0, addedAt: 0, depth: depth)
        }
        // Eight folders, because that is what the owner's bar has, plus the two
        // rows that have the least to work with: a deep nesting, and a title
        // long enough to collide with the count on its right.
        var tree: [Bookmark] = []
        for (i, name) in ["Daily", "Work", "Rust", "Infra", "Reading", "Shopping", "Music", "Admin"]
            .enumerated()
        {
            tree.append(node("f\(i)", name, nil, 0))
            tree.append(node("f\(i)-a", "\(name) — the one I always reopen",
                             "https://\(name.lowercased()).example.com/a/b", 1))
        }
        tree.insert(node("deep", "Standard Library", nil, 1), at: 5)
        tree.insert(
            node("deep-a", "std", "https://doc.rust-lang.org/std/collections/", 2), at: 6)
        tree.append(node("loose", "Loose", "https://loose.example.com", 0))

        var controls = SidebarModel.Controls()
        controls.collapsed = ["f3"]
        let rows = SidebarModel.bookmarkRows(tree, controls)

        for width in [260.0, 290.0, 420.0] as [CGFloat] {
            let heights = rows.map { row -> CGFloat in
                if case .group = row { return SidebarGroupView.height }
                return SidebarBookmarkView.height
            }
            let sheet = NSView(frame: NSRect(
                x: 0, y: 0, width: width, height: heights.reduce(0, +) + 8))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.stripBackground.cgColor

            var y = sheet.bounds.height - 4
            for (row, height) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .group(let g): view = SidebarGroupView(group: g)
                case .bookmark(let b): view = SidebarBookmarkView(row: b)
                case .entry: continue
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("bookmarks-\(Int(width)).png"))
        }
    }
}
