import Darwin
import Foundation
import LanedCore

// Resume agent sessions after a reboot (ADR-0046).
//
// A reboot kills every relay-tty session. Each lane comes back from the
// ledger, but a pane only knows its `relay_session_id`, which is dead, and the
// thing worth getting back is the `claude` conversation that was running in
// it. So while the agent is alive the app notes which conversation it is, and
// when the session is gone the pane offers `$ RESUME`.
//
// Everything in this file is a pure function over a reading, or the reading
// itself. The window controller owns the timing; `AgentWatch` owns the queue.

/// One agent seen running in a pane's session.
struct AgentSighting: Equatable, Sendable {
    var cli: String
    var sessionId: String
    var cwd: String
    var args: [String]
    var name: String?
}

/// What Claude Code writes to `~/.claude/sessions/<pid>.json` for each process
/// it is running. Deleted when that process exits, so it has to be read while
/// the agent is alive — which is the whole reason the ledger keeps a copy.
struct ClaudeSessionFile: Equatable, Sendable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var name: String?
    /// `interactive` is a person's conversation. Anything else — a `-p`
    /// run, an SDK child — is nothing anyone would resume.
    var kind: String?

    var isInteractive: Bool { kind == nil || kind == "interactive" }

    static func parse(_ data: Data) -> ClaudeSessionFile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeSessionFile(pid: pid, sessionId: sessionId, cwd: cwd, name: name, kind: object["kind"] as? String)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Every file in the directory that parses. Which of them are alive is
    /// the process table's question, not this one's.
    static func all(in directory: URL = directory) -> [ClaudeSessionFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap(parse)
        }
    }
}

/// The argv an agent was started with, as the flags a resume passes back.
enum AgentArgv {
    /// The flags after the program, minus the ones that say which
    /// conversation to open. A resume names the conversation itself, so a
    /// `--resume <old>` or `--continue` left in would be a second, and
    /// conflicting, answer to that question.
    ///
    /// `--resume` takes an optional value in Claude Code: `claude --resume`
    /// alone opens a picker. So the word after it is its value only when it
    /// is not a flag. `argv[0]` may be `claude`, a path to it, or `node`
    /// running Claude's `cli.js`; the flags start after whichever it is.
    static func resumeFlags(_ argv: [String]) -> [String] {
        guard !argv.isEmpty else { return [] }
        let start = argv.firstIndex(where: isProgram).map { $0 + 1 } ?? 1
        var out: [String] = []
        var i = start
        while i < argv.count {
            let word = argv[i]
            i += 1
            switch word {
            case "--resume", "-r":
                if i < argv.count, !argv[i].hasPrefix("-") { i += 1 }
            case "--session-id":
                if i < argv.count { i += 1 }
            case "--continue", "-c", "--fork-session":
                continue
            default:
                if word.hasPrefix("--resume=") || word.hasPrefix("--session-id=") { continue }
                out.append(word)
            }
        }
        return out
    }

    private static func isProgram(_ word: String) -> Bool {
        let base = (word as NSString).lastPathComponent
        return base == "claude" || base == "cli.js" || base == "cli.mjs"
    }
}

/// Who is whose parent, and what each process is called: one `sysctl`.
struct ProcessTable: Equatable, Sendable {
    var parent: [Int32: Int32] = [:]
    /// `p_comm`: the executable's name, at most sixteen bytes. Claude Code
    /// sets its own to `claude`.
    var name: [Int32: String] = [:]

    func isAlive(_ pid: Int32) -> Bool { parent[pid] != nil }

    /// The relay session `pid` runs under, and how many parents up its
    /// `relay-pty-host` is. Nil for a process in no session of ours.
    func host(of pid: Int32, among hosts: [Int32: String]) -> (id: String, depth: Int)? {
        var at = pid
        for depth in 0..<32 {
            if let id = hosts[at] { return (id, depth) }
            guard let up = parent[at], up > 1, up != at else { return nil }
            at = up
        }
        return nil
    }

    static func current() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return ProcessTable() }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return ProcessTable() }
        var table = ProcessTable()
        for proc in procs.prefix(size / stride) {
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }
            table.parent[pid] = proc.kp_eproc.e_ppid
            var comm = proc.kp_proc.p_comm
            table.name[pid] = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        return table
    }

    /// A process's argv, from `KERN_PROCARGS2`: argc, the executable's path,
    /// padding, then argc NUL-terminated words. Nil when it cannot be read.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var i = 4
        // The executable's path, then the NULs that pad it.
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            out.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return out.count == argc ? out : nil
    }
}

