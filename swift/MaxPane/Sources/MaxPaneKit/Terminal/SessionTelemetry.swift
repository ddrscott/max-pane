import Foundation
import RelayClient

/// What a session is doing right now.
///
/// pty-host computes this heuristically and writes it to the session file; the
/// RelayTTY web app is what it is largely because it shows this at a glance for
/// every session at once. A supervision surface that cannot tell you which of
/// ten agents is waiting on you is not supervising anything.
public enum AgentState: String, Sendable {
    /// **The one that matters.** The agent has drawn a prompt and is waiting on
    /// a human — "Do you want to proceed", "(y/n)", "❯ 1. Yes". With ten agents
    /// running, this is the entire reason to glance at the screen, and finding
    /// it by eye means reading ten terminals.
    case blocked
    /// Output is flowing, or the tail says "esc to interrupt"/"Thinking", or a
    /// braille spinner is turning.
    case working
    /// Finished while nobody was attached.
    ///
    /// pty-host makes this a *notification* state rather than a display state:
    /// `(Working, 0 clients) → Done`, and `(Done, >0 clients) → Idle`. It exists
    /// only while unwatched and clears itself the moment someone looks. Which is
    /// also why RelayTTY's own monitors attach in OBSERVE mode — a counted
    /// client would suppress `Done` for every session forever.
    case done
    /// Alive and quiet.
    case idle
    /// A foreground process pty-host does not recognise as an agent. It
    /// deliberately does not guess.
    case unknown
    /// The process is gone. Not one of pty-host's states — ours, from `status`.
    case exited

    /// The wire values are lowercase, from `crates/pty-host/src/agent_state.rs`
    /// (`#[serde(rename_all = "lowercase")]`).
    public init(relayValue: String?, status: String) {
        if status == "exited" {
            self = .exited
            return
        }
        self = relayValue.flatMap(AgentState.init(rawValue:)) ?? .unknown
    }

    /// Sort order: blocked first, always. This is the whole point — it is what
    /// floats the agent that needs you to the top of a list of ten.
    public var rank: Int {
        switch self {
        case .blocked: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        case .unknown: return 4
        case .exited: return 5
        }
    }

    /// The chip's text, or empty where there should be no chip.
    ///
    /// RelayTTY renders nothing at all for idle and unknown, and it is right to:
    /// a chip on every row is a chip that means nothing. Only the three states
    /// worth interrupting someone for get one.
    public var chipText: String {
        switch self {
        case .blocked: return "BLOCKED"
        case .working: return "WORKING"
        case .done: return "DONE"
        case .exited: return "EXITED"
        case .idle, .unknown: return ""
        }
    }

    public var hasChip: Bool { !chipText.isEmpty }

    /// Claude Code's title spinner while it works. Measured on the owner's live
    /// sessions, it matched real activity for every Claude session, where
    /// relay's own verdict was wrong in both directions.
    static let workingTitleGlyphs: Set<Character> = ["◐", "◓", "◑", "◒"]
    /// Claude Code's title mark while it waits for input.
    static let idleTitleGlyph: Character = "✳"

    /// The state every surface shows: relay's verdict, corrected by the title.
    ///
    /// Relay's WORKING is `bps1 ≥ 1` over a sixty-second window, so a redraw
    /// burst — every session repainting when a relaunch reattaches it — reads
    /// as a minute of work, and a session visibly working has been filed as
    /// `idle`. Claude Code's own title says which it is. In order:
    ///
    /// 1. **BLOCKED wins.** A permission prompt is the one thing that must never
    ///    be hidden, whatever the title claims.
    /// 2. **EXITED wins.** The process is gone; its last title is a fossil.
    /// 3. **A spinner title is WORKING**, even when relay says idle or done.
    /// 4. **A `✳` title is not working.** Relay's DONE survives it, because
    ///    "finished while nobody watched" does not contradict "not working" and
    ///    is worth its chip; anything else becomes IDLE.
    /// 5. **No recognised glyph keeps relay's state** — every other program.
    public static func derived(title: String, relay: AgentState) -> AgentState {
        if relay == .blocked || relay == .exited { return relay }
        guard let first = title.drop(while: { $0 == " " }).first else { return relay }
        if workingTitleGlyphs.contains(first) { return .working }
        if first == idleTitleGlyph { return relay == .done ? .done : .idle }
        return relay
    }

