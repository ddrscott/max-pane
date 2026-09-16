import Testing
import Foundation
@testable import MaxPaneKit

/// The ⌘O picker's ranking and grouping.
///
/// These are the parts a screenshot cannot vouch for: which of ten sessions
/// comes first when you type two letters, and whether a group still says
/// "1 running" once a filter has hidden the running one.
@Suite("session picker")
struct PaletteFilteringTests {
    private func session(
        _ id: String, title: String, cwd: String, command: String = "claude",
        state: AgentState = .idle, bps: Double = 0, ageSeconds: TimeInterval = 30,
        running: Bool = true, attached: Bool = false
    ) -> SessionTelemetry {
        SessionTelemetry(
            sessionId: id, title: title, cwd: cwd, command: command, state: state,
            bytesPerSecond: bps, lastActivity: Date().addingTimeInterval(-ageSeconds),
            isRunning: running, isAttached: attached)
    }

    private func groups(_ sessions: [SessionTelemetry]) -> [(path: String, sessions: [SessionTelemetry])] {
        let byPath = Dictionary(grouping: sessions, by: \.groupPath)
        return byPath.keys.sorted().map { (path: $0, sessions: byPath[$0]!) }
    }

    // MARK: - fuzzy

    @Test("matches a scattered subsequence and reports where it landed")
    func matchesSubsequence() {
        let m = Fuzzy.match("mxp", in: "max-pane")
        #expect(m?.indices == [0, 2, 4])
    }

    @Test("a contiguous run beats the same letters scattered")
    func prefersRuns() {
        let tight = Fuzzy.match("pane", in: "pane terminal")?.score ?? 0
        let loose = Fuzzy.match("pane", in: "p a n e")?.score ?? 0
        #expect(tight > loose)
    }

    @Test("a match on word starts beats a match mid-word")
    func prefersWordStarts() {
        let starts = Fuzzy.match("tm", in: "trifecta monitor")?.score ?? 0
        let middle = Fuzzy.match("tm", in: "attempt m")?.score ?? 0
        #expect(starts > middle)
    }

    @Test("letters out of order do not match")
    func rejectsOutOfOrder() {
        #expect(Fuzzy.match("enap", in: "max-pane") == nil)
    }

    @Test("an empty query matches everything with no highlights")
    func emptyQueryMatchesAll() {
        #expect(Fuzzy.match("", in: "anything") == Fuzzy.Match(score: 0, indices: []))
    }

    @Test("matching ignores case")
    func ignoresCase() {
        #expect(Fuzzy.match("GH", in: "Github project") != nil)
    }

    // MARK: - grouping

    @Test("sessions are grouped by directory, with a running count per group")
    func groupsWithCounts() {
        let entries = PaletteFilter.entries(groups: groups([
            session("a", title: "trifecta ask", cwd: "/tmp/work/one"),
            session("b", title: "trifecta monitor", cwd: "/tmp/work/one", running: false),
            session("c", title: "pane terminal", cwd: "/tmp/work/two"),
        ]), query: "")

        let headers = entries.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        #expect(headers.count == 2)
        #expect(headers[0] == PaletteGroup(path: "/tmp/work/one", total: 2, running: 1, blocked: 0))
        #expect(headers[1] == PaletteGroup(path: "/tmp/work/two", total: 1, running: 1, blocked: 0))
        // Header, two sessions, header, one session.
        #expect(entries.map(\.isSelectable) == [false, true, true, false, true])
    }

    @Test("a group's counts describe the group, not what the filter left of it")
    func countsSurviveFiltering() {
        let entries = PaletteFilter.entries(groups: groups([
            session("a", title: "trifecta ask", cwd: "/tmp/work"),
            session("b", title: "htop", cwd: "/tmp/work", command: "htop"),
        ]), query: "htop")

        guard case .group(let header)? = entries.first else {
            Issue.record("expected a group header first")
            return
        }
        #expect(header.total == 2 && header.running == 2)
        #expect(entries.filter(\.isSelectable).count == 1)
    }

    @Test("a group with nothing left after filtering disappears")
    func emptyGroupsDrop() {
        let entries = PaletteFilter.entries(groups: groups([
            session("a", title: "trifecta ask", cwd: "/tmp/one"),
            session("b", title: "pane terminal", cwd: "/tmp/two"),
        ]), query: "trifecta")
        #expect(entries.count == 2)
        #expect(entries.filter(\.isSelectable).count == 1)
    }

    // MARK: - filtering across fields

