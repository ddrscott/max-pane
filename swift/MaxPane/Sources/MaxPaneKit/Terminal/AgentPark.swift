import Foundation

// Parking an idle Claude (ADR-0048).
//
// relay-tty owns the mechanism: `POST /api/sessions/:id/park` SIGTERMs the
// session's `claude` and leaves the shell, the pty-host and the scrollback
// alive, with a `parked` record in the session file; `…/unpark` types
// `claude --resume <id> <flags>` back into that shell. This file is Max
// Pane's half: the record as the session file carries it, the client that
// asks, and the pure rules for Park Idle Lanes.

/// relay-tty's `parked` field: which conversation was put to sleep, where,
/// and with which flags it comes back.
///
/// Decoded leniently, field by field. A session file is one JSON object, and
/// a `parked` this build does not fully understand must not cost the
/// sidebar the whole session.
public struct ParkedAgent: Codable, Equatable, Sendable {
    public var agent: String
    public var sessionId: String
    public var cwd: String
    public var flags: [String]
    public var name: String?
    /// ms since the epoch.
    public var parkedAt: Double?

    public init(
        agent: String = "claude", sessionId: String, cwd: String, flags: [String] = [],
        name: String? = nil, parkedAt: Double? = nil
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.flags = flags
        self.name = name
        self.parkedAt = parkedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? c.decodeIfPresent(String.self, forKey: .agent)) ?? "claude"
        sessionId = (try? c.decodeIfPresent(String.self, forKey: .sessionId)) ?? ""
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        flags = (try? c.decodeIfPresent([String].self, forKey: .flags)) ?? []
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0.isEmpty ? nil : $0 }
        parkedAt = try? c.decodeIfPresent(Double.self, forKey: .parkedAt)
    }

    /// What the lane and the row call it: Claude's own name for the
    /// conversation, else the start of its id.
    public var label: String { name ?? (sessionId.isEmpty ? "claude" : String(sessionId.prefix(8))) }

    public var parkedDate: Date? { parkedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// `3d`, `5h`, `12m`, `now`: how long it has been asleep, for the row.
    public func age(now: Date = Date()) -> String {
        guard let since = parkedDate else { return "" }
        return Self.shortAge(max(0, now.timeIntervalSince(since)))
    }

    static func shortAge(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// What a park, an unpark or a keep came to.
enum ParkOutcome: Equatable {
    case done
    /// Parked, on a pty-host from relay 1.23 or older. That host ignores
    /// relay-tty's `SET_META`, so the session will never say `parked`; the
    /// conversation is recoverable only from relay-tty's `parked/` copy, by
    /// its conversation id. `note` is relay-tty's line for the user.
    case parkedOnOldHost(ParkedAgent, note: String)
    /// An unpark by conversation id started a new relay session to resume
    /// in, because the one it was parked from is gone or never knew.
    case spawned(session: String)
    /// relay-tty said no, and why, in its words. `forceable` when Park
    /// Anyway could get past it: a working, blocked or busy agent, or a
    /// draft — never a session with no Claude in it, or one already parked.
    case refused(String, forceable: Bool)
    /// This relay-tty has no such route: the feature is not there, and the
    /// items that ask for it go away.
    case unsupported
    /// Nobody answered, or something broke on the way.
    case failed(String)

    var isUnsupported: Bool { self == .unsupported }
    var isSpawned: Bool { if case .spawned = self { return true } else { return false } }
}

/// relay-tty's answer to a park, unpark or keep, as a value.
enum ParkReply {
    /// `status` 0 means no HTTP response at all; `transportError` says why.
    static func outcome(status: Int, data: Data?, transportError: String? = nil) -> ParkOutcome {
        if let transportError { return .failed(transportError) }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let message = ((object?["error"] as? String) ?? (object?["message"] as? String)).map(trimForceHint)
        let code = object?["reason"] as? String
        switch status {
        case 200..<300:
            if object?["legacyHost"] as? Bool == true,
               let raw = object?["parked"], let json = try? JSONSerialization.data(withJSONObject: raw),
               let parked = try? JSONDecoder().decode(ParkedAgent.self, from: json), !parked.sessionId.isEmpty {
                let note = (object?["note"] as? String)
                    ?? "This session's pty-host predates parking, so it won't show as PARKED."
                return .parkedOnOldHost(parked, note: note)
            }
            if object?["spawned"] as? Bool == true, let session = object?["session"] as? String, !session.isEmpty {
                return .spawned(session: session)
            }
            return .done
        case 404:
            // Express answers a route it does not have with an HTML
            // "Cannot POST /api/sessions/…/park"; the route answers an
            // unknown session with JSON. Only the first means "older
            // relay-tty".
            if let message { return .refused(message, forceable: false) }
            return .unsupported
        case 405, 501:
            return .unsupported
        case 400..<500:
            let reason = message ?? RemoteSpawner.errorLine(data)
            let forceable = code.map(forceableCodes.contains) ?? Self.looksForceable(reason)
            return .refused(reason.isEmpty ? "HTTP \(status)" : reason, forceable: forceable)
        default:
            // relay-tty's own refusals that happen to be 500s: `no-record`
            // (it could not write the `parked/` copy, so it signalled
            // nothing), `kill-failed`, `shell-died`. Said on the row like
            // any refusal, and never forceable.
            if code != nil, let message { return .refused(message, forceable: false) }
            let line = message ?? RemoteSpawner.errorLine(data)
            return .failed("HTTP \(status)" + (line.isEmpty ? "" : ": \(line)"))
        }
    }

    /// relay-tty's refusal codes `--force` gets past (`shared/park.ts`,
    /// `parkRefusal`). The rest — no Claude, already parked, not running —
    /// are refused either way, and Park Anyway is not offered for them.
    static let forceableCodes: Set<String> = ["agent-working", "agent-blocked", "claude-busy", "unsent-draft"]

    /// With no code to go by (the CLI's stderr), the words decide.
    static func looksForceable(_ reason: String) -> Bool {
        let r = reason.lowercased()
        if r.contains("--force") { return true }
        for word in ["no claude", "already parked", "not running", "not found"] where r.contains(word) { return false }
        return true
    }

    /// relay-tty's message tells a CLI user to pass `--force`; here the
    /// row's menu offers Park Anyway instead, so the hint goes.
    static func trimForceHint(_ message: String) -> String {
        message.replacingOccurrences(of: " (use --force to park anyway)", with: "")
    }
}

/// Park, wake and keep a session. Main-actor callbacks, once each.
@MainActor
protocol AgentParking: AnyObject {
    func park(sessionId: String, force: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void)
    func unpark(sessionId: String, completion: @escaping @MainActor (ParkOutcome) -> Void)
    func setKeep(sessionId: String, keep: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void)
    /// relay-tty's `agentQuietSince` for each local session that has it, by
    /// relay id. Empty from a relay-tty too old to send it, or none answering:
    /// Park Idle Lanes then measures from the session file, as it always has.
    func agentQuiet(completion: @escaping @MainActor ([String: AgentQuiet]) -> Void)
}

/// The relay-tty server on this Mac, over HTTP on loopback (which its auth
/// lets through without a cookie), at the address the running server writes
/// to `~/.config/relay-tty/server.json` — the address `relay` itself uses.
///
/// Max Pane never needed a local server before: sessions are files and
/// sockets. Parking is the server's because pty-host must write the record
/// and pick the Claude out of the session's process tree.
///
/// **Never the `relay` CLI as a fallback.** relay-tty before park reads an
/// unknown first word as a program to run: `relay park <id>` starts a new
/// session running `park`, exits 0, and looks exactly like success. With
/// no server answering, a park says so instead.
@MainActor
final class LocalAgentParker: AgentParking {
    /// Where the server is, read on each call: it moves when restarted.
    let baseURL: @Sendable () -> URL
    private let urlSession: URLSession

    nonisolated static var serverFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/relay-tty/server.json")
    }

    /// `server.json`'s `url`, else relay-tty's own default.
    nonisolated static func serverURL(file: URL = serverFile) -> URL {
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["url"] as? String, let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:7680")!
    }

    static let noServer = "no relay-tty server is answering on this Mac (relay server start)"

    init(baseURL: @escaping @Sendable () -> URL = { LocalAgentParker.serverURL() }) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // A park waits up to 5 s for Claude to go before SIGKILL.
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)
    }

    func park(sessionId: String, force: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/park", body: force ? ["force": true] : [:], completion: completion)
    }

    func unpark(sessionId: String, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/unpark", body: [:], completion: completion)
    }

    func setKeep(sessionId: String, keep: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/keep", body: ["keep": keep], completion: completion)
    }

    func agentQuiet(completion: @escaping @MainActor ([String: AgentQuiet]) -> Void) {
        var components = URLComponents(url: baseURL(), resolvingAgainstBaseURL: false)!
        components.path = "/api/sessions"
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 5
        urlSession.dataTask(with: request) { data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200
            let quiet = ok ? AgentQuiet.parse(sessionList: data) : [:]
            Task { @MainActor in completion(quiet) }
        }.resume()
    }

    private func post(
        _ path: String, body: [String: Any], completion: @escaping @MainActor (ParkOutcome) -> Void
    ) {
        var components = URLComponents(url: baseURL(), resolvingAgainstBaseURL: false)!
        components.path = path
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        urlSession.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = ParkReply.outcome(
                status: status, data: data, transportError: error.map { _ in Self.noServer })
            Task { @MainActor in completion(outcome) }
        }.resume()
    }
}