/// One look at every agent on this Mac and which pane's session it is in.
struct AgentReading: Equatable, Sendable {
    /// Relay sessions whose `relay-pty-host` is alive.
    var hosts: Set<String> = []
    /// Relay sessions with a `claude` process anywhere under them, file or
    /// no file. A resumed agent can take a while to write its session file,
    /// and "the process is up" is what says it has not exited.
    var running: Set<String> = []
    /// The agent in each relay session: the one nearest its host, when a
    /// session somehow has two.
    var sightings: [String: AgentSighting] = [:]
    /// Every conversation a live process has open. Resuming one of these
    /// would put a second client on it (the stopgap did, once).
    var claimed: Set<String> = []

    static let cli = "claude"

    /// `hosts` is relay session id by `relay-pty-host` pid, from the relay
    /// session files. `argv` is a parameter so a test hands it a table.
    static func read(
        files: [ClaudeSessionFile], hosts: [Int32: String], table: ProcessTable,
        argv: (Int32) -> [String]?
    ) -> AgentReading {
        var reading = AgentReading(hosts: Set(hosts.values))
        for (pid, name) in table.name where name == cli {
            if let host = table.host(of: pid, among: hosts) { reading.running.insert(host.id) }
        }
        var depths: [String: Int] = [:]
        for file in files where file.isInteractive && table.isAlive(file.pid) {
            reading.claimed.insert(file.sessionId)
            guard let host = table.host(of: file.pid, among: hosts) else { continue }
            if let seen = depths[host.id], seen <= host.depth { continue }
            depths[host.id] = host.depth
            reading.running.insert(host.id)
            reading.sightings[host.id] = AgentSighting(
                cli: cli, sessionId: file.sessionId, cwd: file.cwd,
                args: argv(file.pid).map(AgentArgv.resumeFlags) ?? [], name: file.name)
        }
        return reading
    }

    /// The real thing: this Mac's relay sessions, Claude's session files and
    /// the process table. Off the main thread — it reads a directory of files.
    static func now() -> AgentReading {
        var hosts: [Int32: String] = [:]
        for info in RelaySessionDirectory().live() {
            if let pid = info.pid { hosts[pid] = info.id }
        }
        return read(
            files: ClaudeSessionFile.all(), hosts: hosts, table: ProcessTable.current(),
            argv: ProcessTable.arguments(of:))
    }
}

/// What the ledger should be told after a reading.
enum AgentLedgerSync {
    enum Change: Equatable {
        case record(PaneAgent)
        case forget(paneId: String)
    }

    /// For each local terminal pane (`relayId` is its session):
    ///
    /// - an agent seen in its session is recorded, when that differs from
    ///   what the ledger has — a write per change, not per poll;
    /// - a live session with no agent in it forgets the record: the agent
    ///   exited and the shell lived on, so there is nothing to resume;
    /// - a dead session changes nothing. That is the reboot, and the record
    ///   is what it is for.
    ///
    /// `holding` is panes just resumed, whose agent may not be up yet: their
    /// record is left alone until it is.
    static func changes(
        panes: [(paneId: String, relayId: String)], records: [String: PaneAgent],
        reading: AgentReading, holding: Set<String>, now: Int64
    ) -> [Change] {
        var out: [Change] = []
        for (paneId, relayId) in panes {
            let kept = records[paneId]
            if let seen = reading.sightings[relayId] {
                if let kept, kept.cli == seen.cli, kept.sessionId == seen.sessionId, kept.cwd == seen.cwd,
                   kept.args == seen.args, kept.name == seen.name { continue }
                out.append(.record(PaneAgent(
                    paneId: paneId, cli: seen.cli, sessionId: seen.sessionId, cwd: seen.cwd,
                    args: seen.args, name: seen.name, updatedAt: now)))
            } else if kept != nil, reading.hosts.contains(relayId), !reading.running.contains(relayId),
                      !holding.contains(paneId) {
                out.append(.forget(paneId: paneId))
            }
        }
        return out
    }
}

