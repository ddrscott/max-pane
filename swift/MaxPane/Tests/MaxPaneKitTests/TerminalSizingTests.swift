import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// ADR-0007: the lane is sized to the session, never the other way round.
///
/// The table below is M2's, measured at 12 pt Menlo (a 7 pt cell). It is here so
/// that a change to the sizing rule has to argue with the measurement rather
/// than just recompiling.
@Suite("lane sized to session")
@MainActor
struct LaneSizingTests {
    private let cell12pt = 7.0

    @Test("real session widths all fit inside the PRD's lane range", arguments: [
        (cols: 52, fits: true),   // the narrowest real session on this machine
        (cols: 73, fits: true),   // a Claude Code session
        (cols: 100, fits: true),
        (cols: 126, fits: true),  // the very top of the range, chrome included
        (cols: 128, fits: false), // M2's 896pt is the grid alone; the gutter tips it over
        (cols: 160, fits: false), // needs the font to shrink
    ])
    func realWidthsFit(_ c: (cols: Int, fits: Bool)) {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: c.cols, cellWidth: 7.0)
        #expect((needed <= config.widthRange.upperBound) == c.fits,
                "\(c.cols) cols wanted \(needed)pt")
    }

    @Test("the measured widths match M2's table")
    func matchesSpikeTable() {
        // 73 × 7 + 16 gutter = 527. M2 quotes 511 for the grid alone; the
        // difference is the lane's own chrome, and both sit well inside 900.
        #expect(TerminalPaneController.laneWidth(forCols: 73, cellWidth: 7.0) == 527)
        // 912 — which is *past* LANE_MAX. M2's 896 counts the grid only, so the
        // true ceiling at 12 pt is 126 columns, not 128.
        #expect(TerminalPaneController.laneWidth(forCols: 128, cellWidth: 7.0) == 912)
        #expect(TerminalPaneController.laneWidth(forCols: 126, cellWidth: 7.0) == 898)
        #expect(TerminalPaneController.laneWidth(forCols: 52, cellWidth: 7.0) == 380)
    }

    @Test("a narrow session clamps up to LANE_MIN rather than making a sliver")
    func narrowSessionClampsToMinimum() {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 52, cellWidth: 7.0)
        #expect(needed < config.widthRange.lowerBound)
        #expect(config.clampWidth(needed) == config.laneMinPt)
    }

    @Test("a very wide session clamps down to LANE_MAX, which is what triggers font scaling")
    func wideSessionClampsToMaximum() {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 200, cellWidth: 7.0)
        #expect(needed > config.widthRange.upperBound)
        #expect(config.clampWidth(needed) == config.laneMaxPt)
    }

    @Test("the font floor still shows a usable number of columns")
    func fontFloorIsUsable() {
        // M2: at 9 pt a cell is 5 pt, so LANE_MIN holds 84 columns and LANE_MAX
        // holds 180. Below this the text stops being readable and we clip.
        let config = Config()
        let atMin = (Double(config.laneMinPt) - TerminalPaneController.gutter) / 5.0
        let atMax = (Double(config.laneMaxPt) - TerminalPaneController.gutter) / 5.0
        #expect(Int(atMin) >= 80, "only \(Int(atMin)) columns at the floor")
        #expect(Int(atMax) >= 170)
        #expect(TerminalPaneController.minimumFontSize == 9)
    }

    @Test("the Swift and Rust defaults agree")
    func defaultsAgree() {
        // `laned-core` stamps LANE_DEFAULT_PT onto every new lane; Config is
        // what the user can override. They drift silently if nobody checks,
        // and the symptom is a web lane that opens at a different width than
        // the one the config file says.
        let core = try! Core.openInMemory()
        let state = try! core.createLane(
            placement: .end, kind: .web, relaySessionId: nil,
            url: "https://example.com", inheritTagFromLane: nil)
        #expect(state.lanes[0].widthPt == Config().laneDefaultPt)
    }

    @Test("the default lane width holds 80 columns at the default font size")
    func defaultHolds80Columns() {
        // The common case — an agent TUI assuming 80 columns — should not open
        // already clipped. At 13 pt a cell is 8 pt.
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 80, cellWidth: 8.0)
        #expect(needed <= config.laneDefaultPt, "80 cols wants \(needed)pt, default is \(config.laneDefaultPt)")
    }
}

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

        t.bytesPerSecond = 1740
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
