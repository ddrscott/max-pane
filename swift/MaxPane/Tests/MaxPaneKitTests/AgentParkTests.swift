import AppKit
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
        #expect(summary.contains("$ park  old — quiet 5d (output)"))
        #expect(summary.contains("  skip  draft — quiet 2d (output) · an unsent draft at the prompt"))
    }

    // MARK: relay-tty's quiet time (agentQuietSince)

    static func quiet(_ ago: TimeInterval, _ source: String = "claude") -> AgentQuiet {
        AgentQuiet(since: now.addingTimeInterval(-ago), source: source)
    }

    @Test("with relay-tty's agentQuietSince, a Claude idle for weeks is parked even though a repaint just touched its output")
    func agentQuietSelection() {
        // Repainted a minute ago: by output alone it is not idle. (Its last
        // input is older than Claude's last status, as agentQuietSince is
        // the later of the two: no draft.)
        let repainted = Self.telemetry("repainted", quiet: 60, inputQuiet: 40 * Self.day)
        #expect(ParkIdle.plan([Self.candidate(repainted)], quietFor: Self.day, now: Self.now).park.isEmpty,
                "without agentQuietSince, today's rule: output counts")

        var withQuiet = Self.candidate(repainted)
        withQuiet.agentQuiet = Self.quiet(31 * Self.day)
        // Claude said something an hour ago, though output has been still for days.
        var recent = Self.candidate(Self.telemetry("recent", quiet: 5 * Self.day))
        recent.agentQuiet = Self.quiet(3600)
        // pty-host calls it working off the repaint; Claude's own status is idle.
        var repaintWorking = Self.candidate(Self.telemetry("repaint-working", state: .working, quiet: 30, inputQuiet: 10 * Self.day))
        repaintWorking.agentQuiet = Self.quiet(3 * Self.day)
        // relay-tty fell back to output for this one: its working still counts.
        var outputWorking = Self.candidate(Self.telemetry("output-working", state: .working))
        outputWorking.agentQuiet = Self.quiet(2 * Self.day, "output")
        // The last input is what agentQuietSince is: typed after Claude settled.
        var draft = Self.candidate(Self.telemetry("draft", quiet: 60, inputQuiet: 4 * Self.day))
        draft.agentQuiet = Self.quiet(4 * Self.day)
        // An old pty-host: its file knows nothing of parking, but the server measured it.
        var old = Self.telemetry("old-host", quiet: 60, knows: false)
        old.lastInputAt = nil
        old.isOldPtyHost = true
        var oldHost = Self.candidate(old, hasClaude: false)
        oldHost.agentQuiet = Self.quiet(10 * Self.day)
        // Same file, no agentQuietSince: an older server, which cannot park it.
        let oldHostOldServer = Self.candidate(old)

        let plan = ParkIdle.plan(
            [withQuiet, recent, repaintWorking, outputWorking, draft, oldHost, oldHostOldServer],
            quietFor: Self.day, now: Self.now)
        #expect(plan.park.map(\.name) == ["repainted", "old-host", "repaint-working"], "quietest first")
        let skipped = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.candidate.name, $0.why) })
        #expect(skipped == ["output-working": "working", "draft": "an unsent draft at the prompt"])

        let summary = ParkIdle.summary(park: plan.park, skipped: plan.skipped, now: Self.now)
        #expect(summary.contains("$ park  repainted — quiet 31d (claude)"))
        #expect(summary.contains("$ park  old-host — quiet 10d (claude) · old pty-host: never shows PARKED"))
        #expect(summary.contains("  skip  output-working — quiet 2d (output) · working"))
    }

    @Test("agentQuietSince and agentQuietSource are read off GET /api/sessions, and a session without them is left out")
    func agentQuietParse() {
        let body = Data("""
        {"sessions":[
          {"id":"a","status":"running","agentQuietSince":1797408000000,"agentQuietSource":"claude"},
          {"id":"b","status":"running","agentQuietSince":1799913600000},
          {"id":"c","status":"running","lastActivity":1799999999000}
        ]}
        """.utf8)
        let quiet = AgentQuiet.parse(sessionList: body)
        #expect(quiet["a"] == AgentQuiet(since: Date(timeIntervalSince1970: 1_797_408_000), source: "claude"))
        #expect(quiet["b"]?.source == "output")
        #expect(quiet["c"] == nil)
        #expect(AgentQuiet.parse(sessionList: Data("<html>".utf8)).isEmpty)
    }

    @Test("an old pty-host's file is recognized the way relay-tty does: a foreground job without its pid, and no input")
    func legacyHostFile() throws {
        func info(_ extra: String) throws -> RelaySessionInfo {
            try JSONDecoder().decode(RelaySessionInfo.self, from: Data("""
            {"id":"x","command":"zsh","args":[],"cwd":"/tmp","createdAt":1,"status":"running","cols":80,"rows":24\(extra)}
            """.utf8))
        }
        #expect(try info(",\"foregroundProcess\":\"2.1.3\"").isLegacyHost)
        #expect(try !info(",\"foregroundProcess\":\"2.1.3\",\"foregroundPid\":42").isLegacyHost)
        #expect(try !info(",\"foregroundProcess\":\"2.1.3\",\"lastInputAt\":1").isLegacyHost)
        #expect(try !info("").isLegacyHost, "no foreground job: nothing to go by")
    }

    @Test("a lane parked on an old pty-host is found from relay-tty's parked/ copy, and only while its shell has no claude")
    func oldHostLedger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ conv: String, relay: String) throws {
            try Data("""
            {"agent":"claude","sessionId":"\(conv)","cwd":"/tmp/a","flags":["--x"],"name":"n-\(conv)","parkedAt":1,"relaySessionId":"\(relay)"}
            """.utf8).write(to: dir.appendingPathComponent("\(conv).json"))
        }
        try write("conv-old", relay: "old")
        try write("conv-new", relay: "new")
        try write("conv-gone", relay: "gone")
        try write("conv-back", relay: "back")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))
        let entries = ParkLedger.entries(in: dir)
        #expect(entries.count == 4)

        var old = Self.telemetry("old", knows: false)
        old.lastInputAt = nil
        // A new host's park says so in its own file: not this path.
        let new = Self.telemetry("new", parked: Self.parked())
        var back = Self.telemetry("back", knows: false)
        back.lastInputAt = nil
        let sessions = [old.key: old, new.key: new, back.key: back]
        let asleep = ParkLedger.asleepOnOldHosts(entries, sessions: sessions, sightings: ["back"])
        #expect(Array(asleep.keys) == ["old"], "gone is not running; back has its claude again")
        #expect(asleep["old"]?.sessionId == "conv-old" && asleep["old"]?.flags == ["--x"])

        // The lane keeps its record from that copy, as a parked one does.
        let reading = AgentReading(hosts: ["old"], running: [], sightings: [:])
        let changes = AgentLedgerSync.changes(
            panes: [("p1", "old")], records: [:], reading: reading, holding: [], now: 9, parked: asleep)
        #expect(changes == [.record(PaneAgent(paneId: "p1", cli: "claude", sessionId: "conv-old", cwd: "/tmp/a",
                                              args: ["--x"], name: "n-conv-old", updatedAt: 9))])
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
        // no-record: relay-tty could not write the parked/ copy and signalled
        // nothing. A refusal with its reason, never Park Anyway.
        #expect(ParkReply.outcome(status: 500, data: refusal("no-record", "could not write /x/parked, so the conversation would not be recoverable"))
                == .refused("could not write /x/parked, so the conversation would not be recoverable", forceable: false))
        #expect(ParkReply.outcome(status: 500, data: Data("oops".utf8)) == .failed("HTTP 500: oops"))
    }

    @Test("a park on an old pty-host comes back with relay-tty's note, and an unpark by conversation with its new session")
    func oldHostReplies() {
        let parked = Data("""
        {"ok":true,"session":"abc","pid":4242,"signal":"SIGTERM","legacyHost":true,
         "note":"This session's pty-host predates parking, so it won't show as PARKED; relay unpark conv-1 brings the conversation back in a new session.",
         "parked":{"agent":"claude","sessionId":"conv-1","cwd":"/tmp/a","flags":[],"parkedAt":1}}
        """.utf8)
        guard case .parkedOnOldHost(let agent, let note) = ParkReply.outcome(status: 200, data: parked) else {
            Issue.record("expected parkedOnOldHost")
            return
        }
        #expect(agent.sessionId == "conv-1" && note.contains("relay unpark conv-1"))
        #expect(ParkReply.outcome(status: 200, data: Data("{\"ok\":true,\"session\":\"abc\",\"legacyHost\":false}".utf8)) == .done)
        #expect(ParkReply.outcome(status: 200, data: Data("""
            {"ok":true,"session":"fresh1","conversation":"conv-1","line":"claude --resume conv-1","spawned":true}
            """.utf8)) == .spawned(session: "fresh1"))
        #expect(ParkReply.outcome(status: 200, data: Data("{\"ok\":true,\"session\":\"abc\",\"spawned\":false}".utf8)) == .done)
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

// MARK: - render sheet

/// The sidebar with a `// PARKED` group, and a parked pane's banner, drawn
/// by the real views offscreen. `MAXPANE_SHOTS=<dir>` to write it.
@Suite("parked rendering")
@MainActor
struct ParkedRenderTests {
    @Test("renders the sidebar with a // PARKED group and a parked pane's $ WAKE banner")
    func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED: set MAXPANE_SHOTS=<dir> to render the parked sheet")
            return
        }
        BlockedPulse.isReduced = { true }
        defer { BlockedPulse.isReduced = { Motion.isReduced } }
        let now = AgentParkTests.now
        let home = NSHomeDirectory()
        func t(_ id: String, _ title: String, _ cwd: String, state: AgentState = .idle, bps: Double = 0,
               ago: TimeInterval = 40, parkedAgo: Double? = nil) -> SessionTelemetry {
            var t = SessionTelemetry(
                sessionId: id, title: title, cwd: home + "/code/" + cwd, command: "zsh", state: state,
                bytesPerSecond: bps, lastActivity: now.addingTimeInterval(-ago), isRunning: true)
            t.knowsParking = true
            if let parkedAgo {
                t.parked = ParkedAgent(sessionId: id + "-conv", cwd: home + "/code/" + cwd, name: title,
                                       parkedAt: (now.timeIntervalSince1970 - parkedAgo) * 1000)
            }
            return t
        }
        let telemetry: [SessionKey: SessionTelemetry] = [
            "a1": t("a1", "◑ ship park ui", "max-pane", state: .working, bps: 2300, ago: 1),
            "a2": t("a2", "✳ relay park api", "relay-tty", state: .blocked, ago: 90),
            "a3": t("a3", "✳ release-notes", "max-pane", ago: 600),
            "p1": t("p1", "fix-auth-flow", "trifecta", parkedAgo: 3 * 86_400),
            "p2": t("p2", "docs-sweep", "site", parkedAgo: 5 * 3600),
            "p3": t("p3", "migrate-billing", "trifecta", parkedAgo: 12 * 60),
        ]
        let rows = SidebarModel.rows(
            lanes: [AgentParkTests.lane("L1", session: "p1")], telemetry: telemetry,
            notes: ["a3": "park refused: a draft may be unsent"], now: now)

        let sidebarWidth: CGFloat = 300, paneWidth: CGFloat = 560
        let heights = rows.map { row -> CGFloat in
            if case .group = row { return SidebarGroupView.height } else { return SidebarEntryView.height }
        }
        let height = max(heights.reduce(8, +), 300)
        try AppearanceSheet.render(to: dir, named: "parked") {
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth + paneWidth + 1, height: height))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            var y = height - 4
            for (row, h) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .group(let g): view = SidebarGroupView(group: g)
                case .entry(let e): view = SidebarEntryView(entry: e)
                case .bookmark: continue
                }
                y -= h
                view.frame = NSRect(x: 0, y: y, width: sidebarWidth, height: h)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            let rule = NSView(frame: NSRect(x: sidebarWidth, y: 0, width: 1, height: height))
            rule.wantsLayer = true
            rule.layerBackgroundColor = Theme.laneBorder
            sheet.addSubview(rule)

            // The parked pane: its banner over the scrollback it kept.
            let banner = ReconnectingBanner(frame: NSRect(x: sidebarWidth + 1, y: height - 26, width: paneWidth, height: 26))
            banner.setState(.action("parked · fix-auth-flow", label: "wake"))
            sheet.addSubview(banner)
            let text = NSTextField(wrappingLabelWithString: """
                ~/code/trifecta $ claude --dangerously-skip-permissions --model opus
                ✳ fix-auth-flow
                ⏺ The token refresh now retries once on a 401 and the tests pass.
                > 
                ~/code/trifecta $ 
                """)
            text.font = Theme.mono(11)
            text.textColor = .secondaryLabelColor
            text.frame = NSRect(x: sidebarWidth + 13, y: height - 140, width: paneWidth - 26, height: 100)
            sheet.addSubview(text)
            banner.layoutSubtreeIfNeeded()
            return sheet
        }
    }
}
