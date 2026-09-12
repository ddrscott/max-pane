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
            createdAt: created, lastFocusAt: created, pinned: pinned, span: 1,
            panes: [Pane(
                id: "p-" + id, laneId: id, position: 0, kind: kind,
                relaySessionId: session, url: url, scrollY: nil,
                dataStoreId: nil, snapshotPath: nil, state: state)])
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

    @Test("the age column reads the way the bar's does")
    func ages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-6), now: now) == "6s ago")
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(SessionTelemetry.age(since: now.addingTimeInterval(-46_800), now: now) == "13h ago")
    }
}