// MARK: - Quiet time

/// How long a session's Claude has been quiet, as relay-tty measures it
/// (`shared/park.ts` `quietFor`): from Claude's own `statusUpdatedAt` and the
/// session's last input, because Claude repaints on every resize, attach and
/// status-line refresh and pty output is never old. `GET /api/sessions` adds
/// it as `agentQuietSince`/`agentQuietSource`; the session file never has it.
struct AgentQuiet: Equatable, Sendable {
    var since: Date
    /// `claude` when measured from Claude's session file, `output` when
    /// relay-tty itself fell back to pty output.
    var source: String

    /// `{sessions: [{id, agentQuietSince, agentQuietSource}, …]}` → by id.
    /// Sessions without the field are left out, which is every session
    /// from a relay-tty older than the field.
    static func parse(sessionList data: Data?) -> [String: AgentQuiet] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { return [:] }
        var out: [String: AgentQuiet] = [:]
        for s in sessions {
            guard let id = s["id"] as? String, let ms = (s["agentQuietSince"] as? NSNumber)?.doubleValue,
                  ms > 0 else { continue }
            let source = (s["agentQuietSource"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "output"
            out[id] = AgentQuiet(since: Date(timeIntervalSince1970: ms / 1000), source: source)
        }
        return out
    }
}

// MARK: - Old pty-hosts

/// relay-tty's `~/.relay-tty/parked/<conversation>.json`: a copy of every
/// park, written before Claude is signalled and removed by unpark. For a
/// session on a pty-host from relay 1.23 or older it is the only record,
/// because that host never stores `parked` in the session file.
enum ParkLedger {
    struct Entry: Equatable {
        var parked: ParkedAgent
        var relaySessionId: String
    }

