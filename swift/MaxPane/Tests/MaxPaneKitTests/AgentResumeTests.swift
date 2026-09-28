import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// Resume agent sessions after a reboot (ADR-0046): reading which `claude` is
/// in which pane, what the ledger is told, which panes can resume and with
/// what command line, and the pane that offers `$ RESUME` and is rebound in
/// place. Nothing here starts a `claude` or a relay session; the one real
/// thing read is this test process's own entry in the process table.
@Suite("resume agents")
@MainActor
struct AgentResumeTests {
    // MARK: Claude's session file

    @Test("a session file parses to its pid, conversation, directory and name; a non-interactive one is not a person's")
    func sessionFile() throws {
        let real = #"""
            {"pid":3515,"sessionId":"4c1dbec0-00de-45d7-ac47-4fe37036469a","cwd":"/Users/s/code/metronome-pocket",
             "startedAt":1790605814083,"version":"2.1.283","kind":"interactive","entrypoint":"cli",
             "name":"metronome-pocket-ea","nameSource":"derived","status":"idle"}
            """#
        let file = try #require(ClaudeSessionFile.parse(Data(real.utf8)))
        #expect(file == ClaudeSessionFile(
            pid: 3515, sessionId: "4c1dbec0-00de-45d7-ac47-4fe37036469a", cwd: "/Users/s/code/metronome-pocket",
            name: "metronome-pocket-ea", kind: "interactive"))
        #expect(file.isInteractive)

        let printed = try #require(ClaudeSessionFile.parse(Data(#"{"pid":1,"sessionId":"s","cwd":"/","kind":"print","name":""}"#.utf8)))
        #expect(!printed.isInteractive)
        #expect(printed.name == nil, "an empty name is no name")
        #expect(ClaudeSessionFile.parse(Data(#"{"pid":1,"cwd":"/"}"#.utf8)) == nil, "no conversation, nothing to resume")
        #expect(ClaudeSessionFile.parse(Data("not json".utf8)) == nil)
    }

    // MARK: the argv cleanup

    @Test("the flags after the program, minus every way of naming a conversation")
    func argvCleanup() {
        let flags = AgentArgv.resumeFlags
        #expect(flags(["claude", "--dangerously-skip-permissions"]) == ["--dangerously-skip-permissions"])
        #expect(flags(["claude", "--resume", "4c1dbec0", "--dangerously-skip-permissions"]) == ["--dangerously-skip-permissions"])
        #expect(flags(["claude", "-r", "abc", "--model", "opus"]) == ["--model", "opus"])
        // `--resume` alone opens a picker: the flag after it is not its value.
        #expect(flags(["claude", "--dangerously-skip-permissions", "--resume"]) == ["--dangerously-skip-permissions"])
        #expect(flags(["claude", "--resume", "--model", "opus"]) == ["--model", "opus"])
        #expect(flags(["claude", "--resume=abc", "--continue", "-c", "--verbose"]) == ["--verbose"])
        #expect(flags(["claude", "--session-id", "abc", "--fork-session", "--session-id=def"]) == [])
        // A path to it, or node running its cli.js: the flags start after it.
        #expect(flags(["/opt/homebrew/bin/claude", "--model", "opus"]) == ["--model", "opus"])
        #expect(flags(["node", "--no-warnings", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose"]) == ["--verbose"])
        #expect(flags([]) == [])
        #expect(flags(["claude"]) == [])
    }

    // MARK: the process table

    @Test("KERN_PROCARGS2 is argc, the path, padding, then the words")
    func procArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/claude".utf8) + [0, 0, 0, 0]
        for word in ["claude", "--resume", "abc"] { bytes += Array(word.utf8) + [0] }
        bytes += Array("HOME=/Users/s".utf8) + [0]
        #expect(ProcessTable.parseProcArgs(bytes) == ["claude", "--resume", "abc"])
        #expect(ProcessTable.parseProcArgs([1, 0]) == nil)
    }

    @Test("this process is in the real table under its real parent, and its argv reads back")
    func realTable() throws {
        let table = ProcessTable.current()
        let me = getpid()
        #expect(table.parent[me] == getppid())
        #expect(table.isAlive(me))
        let argv = try #require(ProcessTable.arguments(of: me))
        #expect(argv.first == CommandLine.arguments.first)
    }

    /// relay-pty-host 100 → zsh 101 → claude 102 → bash 103 → claude 104 (a
    /// nested one); relay-pty-host 200 → zsh 201; a claude 300 in no session.
    static let table = ProcessTable(
        parent: [100: 1, 101: 100, 102: 101, 103: 102, 104: 103, 200: 1, 201: 200, 300: 90, 90: 1],
        name: [100: "relay-pty-host", 101: "zsh", 102: "claude", 103: "bash", 104: "claude",
               200: "relay-pty-host", 201: "zsh", 300: "claude", 90: "Terminal"])
    static let hosts: [Int32: String] = [100: "aaaa0001", 200: "aaaa0002"]

    @Test("a process's session is its nearest relay-pty-host ancestor, and one in no session has none")
    func hostWalk() {
        #expect(Self.table.host(of: 102, among: Self.hosts)?.id == "aaaa0001")
        #expect(Self.table.host(of: 102, among: Self.hosts)?.depth == 2)
        #expect(Self.table.host(of: 104, among: Self.hosts)?.depth == 4)
        #expect(Self.table.host(of: 300, among: Self.hosts) == nil)
        #expect(Self.table.host(of: 999, among: Self.hosts) == nil)
    }

    @Test("a reading: the agent nearest each host, what is running file or not, and every conversation claimed")
    func reading() {
        let files = [
            ClaudeSessionFile(pid: 104, sessionId: "nested", cwd: "/tmp", name: nil, kind: "interactive"),
            ClaudeSessionFile(pid: 102, sessionId: "outer", cwd: "/Users/s/code/a", name: "a fixes", kind: "interactive"),
            ClaudeSessionFile(pid: 300, sessionId: "elsewhere", cwd: "/", name: nil, kind: "interactive"),
            ClaudeSessionFile(pid: 555, sessionId: "dead", cwd: "/", name: nil, kind: "interactive"),
            ClaudeSessionFile(pid: 201, sessionId: "printed", cwd: "/", name: nil, kind: "print"),
        ]
        let argv: (Int32) -> [String]? = { pid in
            pid == 102 ? ["claude", "--resume", "old", "--dangerously-skip-permissions"] : ["claude"]
        }
        let reading = AgentReading.read(files: files, hosts: Self.hosts, table: Self.table, argv: argv)
        #expect(reading.hosts == ["aaaa0001", "aaaa0002"])
        #expect(reading.sightings["aaaa0001"] == AgentSighting(
            cli: "claude", sessionId: "outer", cwd: "/Users/s/code/a",
            args: ["--dangerously-skip-permissions"], name: "a fixes"))
        #expect(reading.sightings["aaaa0002"] == nil, "a -p run is not a conversation")
        #expect(reading.running == ["aaaa0001"])
        #expect(reading.claimed == ["nested", "outer", "elsewhere"], "a dead pid claims nothing")

        // A resumed claude that has not written its file yet is running.
        let early = AgentReading.read(files: [], hosts: Self.hosts, table: Self.table, argv: argv)
        #expect(early.running == ["aaaa0001"])
        #expect(early.sightings.isEmpty)
    }

    // MARK: what the ledger is told

    static func record(_ paneId: String, _ session: String, args: [String] = [], name: String? = nil) -> PaneAgent {
        PaneAgent(paneId: paneId, cli: "claude", sessionId: session, cwd: "/Users/s/code/a",
                  args: args, name: name, updatedAt: 1)
    }

    @Test("a new or changed agent is recorded, the same one is not written again, and only an exit with the shell alive forgets")
    func ledgerSync() {
        let seen = AgentSighting(cli: "claude", sessionId: "outer", cwd: "/Users/s/code/a", args: ["-x"], name: "a")
        var reading = AgentReading(hosts: ["r1", "r2", "r3"], running: ["r1", "r3"], sightings: ["r1": seen])
        let panes: [(paneId: String, relayId: String)] = [("p1", "r1"), ("p2", "r2"), ("p3", "r3"), ("p4", "dead")]

        // Nothing known yet: p1 is recorded; p2 has nothing to forget.
        let first = AgentLedgerSync.changes(panes: panes, records: [:], reading: reading, holding: [], now: 42)
        #expect(first == [.record(PaneAgent(paneId: "p1", cli: "claude", sessionId: "outer",
                                              cwd: "/Users/s/code/a", args: ["-x"], name: "a", updatedAt: 42))])

        let kept: [String: PaneAgent] = [
            "p1": Self.record("p1", "outer", args: ["-x"], name: "a"),
            "p2": Self.record("p2", "exited"),
            "p3": Self.record("p3", "starting"),
            "p4": Self.record("p4", "rebooted"),
        ]
        // p1 unchanged: no write. p2's shell is alive with no claude in it:
        // the agent exited on its own. p3 has a claude with no file yet:
        // kept. p4's session is gone — the reboot — kept.
        #expect(AgentLedgerSync.changes(panes: panes, records: kept, reading: reading, holding: [], now: 43)
            == [.forget(paneId: "p2")])
        // A pane just resumed is left alone even before its claude is up.
        #expect(AgentLedgerSync.changes(panes: panes, records: kept, reading: reading, holding: ["p2"], now: 43) == [])

        // A different conversation in the same pane replaces the record.
        reading.sightings["r1"]?.sessionId = "newer"
        let changed = AgentLedgerSync.changes(panes: [("p1", "r1")], records: kept, reading: reading, holding: [], now: 44)
        #expect(changed.count == 1)
        if case .record(let agent) = changed.first { #expect(agent.sessionId == "newer" && agent.updatedAt == 44) }
    }

    // MARK: the command line

    @Test("a resume runs claude --resume with the recorded flags, the API key unset after the login files, in the recorded directory")
    func commandLine() throws {
        let agent = Self.record("p1", "4c1dbec0-00de", args: ["--dangerously-skip-permissions", "--append-system-prompt", "be terse; it's fine"])
        let line = try #require(AgentResume.line(agent))
        #expect(line == "unset ANTHROPIC_API_KEY CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION; "
            + "'claude' '--resume' '4c1dbec0-00de' '--dangerously-skip-permissions' '--append-system-prompt' 'be terse; it'\\''s fine'")
        let argv = LocalSpawner.buildShellArgs(id: "beef0002", cols: 120, rows: 50, cwd: agent.cwd, line: line)
        #expect(Array(argv.prefix(4)) == ["beef0002", "120", "50", "/Users/s/code/a"])
        #expect(Array(argv[5...6]) == ["-li", "-c"])
        #expect(argv[7] == line + "\nexit $?", "the wrapper that keeps a shell under the agent, so it can be BLOCKED")

        var other = agent
        other.cli = "codex"
        #expect(AgentResume.line(other) == nil, "a CLI this build cannot resume is not offered")
    }

    // MARK: which panes can resume

    static func pane(_ id: String, session: String?, server: String? = nil, kind: PaneKind = .pty) -> Pane {
        Pane(id: id, laneId: "L\(id)", position: 0, kind: kind, relaySessionId: session, relayServer: server,
             url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1,
             zoom: 1, mobile: false, muted: false, volume: 100)
    }

    @Test("resumable: a local terminal with a record whose session is not running, in strip order, not one already resuming")
    func resumable() {
        let panes = [
            Self.pane("dead1", session: "d0000001"),
            Self.pane("live", session: "a0000001"),
            Self.pane("remote", session: "d0000002", server: "yorkshire"),
            Self.pane("norecord", session: "d0000003"),
            Self.pane("web", session: nil, kind: .web),
            Self.pane("resuming", session: "d0000004"),
            Self.pane("dead2", session: "d0000005"),
        ]
        var records: [String: PaneAgent] = [:]
        for id in ["dead1", "live", "remote", "web", "resuming", "dead2"] { records[id] = Self.record(id, "s-\(id)") }
        let got = AgentResume.resumable(
            panes: panes, records: records, live: [SessionKey(id: "a0000001")], holding: ["resuming"])
        #expect(got.map(\.paneId) == ["dead1", "dead2"])
    }

    @Test("resume all: each conversation once, and none a live claude already has open")
    func plan() {
        let candidates = [
            Self.record("p1", "one"), Self.record("p2", "open-elsewhere"),
            Self.record("p3", "one"), Self.record("p4", "two"),
        ]
        let plan = AgentResume.plan(candidates, claimed: ["open-elsewhere"])
        #expect(plan.go.map(\.paneId) == ["p1", "p4"])
        #expect(plan.skipped.map(\.agent.paneId) == ["p2", "p3"])
        #expect(AgentResume.label(Self.record("p", "4c1dbec0-00de-45d7")) == "4c1dbec0")
        #expect(AgentResume.label(Self.record("p", "x", name: "max-pane fixes")) == "max-pane fixes")
    }

    @Test("the socket's resume op: a lane, or all when none is named")
    func socket() {
        guard case .resume("3")? = OpenServer.parse(#"{"op":"resume","lane":"3"}"#) else {
            Issue.record("resume with a lane did not parse")
            return
        }
        guard case .resume("all")? = OpenServer.parse(#"{"op":"resume"}"#) else {
            Issue.record("resume with no lane is all")
            return
        }
    }

    @Test("the status bar's offer counts agents and goes away at none")
    func statusOffer() {
        #expect(StatusBar.resumeText(12) == "$ RESUME 12 AGENTS")
        #expect(StatusBar.resumeText(1) == "$ RESUME 1 AGENT")
        let bar = StatusBar()
        bar.setResume(3)
        #expect(bar.resumeText == "$ RESUME 3 AGENTS")
        bar.setResume(0)
        #expect(bar.resumeText == "")
    }

    @Test("the watch hands over a reading, and a poke during one becomes one more")
    func watch() async throws {
        let watch = AgentWatch()
        watch.minimumInterval = 0
        watch.read = { AgentReading(hosts: ["r1"]) }
        var readings = 0
        watch.onReading = { _ in readings += 1 }
        watch.poke()
        watch.poke()
        watch.poke()
        for _ in 0..<50 where readings < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(readings == 2)
        #expect(watch.latest?.hosts == ["r1"])
    }

    // MARK: the pane

    @Test("a dead pane with an agent offers $ RESUME, ↩'s button fires, and a resume rebinds the same pane in place")
    func paneResumesInPlace() async throws {
        let rig = try AppUpdateTests.LaneRig(session: "dead0001")
        defer { rig.tearDown() }
        var fresh: [String: AppUpdateTests.ExitAttachment] = [:]
        rig.strip.attachmentFactory = { key in
            let attachment = AppUpdateTests.ExitAttachment(sessionId: key.id)
            fresh[key.id] = attachment
            return attachment
        }
        try rig.store.newTerminalLane(relaySessionId: "aaaa0001", near: nil)
        try rig.store.newTerminalLane(relaySessionId: "dead0001", near: nil)
        await rig.settle()
        let pane = try #require(rig.store.state.lanes[1].panes.first)
        let lanesBefore = rig.store.state.lanes.map(\.id)
        let controller = try #require(rig.controllers[pane.id])

        var asked: [String] = []
        rig.strip.onResumePane = { asked.append($0) }
        rig.strip.setResumeOffers([pane.id: "max-pane fixes"])
        #expect(!controller.offersResume, "a live session offers nothing")

        // The session is gone: the registry has only the other one.
        rig.strip.sessionsChanged([SessionKey(id: "aaaa0001"): SessionTelemetry(sessionId: "aaaa0001")])
        #expect(controller.offersResume)
        #expect(controller.bannerText == "SESSION GONE · MAX-PANE FIXES")
        #expect(controller.exitActionLabel == "$ RESUME")
        controller.pressExitAction()
        #expect(asked == [pane.id])

        // Nothing to resume any more: back to saying the session is gone.
        rig.strip.setResumeOffers([:])
        #expect(!controller.offersResume)
        #expect(controller.bannerText == "RECONNECTING")
        rig.strip.setResumeOffers([pane.id: "max-pane fixes"])

        try rig.strip.rebindPane(pane.id, to: SessionKey(id: "beef0002"))
        #expect(rig.store.state.lanes.map(\.id) == lanesBefore, "no new lane, same order")
        let rebound = try #require(rig.store.pane(pane.id))
        #expect(rebound.relaySessionId == "beef0002")
        #expect(rebound.laneId == pane.laneId && rebound.position == pane.position)
        #expect(controller.sessionKey == SessionKey(id: "beef0002"))
        #expect(fresh["beef0002"] != nil, "the pane attached to the new session")
        #expect(!controller.offersResume)
    }
}