    /// A glyph for places too narrow for a chip.
    public var glyph: String {
        switch self {
        case .blocked: return "!"
        case .working: return "◑"
        case .done: return "✓"
        case .idle: return "✳"
        case .unknown: return "·"
        case .exited: return "×"
        }
    }
}

/// Everything known about one session's liveness, in one value.
///
/// Read from the session file, which pty-host flushes every ≤5 s and which
/// covers *every* session including ones no lane is attached to. Each file
/// replaces the last reading outright; nothing is carried forward.
public struct SessionTelemetry: Sendable, Equatable {
    public var sessionId: String
    public var title: String
    public var cwd: String
    public var command: String
    /// pty-host's verdict, as the file has it. Shown nowhere directly.
    public var relayState: AgentState
    /// What the session is doing, and the only state any surface reads:
    /// sidebar rows and chips, lane headers, gallery tiles, ⌘P, the status bar.
    /// See `AgentState.derived`.
    public var state: AgentState { AgentState.derived(title: title, relay: relayState) }
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
        self.relayState = state
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

    /// The throughput slot: a green rate while the agent is working, the word
    /// "idle" otherwise.
    ///
    /// Green means the agent is actually working, and nothing else. `bps1` is
    /// a sixty-second average, so a bare `≥ 1 B/s` rule lit every idle Claude
    /// session for a minute after each redraw and printed trickle numbers
    /// forever; a rate is only shown while the derived state is WORKING. A
    /// session can read `idle` here and `BLOCKED` on its chip at the same time
    /// — the combination worth walking across the room for.
    public var badgeText: String { badgeIsThroughput ? throughputText : "idle" }

    public var badgeIsThroughput: Bool { state == .working && !throughputText.isEmpty }

    /// True when this session is waiting on a human.
    public var needsAttention: Bool { state == .blocked }

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

    /// A registry over the files it is handed and nothing else: no watcher, no
    /// ticker, no read of the real sessions directory. For tests.
    init(files: [RelaySessionInfo]) {
        adopt(files)
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
            // Blocked first, then working, then by recency. An agent waiting on
            // a prompt has to be at the top or the list is just a list.
            let inGroup = byPath[path]!.sorted {
                if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            return (path: path, sessions: inGroup)
        }
    }

    public var runningCount: Int { sessions.values.filter(\.isRunning).count }

    /// Sessions waiting on a human right now.
    public var blockedCount: Int { sessions.values.filter { $0.isRunning && $0.needsAttention }.count }

    /// Every session, blocked first. For anything that shows one flat list.
    public var byUrgency: [SessionTelemetry] {
        sessions.values.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

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

    /// Every file replaces the reading before it, rate and state both.
    ///
    /// This used to keep the existing rate — and its state — whenever it was
    /// larger, "because a live wire reading is fresher than the file". Nothing
    /// fed live readings (`observeLive` had no caller), so an agent's peak
    /// rate and the WORKING that came with it were carried forward every five
    /// seconds forever. The merge and `observeLive` are gone rather than wired
    /// up: the wire's SESSION_METRICS frame carries the same sixty-second
    /// `bps1` the file does, so it would only have been ≤5 s sooner, at the
    /// cost of a freshness clock to stop it doing this again.
    func adopt(_ infos: [RelaySessionInfo]) {
        var next: [String: SessionTelemetry] = [:]
        for info in infos {
            next[info.id] = SessionTelemetry(info, isAttached: attached.contains(info.id))
        }
        guard next != sessions else { return }
        sessions = next
        notify()
    }

    private func notify() {
        for body in observers.values { body(sessions) }
    }
}
