import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// ADR-0007: the lane is sized to the session, never the other way round.
///
/// The table below is M2's, measured at 12 pt Menlo (a 7 pt cell). It is here so
/// that a change to the sizing rule has to argue with the measurement rather
/// than just recompiling.
/// Lane-to-column arithmetic is no longer done here.
///
/// The suite that lived at this spot converted lane points into columns and
/// rows by hand, and its bugs were all of one kind: the font metric it measured
/// with never quite matched the one the renderer drew with, which cost every
/// terminal a row or two of dead space. Ghostty derives the grid from the view
/// and reports what it became, so there is no conversion left to test.
/// See ADR-0009.

/// The search index holds text, not formatting.
@Suite("scrollback text extraction")
@MainActor
struct ScrollbackTextTests {
    @Test("strips CSI colour and cursor sequences")
    func stripsCSI() {
        let input = "\u{1b}[32mok\u{1b}[0m done\u{1b}[2K"
        #expect(TerminalPaneController.stripEscapes(input) == "ok done")
    }

    @Test("strips OSC sequences with either terminator")
    func stripsOSC() {
        #expect(TerminalPaneController.stripEscapes("a\u{1b}]0;a title\u{07}b") == "ab")
        #expect(TerminalPaneController.stripEscapes("a\u{1b}]7;file://h/p\u{1b}\\b") == "ab")
    }

    @Test("keeps the text an agent actually prints, emoji included")
    func keepsRealOutput() {
        // M2 caught `translateToString` silently dropping astral-plane scalars,
        // which is most of what agent output decorates itself with.
        let input = "\u{1b}[1m✳ Latest commit\u{1b}[0m 😀 日本 🇺🇸"
        #expect(TerminalPaneController.stripEscapes(input) == "✳ Latest commit 😀 日本 🇺🇸")
    }

    @Test("drops carriage returns, which would otherwise split one line into two")
    func dropsCarriageReturns() {
        #expect(TerminalPaneController.stripEscapes("progress\rdone") == "progressdone")
    }

    @Test("survives a sequence truncated at the end of a frame")
    func survivesTruncation() {
        // A frame boundary can land anywhere; nothing here may hang or trap.
        #expect(TerminalPaneController.stripEscapes("text\u{1b}[") == "text")
        #expect(TerminalPaneController.stripEscapes("text\u{1b}") == "text")
        #expect(TerminalPaneController.stripEscapes("text\u{1b}]0;unterminated") == "text")
    }

    @Test("leaves plain text exactly alone")
    func leavesPlainTextAlone() {
        let plain = "error: could not compile laned-core (lib) due to 2 previous errors"
        #expect(TerminalPaneController.stripEscapes(plain) == plain)
    }
}

/// The agent-state model — the single most valuable thing RelayTTY does. With
/// ten agents running it is what tells you which one has stopped and is waiting
/// on you; finding that by eye means reading ten terminals.
///
/// The wire values come from `crates/pty-host/src/agent_state.rs`, serialised
/// lowercase. Getting a name wrong here does not fail loudly — the state just
/// reads as `unknown` and the signal silently disappears, which is exactly what
/// had happened before these tests existed.
@Suite("agent state")
struct AgentStateTests {
    @Test("every state pty-host can emit round-trips", arguments: [
        ("blocked", AgentState.blocked),
        ("working", AgentState.working),
        ("done", AgentState.done),
        ("idle", AgentState.idle),
        ("unknown", AgentState.unknown),
    ])
    func parsesEveryWireValue(_ c: (wire: String, expected: AgentState)) {
        #expect(AgentState(relayValue: c.wire, status: "running") == c.expected)
    }

    @Test("an exited session is exited whatever the classifier last said")
    func exitedWins() {
        #expect(AgentState(relayValue: "working", status: "exited") == .exited)
        #expect(AgentState(relayValue: nil, status: "exited") == .exited)
    }

    @Test("a state we do not recognise is unknown, not a guess")
    func unknownIsNotAGuess() {
        #expect(AgentState(relayValue: "sleeping", status: "running") == .unknown)
        #expect(AgentState(relayValue: nil, status: "running") == .unknown)
    }

    @Test("blocked sorts above everything")
    func blockedSortsFirst() {
        let ranks = [AgentState.blocked, .working, .done, .idle, .unknown].map(\.rank)
        #expect(ranks == ranks.sorted(), "rank order changed")
        #expect(AgentState.blocked.rank == 0)
    }

