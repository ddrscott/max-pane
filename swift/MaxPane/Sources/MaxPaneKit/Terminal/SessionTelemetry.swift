import Foundation
import RelayClient

/// What a session is doing right now.
///
/// pty-host computes this heuristically and writes it to the session file; the
/// RelayTTY web app is what it is largely because it shows this at a glance for
/// every session at once. A supervision surface that cannot tell you which of
/// ten agents is waiting on you is not supervising anything.
public enum AgentState: String, Sendable {
    /// Working — output is flowing.
    case active
    /// Alive but quiet. The common case, and the one that matters: an idle agent
    /// is usually an agent blocked on a prompt.
    case idle
    /// Finished its task and said so.
    case done
    /// The process is gone.
    case exited
    /// No opinion — a session that has not been observed yet.
    case unknown

    public init(relayValue: String?, status: String) {
        if status == "exited" {
            self = .exited
            return
        }
        switch relayValue {
        case "active": self = .active
        case "idle": self = .idle
        case "done": self = .done
        default: self = .unknown
        }
    }

    /// The glyph the strip and sidebar show. Matches the bar's vocabulary:
    /// a spinner-ish mark for working, a quiet asterisk for waiting.
    public var glyph: String {
        switch self {
        case .active: return "◑"
        case .idle: return "✳"
        case .done: return "✓"
        case .exited: return "×"
        case .unknown: return "·"
        }
    }

    public var label: String {
        switch self {
        case .active: return "active"
        case .idle: return "idle"
        case .done: return "done"
        case .exited: return "exited"
        case .unknown: return ""
        }
    }
}

/// Everything known about one session's liveness, in one value.
///
/// Assembled from two sources that disagree by design: the session file, which
/// pty-host flushes every ≤5 s and which covers *every* session including ones
/// no lane is attached to; and the live wire, which is instant but only exists
/// for sessions we are attached to. The wire wins where it has an opinion.
public struct SessionTelemetry: Sendable, Equatable {
    public var sessionId: String
    public var title: String
    public var cwd: String
    public var command: String
    public var state: AgentState
    /// Bytes per second over the last minute. The bar's "1.7KB/s".
    public var bytesPerSecond: Double
    /// When output was last seen. The bar's "6s ago".
    public var lastActivity: Date?
    public var isRunning: Bool
    /// True while a lane is attached to it.
    public var isAttached: Bool

    public init(
        sessionId: String, title: String = "", cwd: String = "", command: String = "",
        state: AgentState = .unknown, bytesPerSecond: Double = 0,
        lastActivity: Date? = nil, isRunning: Bool = true, isAttached: Bool = false
    ) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.command = command
        self.state = state
        self.bytesPerSecond = bytesPerSecond
        self.lastActivity = lastActivity
        self.isRunning = isRunning
        self.isAttached = isAttached
    }

    public init(_ info: RelaySessionInfo, isAttached: Bool = false) {
        self.init(
            sessionId: info.id,
            title: info.displayName,
            cwd: info.cwd,
            command: info.command,
            state: AgentState(relayValue: info.agentState, status: info.status),
            bytesPerSecond: info.bps1 ?? 0,
            lastActivity: info.lastActivity.map { Date(timeIntervalSince1970: $0 / 1000) },
            isRunning: info.isRunning,
            isAttached: isAttached)
    }

    /// Throughput the way the bar prints it: `1.7KB/s`, `842B/s`, `2.1MB/s`.
    /// Empty below a byte a second, because a number that is always "0B/s" is
    /// noise where the state badge should be.
    public var throughputText: String {
        guard bytesPerSecond >= 1 else { return "" }
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1fMB/s", bytesPerSecond / 1_048_576)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.1fKB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0fB/s", bytesPerSecond)
    }

    /// What goes in the badge slot. Throughput when it is moving, otherwise the
    /// state — exactly the bar's rule, and the reason that column is never dead
    /// space.
    public var badgeText: String {
        let flow = throughputText
        return flow.isEmpty ? state.label : flow
    }

    public var badgeIsThroughput: Bool { !throughputText.isEmpty }

    /// "6s ago", "13h ago", "3d ago". Short, because it sits in a 290pt column.
    public var ageText: String {
        guard let lastActivity else { return "" }
        return Self.age(since: lastActivity)
    }

    public static func age(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// The group a session belongs to in the sidebar: its directory, with `$HOME`
    /// abbreviated to `~` the way the bar does.
    public var groupPath: String { Self.abbreviate(cwd) }

    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path.isEmpty ? "~" : path
    }
}