    @Test("the query matches on title, command or path")
    func matchesAllThreeFields() {
        let all = groups([
            session("a", title: "latest commit changes", cwd: "/tmp/one", command: "claude"),
            session("b", title: "watching logs", cwd: "/tmp/two", command: "htop"),
            session("c", title: "quiet", cwd: "/Users/x/code/relay-tty", command: "zsh"),
        ])
        func ids(_ q: String) -> [String] {
            PaletteFilter.entries(groups: all, query: q).compactMap {
                if case .session(let s) = $0 { return s.telemetry.sessionId } else { return nil }
            }
        }
        #expect(ids("commit") == ["a"])
        #expect(ids("htop") == ["b"])
        #expect(ids("relay") == ["c"])
    }

    @Test("a title hit outranks a path hit, because the path is what a group already tells you")
    func titleOutranksPath() {
        let entries = PaletteFilter.entries(groups: groups([
            session("path-only", title: "quiet worker", cwd: "/tmp/ask", command: "zsh"),
            session("titled", title: "trifecta ask", cwd: "/tmp/ask", command: "zsh"),
        ]), query: "ask")
        let order = entries.compactMap {
            if case .session(let s) = $0 { return s.telemetry.sessionId } else { return nil }
        }
        #expect(order.first == "titled")
    }

    @Test("every whitespace-separated token has to land somewhere")
    func allTokensMustMatch() {
        let all = groups([
            session("a", title: "latest commit", cwd: "/Users/x/code/max-pane", command: "claude"),
            session("b", title: "latest commit", cwd: "/Users/x/code/relay-tty", command: "claude"),
        ])
        let ids = PaletteFilter.entries(groups: all, query: "commit maxpane").compactMap {
            if case .session(let s) = $0 { return s.telemetry.sessionId } else { return nil }
        }
        #expect(ids == ["a"])
    }

    @Test("the matched characters come back so the row can light them up")
    func reportsTitleHighlights() {
        let entries = PaletteFilter.entries(
            groups: groups([session("a", title: "pane terminal", cwd: "/tmp")]),
            query: "pane")
        guard case .session(let row)? = entries.last else {
            Issue.record("expected a session row")
            return
        }
        #expect(row.titleMatches == [0, 1, 2, 3])
    }

    @Test("within a group, equal scores fall back to most recently active")
    func tiesBreakOnRecency() {
        let entries = PaletteFilter.entries(groups: groups([
            session("stale", title: "claude", cwd: "/tmp", ageSeconds: 9_000),
            session("fresh", title: "claude", cwd: "/tmp", ageSeconds: 5),
        ]), query: "claude")
        let order = entries.compactMap {
            if case .session(let s) = $0 { return s.telemetry.sessionId } else { return nil }
        }
        #expect(order == ["fresh", "stale"])
    }

    @Test("attached sessions stay in the list — the picker marks them, it does not hide them")
    func keepsAttachedSessions() {
        let entries = PaletteFilter.entries(
            groups: groups([session("a", title: "on the strip", cwd: "/tmp", attached: true)]),
            query: "")
        guard case .session(let row)? = entries.last else {
            Issue.record("expected a session row")
            return
        }
        #expect(row.telemetry.isAttached)
    }

    // MARK: - the blocked session, which is the whole point

    @Test("a group holding a blocked session comes before groups that do not")
    func blockedGroupsFloat() {
        let entries = PaletteFilter.entries(groups: [
            (path: "/tmp/aaa", sessions: [session("quiet", title: "quiet", cwd: "/tmp/aaa")]),
            (path: "/tmp/zzz", sessions: [
                session("waiting", title: "waiting", cwd: "/tmp/zzz", state: .blocked),
            ]),
        ], query: "")
        guard case .group(let first)? = entries.first else {
            Issue.record("expected a group header first")
            return
        }
        #expect(first.path == "/tmp/zzz" && first.blocked == 1)
    }

    @Test("a blocked match outranks a better-scoring idle one")
    func blockedOutranksScore() {
        let entries = PaletteFilter.entries(groups: groups([
            session("idle-exact", title: "deploy", cwd: "/tmp"),
            session("blocked-loose", title: "d… e… p… l… o… y", cwd: "/tmp", state: .blocked),
        ]), query: "deploy")
        let order = entries.compactMap {
            if case .session(let s) = $0 { return s.telemetry.sessionId } else { return nil }
        }
        #expect(order == ["blocked-loose", "idle-exact"])
    }