    @Test("only the three states worth interrupting someone for get a chip")
    func onlyUrgentStatesGetChips() {
        #expect(AgentState.blocked.chipText == "BLOCKED")
        #expect(AgentState.working.chipText == "WORKING")
        #expect(AgentState.done.chipText == "DONE")
        // A chip on every row is a chip that means nothing.
        #expect(!AgentState.idle.hasChip)
        #expect(!AgentState.unknown.hasChip)
    }

    @Test("throughput and agent state answer different questions")
    func throughputIsNotState() {
        // The combination worth walking across the room for: nothing coming out
        // of it, and it is waiting on you.
        var t = SessionTelemetry(sessionId: "x", state: .blocked, bytesPerSecond: 0)
        #expect(t.badgeText == "idle")
        #expect(t.needsAttention)

        // Green means working, so a blocked session's trickle is not a rate.
        t.bytesPerSecond = 1740
        #expect(t.badgeText == "idle")
        #expect(!t.badgeIsThroughput)
        #expect(t.needsAttention)

        t.relayState = .working
        #expect(t.badgeText == "1.7KB/s")
        #expect(t.badgeIsThroughput)
    }

    @Test("throughput is printed the way the bar prints it")
    func throughputFormatting() {
        func text(_ bps: Double) -> String {
            SessionTelemetry(sessionId: "x", bytesPerSecond: bps).throughputText
        }
        #expect(text(0) == "")
        #expect(text(0.4) == "")
        #expect(text(842) == "842B/s")
        #expect(text(1740) == "1.7KB/s")
        #expect(text(2_202_010) == "2.1MB/s")
    }

    @Test("ages read the way a person says them")
    func ageFormatting() {
        let now = Date()
        func text(_ secondsAgo: TimeInterval) -> String {
            SessionTelemetry.age(since: now.addingTimeInterval(-secondsAgo), now: now)
        }
        #expect(text(1) == "now")
        #expect(text(6) == "6s ago")
        #expect(text(120) == "2m ago")
        #expect(text(13 * 3600) == "13h ago")
        #expect(text(3 * 86_400) == "3d ago")
    }

    @Test("home is abbreviated to ~ the way the bar does")
    func pathAbbreviation() {
        let home = NSHomeDirectory()
        #expect(SessionTelemetry.abbreviate(home) == "~")
        #expect(SessionTelemetry.abbreviate(home + "/code/max-pane") == "~/code/max-pane")
        #expect(SessionTelemetry.abbreviate("/opt/thing") == "/opt/thing")
        #expect(SessionTelemetry.abbreviate("") == "~")
    }
}

/// Choosing the `relay-pty-host` binary.
///
/// This has one failure mode and it is silent: pick a build without the
/// agent-state classifier and every session starts fine, output flows fine, and
/// `agentState` is simply never written — so the sidebar, picker and status bar
/// all go quiet about the one thing they exist for, with no error anywhere.
@Suite("pty-host selection")
struct PtyHostSelectionTests {
    @Test("a binary with the classifier is recognised, one without is not")
    func detectsClassifier() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptyhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let withIt = dir.appendingPathComponent("new")
        let without = dir.appendingPathComponent("old")
        try Data("...binary...Do you want to proceed...more".utf8).write(to: withIt)
        try Data("...binary...nothing of interest...".utf8).write(to: without)

        #expect(RelaySessionSpawner.hasAgentClassifier(at: withIt.path))
        #expect(!RelaySessionSpawner.hasAgentClassifier(at: without.path))
        // A path that is not there must not throw or crash — it is the common
        // case on a machine with no RelayTTY checkout.
        #expect(!RelaySessionSpawner.hasAgentClassifier(at: dir.appendingPathComponent("absent").path))
    }

    @Test("an explicit override always wins")
    func overrideWins() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptyhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mine = dir.appendingPathComponent("mine")
        try Data("anything".utf8).write(to: mine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.path)

        #expect(RelaySessionSpawner.locatePtyHost(override: mine.path) == mine.path)
        // A non-executable override is ignored rather than used and failing later.
        #expect(RelaySessionSpawner.locatePtyHost(override: "/nope/nothing") != "/nope/nothing")
    }
}