    static var directory: URL { RelaySessionDirectory.root.appendingPathComponent("parked", isDirectory: true) }

    static func entries(in dir: URL = directory) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let parked = try? JSONDecoder().decode(ParkedAgent.self, from: data), !parked.sessionId.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let relay = object["relaySessionId"] as? String, !relay.isEmpty else { return nil }
            return Entry(parked: parked, relaySessionId: relay)
        }
    }

    /// The local sessions parked on an old pty-host, by relay id: a ledger
    /// entry for a session that is running, whose file knows nothing of
    /// parking (a new host's says `parked`, and writes `lastInputAt` once
    /// anyone types), and that has no `claude` in it now. A Claude resumed
    /// by hand in that shell takes the session off the list. Not
    /// `isLegacyHost`: that needs a foreground job, and parking removed it.
    static func asleepOnOldHosts(
        _ entries: [Entry], sessions: [SessionKey: SessionTelemetry], sightings: Set<String>
    ) -> [String: ParkedAgent] {
        var out: [String: ParkedAgent] = [:]
        for e in entries.sorted(by: { ($0.parked.parkedAt ?? 0) < ($1.parked.parkedAt ?? 0) }) {
            guard let t = sessions[SessionKey(id: e.relaySessionId)], t.isRunning, t.parked == nil,
                  !t.knowsParking, !sightings.contains(e.relaySessionId) else { continue }
            out[e.relaySessionId] = e.parked
        }
        return out
    }
}