    @Test("the header counts what is blocked, not only what is running")
    func headerCountsBlocked() {
        let entries = PaletteFilter.entries(groups: groups([
            session("a", title: "one", cwd: "/tmp", state: .blocked),
            session("b", title: "two", cwd: "/tmp", state: .working),
            session("c", title: "three", cwd: "/tmp", running: false),
        ]), query: "")
        guard case .group(let header)? = entries.first else {
            Issue.record("expected a group header first")
            return
        }
        #expect(header == PaletteGroup(path: "/tmp", total: 3, running: 2, blocked: 1))
    }

    @Test("only the three states worth interrupting someone for get a chip")
    func chipsOnlyWhereTheyMean() {
        #expect(AgentState.blocked.hasChip && !AgentState.working.hasChip && AgentState.done.hasChip)
        #expect(!AgentState.idle.hasChip && !AgentState.unknown.hasChip)
    }

    // MARK: - launching what is not running

    private let launchable = [(command: "claude", label: "claude"), (command: "/bin/zsh", label: "zsh")]

    @Test("a query that matches nothing offers to launch instead of showing an empty box")
    func offersLaunchOnNoMatch() {
        let entries = PaletteFilter.entries(
            groups: groups([session("a", title: "trifecta ask", cwd: "/tmp/one")]),
            query: "nothinghere", launchable: launchable, home: "/Users/x")
        #expect(entries.count == 3)
        guard case .section(_, let note)? = entries.first else {
            Issue.record("expected a launch section header")
            return
        }
        #expect(note.contains("nothinghere"))
        #expect(entries.filter(\.isSelectable).count == 2)
    }

    @Test("a launch starts in the project the query looks most like, not in $HOME")
    func launchesInTheMatchingProject() {
        let entries = PaletteFilter.entries(
            groups: groups([session("a", title: "ask", cwd: "/Users/x/code/max-pane")]),
            query: "maxpane zzz", launchable: launchable, home: "/Users/x")
        let cwds = entries.compactMap {
            if case .launch(let l) = $0 { return l.cwd } else { return nil }
        }
        #expect(cwds == ["/Users/x/code/max-pane", "/Users/x/code/max-pane"])
    }

    @Test("with nothing to match against, a launch falls back to $HOME")
    func launchFallsBackHome() {
        let entries = PaletteFilter.entries(
            groups: [], query: "", launchable: launchable, home: "/Users/x")
        let cwds = entries.compactMap {
            if case .launch(let l) = $0 { return l.cwd } else { return nil }
        }
        #expect(cwds == ["/Users/x", "/Users/x"])
    }

    @Test("launch rows never displace real matches")
    func launchStaysOutOfTheWay() {
        let entries = PaletteFilter.entries(
            groups: groups([session("a", title: "trifecta ask", cwd: "/tmp")]),
            query: "ask", launchable: launchable, home: "/Users/x")
        #expect(!entries.contains { if case .launch = $0 { return true } else { return false } })
    }

    @Test("only commands actually on PATH are offered, plus the user's shell")
    func discoversCommandsOnPath() {
        let found = LaunchCommands.discover(
            env: ["PATH": "/opt/bin:/usr/bin", "SHELL": "/bin/fish"],
            exists: { $0 == "/opt/bin/claude" })
        #expect(found.map(\.command) == ["claude", "/bin/fish"])
        #expect(found.map(\.label) == ["claude", "fish"])
    }

    // MARK: - what the rows print

    @Test("the throughput readout and the chip are independent columns")
    func badgeAndChipAreSeparate() {
        let moving = session("a", title: "t", cwd: "/tmp", state: .working, bps: 1741)
        // The combination worth crossing the room for: nothing flowing, and the
        // agent is waiting on an answer.
        let waiting = session("b", title: "t", cwd: "/tmp", state: .blocked, bps: 0)
        #expect(moving.badgeText == "1.7KB/s" && moving.badgeIsThroughput)
        #expect(waiting.badgeText == "idle" && !waiting.badgeIsThroughput)
        #expect(waiting.state.chipText == "BLOCKED" && waiting.needsAttention)
    }

    @Test("scrollback excerpts are flattened to one line")
    func excerptsAreOneLine() {
        let text = PaletteSearchRow.oneLine("  first\n\tsecond  ")
        #expect(text == "first second")
        #expect(!PaletteSearchRow.oneLine(String(repeating: "x", count: 400)).contains("\n"))
        #expect(PaletteSearchRow.oneLine(String(repeating: "x", count: 400)).count == 161)
    }
}
