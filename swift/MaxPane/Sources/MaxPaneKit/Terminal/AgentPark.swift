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
}

/// The relay-tty server on this Mac, over HTTP on loopback (which its auth
/// lets through without a cookie), at the address the running server writes
/// to `~/.config/relay-tty/server.json` — the address `relay` itself uses.
///
/// Max Pane never needed a local server before: sessions are files and
/// sockets. Parking is the server's because pty-host must write the record
/// and pick the Claude out of the session's process tree. When no server
/// answers, the `relay` CLI is asked the same thing, as it is for `relay
/// keep`, which may have no route at all.
@MainActor
final class LocalAgentParker: AgentParking {
    /// Where the server is, read on each call: it moves when restarted.
    let baseURL: @Sendable () -> URL
    /// `relay` on PATH, or nil to not fall back.
    let relayCLI: @Sendable () -> String?
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

    init(
        baseURL: @escaping @Sendable () -> URL = { LocalAgentParker.serverURL() },
        relayCLI: @escaping @Sendable () -> String? = { LocalSpawner.which("relay") }
    ) {
        self.baseURL = baseURL
        self.relayCLI = relayCLI
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // A park waits up to 5 s for Claude to go before SIGKILL.
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)
    }

    func park(sessionId: String, force: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/park", body: force ? ["force": true] : [:],
             cli: ["park"] + (force ? ["--force"] : []) + [sessionId], completion: completion)
    }

    func unpark(sessionId: String, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/unpark", body: [:], cli: ["unpark", sessionId], completion: completion)
    }

    func setKeep(sessionId: String, keep: Bool, completion: @escaping @MainActor (ParkOutcome) -> Void) {
        post("/api/sessions/\(sessionId)/keep", body: ["keep": keep],
             cli: ["keep"] + (keep ? [] : ["--off"]) + [sessionId], completion: completion)
    }

    /// The route, then the CLI when the server is not there or the route
    /// is not (a `keep` route may never land; `relay keep` is the contract).
    private func post(
        _ path: String, body: [String: Any], cli: [String],
        completion: @escaping @MainActor (ParkOutcome) -> Void
    ) {
        var components = URLComponents(url: baseURL(), resolvingAgainstBaseURL: false)!
        components.path = path
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let relay = relayCLI
        urlSession.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = ParkReply.outcome(
                status: status, data: data, transportError: error.map { ($0 as NSError).localizedDescription })
            Task { @MainActor in
                switch outcome {
                case .failed where status == 0, .unsupported:
                    guard let binary = relay() else {
                        completion(outcome.isUnsupported
                            ? outcome : .failed("no relay-tty server is running on this Mac (relay server)"))
                        return
                    }
                    Self.runCLI(binary, cli, completion: completion)
                default:
                    completion(outcome)
                }
            }
        }.resume()
    }

    /// `relay <args>`, off the main thread. Exit 0 is done; an unknown
    /// command is an older relay-tty; anything else is its stderr's first
    /// line, as a refusal.
    private static func runCLI(
        _ binary: String, _ args: [String], completion: @escaping @MainActor (ParkOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let err = Pipe(), out = Pipe()
            process.standardError = err
            process.standardOutput = out
            let outcome: ParkOutcome
            do {
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    + String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                outcome = cliOutcome(exit: process.terminationStatus, output: text)
            } catch {
                outcome = .failed("relay: \(error.localizedDescription)")
            }
            Task { @MainActor in completion(outcome) }
        }
    }

    nonisolated static func cliOutcome(exit: Int32, output: String) -> ParkOutcome {
        if exit == 0 { return .done }
        let lower = output.lowercased()
        if lower.contains("unknown command") || lower.contains("unknown option") { return .unsupported }
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            .map { $0.hasPrefix("error: ") ? String($0.dropFirst(7)) : $0 } ?? "relay exited \(exit)"
        return .refused(ParkReply.trimForceHint(line), forceable: ParkReply.looksForceable(line))
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

    /// Which sessions Park Idle Lanes parks, and which it passes over and
    /// why. Only local Claude sessions on a relay-tty that knows parking,
    /// not already parked, and quiet — output and input both — for at least
    /// `quietFor` are on the list at all; a busy one is not "skipped", it is
    /// simply not idle. Of those, the kept, blocked, working and drafted are
    /// skipped with their reason. Oldest-touched first.
    static func plan(_ candidates: [ParkCandidate], quietFor: TimeInterval, now: Date = Date())
        -> (park: [ParkCandidate], skipped: [(candidate: ParkCandidate, why: String)])
    {
        let idle = candidates.filter { c in
            let t = c.telemetry
            guard t.server == nil, t.isRunning, t.knowsParking, t.parked == nil, c.hasClaude,
                  let touched = lastTouched(t) else { return false }
            return now.timeIntervalSince(touched) >= quietFor
        }.sorted {
            let a = lastTouched($0.telemetry)!, b = lastTouched($1.telemetry)!
            return a == b ? $0.key < $1.key : a < b
        }
        var park: [ParkCandidate] = []
        var skipped: [(candidate: ParkCandidate, why: String)] = []
        for c in idle {
            let t = c.telemetry
            if t.keep || c.keptLoaded {
                skipped.append((c, "kept loaded"))
            } else if t.state == .blocked {
                skipped.append((c, "blocked, waiting on you"))
            } else if t.state == .working {
                skipped.append((c, "working"))
            } else if hasDraft(t) {
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
            let quiet = lastTouched(c.telemetry).map { ParkedAgent.shortAge(now.timeIntervalSince($0)) } ?? "?"
            lines.append("$ park  \(c.name) — quiet \(quiet)")
        }
        for s in skipped {
            lines.append("  skip  \(s.candidate.name) — \(s.why)")
        }
        return lines.joined(separator: "\n")
    }
}