/// Every session Relay knows about, live, whether or not a lane is attached.
///
/// One of these for the whole app. The sidebar, the attach picker and the status
/// bar all read it, so they cannot disagree about how many sessions there are.
@MainActor
public final class SessionRegistry {
    public private(set) var sessions: [String: SessionTelemetry] = [:]

    private var watcher: RelaySessionWatcher?
    private var observers: [UUID: ([String: SessionTelemetry]) -> Void] = [:]
    /// Session ids a lane is currently attached to.
    private var attached: Set<String> = []
    /// A ticker, so "6s ago" becomes "7s ago" without anything else changing.
    private var tick: Timer?

    public init(pollInterval: TimeInterval = 5) {
        watcher = RelaySessionWatcher(pollInterval: pollInterval) { [weak self] infos in
            MainActor.assumeIsolated { self?.adopt(infos) }
        }
        // One second, because the bar's smallest unit is a second and a stale
        // age is worse than no age.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.notify() }
        }
        adopt(RelaySessionDirectory().live())
    }

    deinit { watcher = nil }

    @discardableResult
    public func observe(_ body: @escaping ([String: SessionTelemetry]) -> Void) -> UUID {
        let token = UUID()
        observers[token] = body
        body(sessions)
        return token
    }

    public func stopObserving(_ token: UUID) { observers.removeValue(forKey: token) }

    public func telemetry(for sessionId: String) -> SessionTelemetry? { sessions[sessionId] }

    /// Sessions grouped by directory, groups sorted by path and sessions within
    /// a group newest-active first — the bar's ordering.
    public func grouped(attachedOnly: Bool = false) -> [(path: String, sessions: [SessionTelemetry])] {
        let wanted = sessions.values.filter { !attachedOnly || $0.isAttached }
        let byPath = Dictionary(grouping: wanted, by: \.groupPath)
        return byPath.keys.sorted().map { path in
            let inGroup = byPath[path]!.sorted {
                ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            return (path: path, sessions: inGroup)
        }
    }

    public var runningCount: Int { sessions.values.filter(\.isRunning).count }

    /// Tell the registry which sessions have lanes, so the picker can hide the
    /// ones already on the strip and the sidebar can mark them.
    public func setAttached(_ ids: Set<String>) {
        guard ids != attached else { return }
        attached = ids
        for id in sessions.keys {
            sessions[id]?.isAttached = ids.contains(id)
        }
        notify()
    }

    /// Live values straight off the wire, which beat the ≤5 s file for a session
    /// we are attached to.
    public func observeLive(sessionId: String, bytesPerSecond: Double? = nil, active: Bool? = nil) {
        guard var t = sessions[sessionId] else { return }
        var changed = false
        if let bytesPerSecond, t.bytesPerSecond != bytesPerSecond {
            t.bytesPerSecond = bytesPerSecond
            t.lastActivity = bytesPerSecond > 0 ? Date() : t.lastActivity
            changed = true
        }
        if let active {
            let next: AgentState = active ? .active : (t.state == .active ? .idle : t.state)
            if t.state != next {
                t.state = next
                changed = true
            }
        }
        guard changed else { return }
        sessions[sessionId] = t
        notify()
    }

    private func adopt(_ infos: [RelaySessionInfo]) {
        var next: [String: SessionTelemetry] = [:]
        for info in infos {
            var t = SessionTelemetry(info, isAttached: attached.contains(info.id))
            // A live wire reading is fresher than the file it just replaced.
            if let existing = sessions[info.id], existing.bytesPerSecond > t.bytesPerSecond {
                t.bytesPerSecond = existing.bytesPerSecond
                t.state = existing.state
            }
            next[info.id] = t
        }
        guard next != sessions else { return }
        sessions = next
        notify()
    }

    private func notify() {
        for body in observers.values { body(sessions) }
    }
}