// MARK: - Park Idle Lanes

/// One local session Park Idle Lanes looked at.
struct ParkCandidate: Equatable {
    var key: SessionKey
    var name: String
    var telemetry: SessionTelemetry
    /// A `claude` is running in it right now (the agent reading).
    var hasClaude: Bool
    /// Its lane is kept loaded (⇧⌘P), which means keep here as well.
    var keptLoaded: Bool
    /// relay-tty's own quiet time for it, when the server sends one.
    var agentQuiet: AgentQuiet? = nil
}

enum ParkIdle {
    /// The default for `park_idle_after`.
    static let defaultAfter = "24h"

    /// `24h`, `90m`, `2d`, `1w`, `45s`, or a bare number of hours. Nil for
    /// anything else, and for zero or less.
    static func parse(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800]
        let value: Double?
        let scale: TimeInterval
        if let last = t.last, let unit = units[last] {
            value = Double(t.dropLast())
            scale = unit
        } else {
            value = Double(t)
            scale = 3600
        }
        guard let value, value > 0, value.isFinite else { return nil }
        return value * scale
    }

    /// `24h` → "24 hours", for the confirmation's title.
    static func describe(_ seconds: TimeInterval) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return plural(Int(seconds / 86_400), "day")
        }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            return plural(Int(seconds / 3600), "hour")
        }
        if seconds >= 60 { return plural(Int(seconds / 60), "minute") }
        return plural(Int(seconds), "second")
    }

    /// When the session was last touched either way: the later of its last
    /// output and its last input. Nil when neither is known.
    static func lastTouched(_ t: SessionTelemetry) -> Date? {
        [t.lastActivity, t.lastInputAt].compactMap { $0 }.max()
    }

    /// Input after the agent's last state change: a draft sitting at the
    /// prompt. relay-tty's own guard, to the letter (`lastInputAt >
    /// agentStateChangedAt`, a missing one as zero), so the list never
    /// promises a park relay-tty will refuse.
    static func hasDraft(_ t: SessionTelemetry) -> Bool {
        guard let input = t.lastInputAt else { return false }
        return input > (t.agentStateChangedAt ?? .distantPast)
    }

    /// When the session went quiet and how that was measured: relay-tty's
    /// `agentQuietSince` when the server sent one, else the later of the
    /// file's last output and last input (an older relay-tty, which has
    /// only that), as `output`.
    static func quietSince(_ c: ParkCandidate) -> (since: Date, source: String)? {
        if let q = c.agentQuiet { return (q.since, q.source) }
        return lastTouched(c.telemetry).map { ($0, "output") }
    }

    /// `31d (claude)`: the quiet time and where it came from, for the list.
    static func quietText(_ c: ParkCandidate, now: Date = Date()) -> String {
        guard let q = quietSince(c) else { return "?" }
        return "\(ParkedAgent.shortAge(max(0, now.timeIntervalSince(q.since)))) (\(q.source))"
    }

    /// The draft rule with relay-tty's quiet time. Its `agentQuietSince` is
    /// the later of Claude's `statusUpdatedAt` and the last input, so the
    /// last input *being* it is relay-tty's draft check (`lastInputAt >
    /// statusUpdatedAt`). Measured from output, the file's rule stands.
    static func hasDraft(_ c: ParkCandidate) -> Bool {
        guard let q = c.agentQuiet, q.source == "claude" else { return hasDraft(c.telemetry) }
        guard let input = c.telemetry.lastInputAt else { return false }
        return input >= q.since
    }

    /// Which sessions Park Idle Lanes parks, and which it passes over and
    /// why. Only local Claude sessions relay-tty can park, not already
    /// parked, and quiet for at least `quietFor` are on the list at all; a
    /// busy one is not "skipped", it is simply not idle. Of those, the kept,
    /// blocked, working and drafted are skipped with their reason. Quietest
    /// first.
    ///
    /// Quiet is relay-tty's `agentQuietSince` when the server sends it
    /// (Claude's own status and the last input; a repaint does not count),
    /// else output and input both, from the session file. A session the
    /// server measured is parkable even when its file shows nothing of
    /// parking: that is an old pty-host, which a server new enough to send
    /// the field parks anyway (ADR-0048).
    static func plan(_ candidates: [ParkCandidate], quietFor: TimeInterval, now: Date = Date())
        -> (park: [ParkCandidate], skipped: [(candidate: ParkCandidate, why: String)])
    {
        let idle = candidates.filter { c in
            let t = c.telemetry
            guard t.server == nil, t.isRunning, t.knowsParking || c.agentQuiet != nil, t.parked == nil,
                  c.hasClaude || c.agentQuiet != nil, let quiet = quietSince(c) else { return false }
            return now.timeIntervalSince(quiet.since) >= quietFor
        }.sorted {
            let a = quietSince($0)!.since, b = quietSince($1)!.since
            return a == b ? $0.key < $1.key : a < b
        }
        var park: [ParkCandidate] = []
        var skipped: [(candidate: ParkCandidate, why: String)] = []
        for c in idle {
            let t = c.telemetry
            // pty-host's WORKING is an output rate that one Claude repaint
            // raises for a minute; with Claude's own status to go by,
            // relay-tty ignores it, and so does this.
            let measured = c.agentQuiet?.source == "claude"
            if t.keep || c.keptLoaded {
                skipped.append((c, "kept loaded"))
            } else if t.state == .blocked {
                skipped.append((c, "blocked, waiting on you"))
            } else if t.state == .working, !measured {
                skipped.append((c, "working"))
            } else if hasDraft(c) {
                skipped.append((c, "an unsent draft at the prompt"))
            } else {
                park.append(c)
            }
        }
        return (park, skipped)
    }

    /// The confirmation's body: one line a session, parked or skipped.
    static func summary(
        park: [ParkCandidate], skipped: [(candidate: ParkCandidate, why: String)], now: Date = Date()
    ) -> String {
        var lines: [String] = []
        for c in park {
            lines.append("$ park  \(c.name) — quiet \(quietText(c, now: now))" + (isOldHost(c) ? " · \(oldHostNote)" : ""))
        }
        for s in skipped {
            lines.append("  skip  \(s.candidate.name) — quiet \(quietText(s.candidate, now: now)) · \(s.why)")
        }
        return lines.joined(separator: "\n")
    }

    /// relay-tty's `isLegacyHost`, from the session file: a foreground job
    /// named with no `foregroundPid` beside it, and no input ever recorded.
    static func isOldHost(_ c: ParkCandidate) -> Bool { c.telemetry.isOldPtyHost }

    static let oldHostNote = "old pty-host: never shows PARKED, $ WAKE resumes it in a new session"
}