/// Which panes can be resumed, and the command that does it.
enum AgentResume {
    /// The line a resume runs, read by the user's login shell (`LocalSpawner`'s
    /// wrapper). Nil for an agent CLI this build does not know how to resume.
    ///
    /// `unset` first, and after the login files have run, because that is
    /// where `ANTHROPIC_API_KEY` comes from: a key in the environment makes
    /// `claude` bill the API instead of the Max login. The spawner already
    /// drops Claude's own child-session markers from every pane; this drops
    /// them again in case a login file set one.
    static func line(_ agent: PaneAgent) -> String? {
        guard agent.cli == AgentReading.cli else { return nil }
        return "unset ANTHROPIC_API_KEY CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION; "
            + LocalSpawner.programLine(agent.cli, args: ["--resume", agent.sessionId] + agent.args)
    }

    /// The panes a resume would act on, in strip order: local terminal panes
    /// with a record whose session is not running, and not one being resumed
    /// already. A remote pane is left out — its server's relay-tty says
    /// nothing about the processes in a session (see the README).
    static func resumable(
        panes: [Pane], records: [String: PaneAgent], live: Set<SessionKey>, holding: Set<String>
    ) -> [PaneAgent] {
        panes.compactMap { pane in
            guard pane.kind == .pty, pane.relayServer == nil, let key = pane.sessionKey,
                  !live.contains(key), !holding.contains(pane.id),
                  let agent = records[pane.id], line(agent) != nil
            else { return nil }
            return agent
        }
    }

    /// What Resume All does with the candidates: each conversation once, and
    /// none that a live process already has open. The skipped ones come back
    /// with the reason, for the CLI to print.
    static func plan(_ candidates: [PaneAgent], claimed: Set<String>)
        -> (go: [PaneAgent], skipped: [(agent: PaneAgent, why: String)])
    {
        var go: [PaneAgent] = []
        var skipped: [(agent: PaneAgent, why: String)] = []
        var taken = claimed
        for agent in candidates {
            if claimed.contains(agent.sessionId) {
                skipped.append((agent, "already open in a running claude"))
            } else if taken.contains(agent.sessionId) {
                skipped.append((agent, "the same conversation as a pane to its left"))
            } else {
                taken.insert(agent.sessionId)
                go.append(agent)
            }
        }
        return (go, skipped)
    }

    /// The name a banner or a CLI line calls it by.
    static func label(_ agent: PaneAgent) -> String {
        agent.name ?? String(agent.sessionId.prefix(8))
    }

    /// Resume All starts one agent at a time with this between them, so a
    /// dozen `claude` starts do not all hit the disk and the network at once.
    static let stagger: TimeInterval = 0.8
    /// How long a pane just resumed is left alone by the sync and the offer:
    /// long enough for a login shell and `claude` to start and write its file.
    static let hold: TimeInterval = 30
}

extension AgentReading {
    /// Every conversation a live `claude` has open right now: the files, and
    /// a signal-0 check on each pid. Cheap enough to ask just before a resume,
    /// which is when it has to be true rather than five seconds old.
    static func claimedNow(files: [ClaudeSessionFile] = ClaudeSessionFile.all()) -> Set<String> {
        Set(files.filter { $0.isInteractive && (kill($0.pid, 0) == 0 || errno == EPERM) }.map(\.sessionId))
    }
}

/// Takes a reading off the main thread whenever it is poked, one at a time,
/// and no more often than `minimumInterval`. The session poll pokes it; a
/// poke while a reading is under way is folded into one more afterwards.
@MainActor
final class AgentWatch {
    var onReading: ((AgentReading) -> Void)?
    /// What a reading is. The real one reads the disk and the process table;
    /// a test hands in its own.
    var read: @Sendable () -> AgentReading = { AgentReading.now() }
    var minimumInterval: TimeInterval = 2
    private(set) var latest: AgentReading?

    private let queue = DispatchQueue(label: "maxpane.agents", qos: .utility)
    private var busy = false
    private var again = false
    private var lastStart = Date.distantPast

    func poke() {
        guard !busy else {
            again = true
            return
        }
        busy = true
        let wait = max(0, minimumInterval - Date().timeIntervalSince(lastStart))
        let read = read
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            let reading = read()
            Task { @MainActor in
                guard let self else { return }
                self.lastStart = Date()
                self.busy = false
                self.latest = reading
                self.onReading?(reading)
                if self.again {
                    self.again = false
                    self.poke()
                }
            }
        }
    }
}
