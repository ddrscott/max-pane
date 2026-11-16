import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// Parking an idle Claude (ADR-0048): the session file's new fields, the
/// sidebar's `// PARKED` group, Park Idle Lanes' selection, relay-tty's
/// replies, and the ledger keeping a parked lane bound to its conversation.
/// Nothing here signals a process or reaches a real relay-tty.
@Suite("parking an idle Claude")
struct AgentParkTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    static func parked(_ name: String? = "fix-auth", daysAgo: Double = 3) -> ParkedAgent {
        ParkedAgent(
            sessionId: "conv-1", cwd: "/Users/s/code/a", flags: ["--dangerously-skip-permissions"],
            name: name, parkedAt: (now.timeIntervalSince1970 - daysAgo * day) * 1000)
    }

    static func telemetry(
        _ id: String, cwd: String = NSHomeDirectory() + "/code/a", state: AgentState = .idle,
        quiet: TimeInterval = 2 * day, inputQuiet: TimeInterval? = nil, stateChangedAgo: TimeInterval? = nil,
        parked: ParkedAgent? = nil, keep: Bool = false, knows: Bool = true, server: String? = nil
    ) -> SessionTelemetry {
        var t = SessionTelemetry(
            sessionId: id, server: server, title: "claude \(id)", cwd: cwd, command: "zsh", state: state,
            lastActivity: now.addingTimeInterval(-quiet), isRunning: true)
        t.lastInputAt = now.addingTimeInterval(-(inputQuiet ?? quiet))
        // The agent settled when the last of its input and output did,
        // unless a test says otherwise: no draft.
        t.agentStateChangedAt = now.addingTimeInterval(-(stateChangedAgo ?? min(quiet, inputQuiet ?? quiet)))
        t.parked = parked
        t.keep = keep
        t.knowsParking = knows
        return t
    }

    static func lane(_ id: String, session: String, keepLive: Bool = false) -> Lane {
        Lane(
            id: id, ordinal: 1, widthPt: 500, title: nil,
            projectRoot: NSHomeDirectory() + "/code/a", projectSource: .cwd,
            createdAt: 0, lastFocusAt: 0, keepLive: keepLive, dock: nil, span: 1,
            panes: [Pane(
                id: "p-" + id, laneId: id, position: 0, kind: .pty,
                relaySessionId: session, relayServer: nil, url: nil, scrollY: nil,
                dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1,
                mobile: false, muted: false, volume: 100)])
    }

    // MARK: the session file

    @Test("the session file's parked, keep, lastInputAt and foregroundPid are read, and an older file knows nothing of parking")
    func sessionFile() throws {
        let newer = """
        {"id":"abc","command":"zsh","args":[],"cwd":"/tmp","createdAt":1,"status":"running","cols":80,"rows":24,
         "lastInputAt":1799999000000,"foregroundPid":4242,"keep":true,"agentStateChangedAt":1799998000000,
         "parked":{"agent":"claude","sessionId":"conv-1","cwd":"/tmp/a","flags":["--x"],"name":"fix","parkedAt":1799990000000}}
        """
        let info = try JSONDecoder().decode(RelaySessionInfo.self, from: Data(newer.utf8))
        #expect(info.knowsParking)
        #expect(info.parked == ParkedAgent(sessionId: "conv-1", cwd: "/tmp/a", flags: ["--x"], name: "fix",
                                           parkedAt: 1_799_990_000_000))
        let t = SessionTelemetry(info)
        #expect(t.keep && t.isParkedHere && t.knowsParking)
        #expect(t.lastInputAt == Date(timeIntervalSince1970: 1_799_999_000))

        let older = """
        {"id":"abc","command":"zsh","args":[],"cwd":"/tmp","createdAt":1,"status":"running","cols":80,"rows":24}
        """
        let old = try JSONDecoder().decode(RelaySessionInfo.self, from: Data(older.utf8))
        #expect(!old.knowsParking && old.parked == nil)

        // A `parked` with a field of the wrong type costs that field, not the session.
        let odd = """
        {"id":"abc","command":"zsh","args":[],"cwd":"/tmp","createdAt":1,"status":"running","cols":80,"rows":24,
         "parked":{"sessionId":"conv-2","flags":"oops","parkedAt":"soon"}}
        """
        let lenient = try JSONDecoder().decode(RelaySessionInfo.self, from: Data(odd.utf8))
        #expect(lenient.parked?.sessionId == "conv-2" && lenient.parked?.flags == [] && lenient.parked?.agent == "claude")
    }

    @Test("a parked session is never BLOCKED, WORKING or DONE, so it never counts toward a roll-up or the footer")
    func parkedIsAtRest() {
        let t = Self.telemetry("a", state: .blocked, parked: Self.parked())
        #expect(t.state == .idle && !t.needsAttention)
        #expect(SidebarModel.blockedCount(["a": t]) == 0)
    }

    // MARK: the sidebar

    @Test("parked lanes sort into a dimmed // PARKED group at the bottom, with their parked age, below every server")
    func parkedGroup() {
        let t: [SessionKey: SessionTelemetry] = [
            "awake": Self.telemetry("awake", state: .blocked),
            "sleepy": Self.telemetry("sleepy", state: .blocked, parked: Self.parked(daysAgo: 3)),
            "remote": Self.telemetry("remote", parked: Self.parked(), server: "wsl"),
        ]
        let rows = SidebarModel.rows(
            lanes: [Self.lane("L1", session: "sleepy")], telemetry: t,
            servers: ["wsl": .connected], now: Self.now)

        guard case .group(let last)? = rows.last(where: { if case .group = $0 { return true } else { return false } })
        else { Issue.record("no groups"); return }
        #expect(last.isParked && last.header == "PARKED")
        #expect(last.countText == "1 PARKED" && last.blocked == 0)

        guard case .entry(let sleepy)? = rows.last else { Issue.record("no rows"); return }
        #expect(sleepy.sessionId == "sleepy" && sleepy.parked)
        #expect(sleepy.age == "parked 3d")
        #expect(sleepy.chip.isEmpty && !sleepy.needsAttention)
        #expect(sleepy.laneId == "L1")

        // The blocked session still rolls up under its own project, and the
        // parked one is not counted there.
        let local = rows.compactMap { row -> SidebarModel.Group? in
            if case .group(let g) = row, g.path == "~/code/a" { return g } else { return nil }
        }
        #expect(local.first?.blocked == 1 && local.first?.total == 1)
        // A remote parked session stays with its server (ADR-0046's rule).
        #expect(rows.contains { if case .entry(let e) = $0 { return e.sessionId == "remote" && !e.parked } else { return false } })
    }

    @Test("folding // PARKED puts the parked lanes away, and folding their project does not")
    func parkedFold() {
        let t: [SessionKey: SessionTelemetry] = ["sleepy": Self.telemetry("sleepy", parked: Self.parked())]
        let lanes = [Self.lane("L1", session: "sleepy")]
        #expect(SidebarModel.groups(of: lanes[0], telemetry: t) == [SidebarModel.parkedGroup])
        #expect(SidebarModel.hiddenLanes(lanes: lanes, telemetry: t, collapsed: [SidebarModel.parkedGroup], hasServers: false) == ["L1"])
        #expect(SidebarModel.hiddenLanes(lanes: lanes, telemetry: t, collapsed: ["~/code/a"], hasServers: false).isEmpty)
    }

    @Test("a refused park's reason sits on the row until it is cleared")
    func rowNote() {
        let t: [SessionKey: SessionTelemetry] = ["a": Self.telemetry("a")]
        let rows = SidebarModel.rows(lanes: [], telemetry: t, notes: ["a": "park refused: claude is busy"], now: Self.now)
        let entry = rows.compactMap { row -> SidebarModel.Entry? in if case .entry(let e) = row { return e } else { return nil } }.first
        #expect(entry?.note == "park refused: claude is busy")
    }

    @Test("the parked age reads in minutes, hours and days")
    func parkedAge() {
        #expect(ParkedAgent.shortAge(30) == "now")
        #expect(ParkedAgent.shortAge(5 * 60) == "5m")
        #expect(ParkedAgent.shortAge(5 * 3600) == "5h")
        #expect(ParkedAgent.shortAge(3 * Self.day + 100) == "3d")
        #expect(ParkedAgent(sessionId: "0123456789", cwd: "/").label == "01234567")
    }

    // MARK: Park Idle Lanes

    static func candidate(
        _ t: SessionTelemetry, hasClaude: Bool = true, keptLoaded: Bool = false
    ) -> ParkCandidate {
        ParkCandidate(key: t.key, name: t.sessionId, telemetry: t, hasClaude: hasClaude, keptLoaded: keptLoaded)
    }

    @Test("park_idle_after reads 24h, 90m, 2d, 1w and bare hours, and refuses the rest")
    func durations() {
        #expect(ParkIdle.parse("24h") == 86_400)
        #expect(ParkIdle.parse(" 90m ") == 5400)
        #expect(ParkIdle.parse("2d") == 172_800)
        #expect(ParkIdle.parse("1w") == 604_800)
        #expect(ParkIdle.parse("6") == 21_600)
        #expect(ParkIdle.parse("0h") == nil && ParkIdle.parse("soon") == nil && ParkIdle.parse("") == nil)
        #expect(ParkIdle.describe(86_400) == "1 day" && ParkIdle.describe(7200) == "2 hours" && ParkIdle.describe(5400) == "90 minutes")
    }

    @Test("only quiet local Claude sessions on a relay-tty that can park are listed; kept, blocked, working and drafted ones are skipped, each with why")
    func idleSelection() {
        let all = [
            Self.candidate(Self.telemetry("old", quiet: 5 * Self.day)),
            Self.candidate(Self.telemetry("idle", quiet: 2 * Self.day)),
            // Output quiet, but somebody typed an hour ago: not idle.
            Self.candidate(Self.telemetry("typed", quiet: 3 * Self.day, inputQuiet: 3600)),
            // Talking now: not idle, not "skipped" either.
            Self.candidate(Self.telemetry("busy", quiet: 60)),
            Self.candidate(Self.telemetry("kept", keep: true)),
            Self.candidate(Self.telemetry("pinned"), keptLoaded: true),
            Self.candidate(Self.telemetry("blocked", state: .blocked)),
            Self.candidate(Self.telemetry("working", state: .working)),
            // Input after the agent last settled: a draft at the prompt.
            Self.candidate(Self.telemetry("draft", quiet: 3 * Self.day, inputQuiet: 2 * Self.day,
                                          stateChangedAgo: 2.5 * Self.day)),
            Self.candidate(Self.telemetry("asleep", parked: Self.parked())),
            Self.candidate(Self.telemetry("shell"), hasClaude: false),
            Self.candidate(Self.telemetry("old-relay", knows: false)),
            Self.candidate(Self.telemetry("remote", server: "wsl")),
        ]
        let plan = ParkIdle.plan(all, quietFor: Self.day, now: Self.now)
        #expect(plan.park.map(\.name) == ["old", "idle"], "oldest-touched first")
        let skipped = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.candidate.name, $0.why) })
        #expect(skipped == [
            "kept": "kept loaded", "pinned": "kept loaded",
            "blocked": "blocked, waiting on you", "working": "working",
            "draft": "an unsent draft at the prompt",
        ])

        let summary = ParkIdle.summary(park: plan.park, skipped: plan.skipped, now: Self.now)
        #expect(summary.contains("$ park  old — quiet 5d"))
        #expect(summary.contains("  skip  draft — an unsent draft at the prompt"))
    }

    // MARK: relay-tty's replies

    @Test("relay-tty's replies: done, a refusal with its reason, a missing route is an older relay-tty, nobody home is a failure")
    func replies() {
        #expect(ParkReply.outcome(status: 200, data: Data("{\"ok\":true}".utf8)) == .done)
        // relay-tty's own body: {ok, session, reason, message, error}.
        func refusal(_ code: String, _ message: String) -> Data {
            Data("{\"ok\":false,\"session\":\"abc\",\"reason\":\"\(code)\",\"message\":\"\(message)\",\"error\":\"\(message)\"}".utf8)
        }
        #expect(ParkReply.outcome(status: 409, data: refusal("claude-busy", "Claude reports itself busy (use --force to park anyway)"))
                == .refused("Claude reports itself busy", forceable: true))
        #expect(ParkReply.outcome(status: 409, data: refusal("agent-working", "the agent is working (use --force to park anyway)"))
                == .refused("the agent is working", forceable: true))
        #expect(ParkReply.outcome(status: 409, data: refusal("no-claude", "no Claude Code process in this session"))
                == .refused("no Claude Code process in this session", forceable: false))
        #expect(ParkReply.outcome(status: 409, data: refusal("already-parked", "already parked"))
                == .refused("already parked", forceable: false))
        // Express's own 404 for a route it does not have, against an older relay-tty.
        #expect(ParkReply.outcome(status: 404, data: Data("<pre>Cannot POST /api/sessions/x/park</pre>".utf8)) == .unsupported)
        // The route, about a session it does not know.
        #expect(ParkReply.outcome(status: 404, data: Data("{\"error\":\"Session not found\"}".utf8))
                == .refused("Session not found", forceable: false))
        #expect(ParkReply.outcome(status: 0, data: nil, transportError: "Could not connect to the server.")
                == .failed("Could not connect to the server."))
        #expect(LocalAgentParker.cliOutcome(exit: 0, output: "parked abc") == .done)
        #expect(LocalAgentParker.cliOutcome(exit: 1, output: "error: unknown command 'park'") == .unsupported)
        #expect(LocalAgentParker.cliOutcome(exit: 1, output: "error: a draft may be unsent (use --force to park anyway)\n")
                == .refused("a draft may be unsent", forceable: true))
        #expect(LocalAgentParker.cliOutcome(exit: 1, output: "no Claude Code process in this session")
                == .refused("no Claude Code process in this session", forceable: false))
    }

    @Test("the local server's address comes from relay-tty's server.json, else its default port")
    func serverAddress() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("park-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.json")
        #expect(LocalAgentParker.serverURL(file: file).absoluteString == "http://localhost:7680")
        try Data("{\"url\":\"http://localhost:18999\",\"pid\":1}".utf8).write(to: file)
        #expect(LocalAgentParker.serverURL(file: file).absoluteString == "http://localhost:18999")
    }

    // MARK: the ledger

    @Test("a parked lane keeps its pane_agent record, and gets one from relay-tty's parked when it had none")
    func ledgerKeepsParked() {
        // r1's shell is alive with no claude in it: without parking, an exit.
        let reading = AgentReading(hosts: ["r1", "r2"], running: [], sightings: [:])
        let kept = ["p1": PaneAgent(paneId: "p1", cli: "claude", sessionId: "conv-1", cwd: "/Users/s/code/a", args: [], name: nil, updatedAt: 1)]
        let sleeping = ParkedAgent(sessionId: "conv-1", cwd: "/Users/s/code/a", flags: ["-x"], name: "a")
        let panes: [(paneId: String, relayId: String)] = [("p1", "r1"), ("p2", "r2")]

        #expect(AgentLedgerSync.changes(panes: panes, records: kept, reading: reading, holding: [], now: 9)
                == [.forget(paneId: "p1")], "unparked, an agent with its shell alive has exited")
        #expect(AgentLedgerSync.changes(panes: panes, records: kept, reading: reading, holding: [], now: 9,
                                        parked: ["r1": sleeping]) == [], "parked, the record stays")
        let fresh = AgentLedgerSync.changes(panes: panes, records: [:], reading: reading, holding: [], now: 9,
                                            parked: ["r2": ParkedAgent(sessionId: "conv-2", cwd: "/w", flags: ["-y"], name: "b")])
        #expect(fresh == [.record(PaneAgent(paneId: "p2", cli: "claude", sessionId: "conv-2", cwd: "/w",
                                             args: ["-y"], name: "b", updatedAt: 9))])
    }
}
