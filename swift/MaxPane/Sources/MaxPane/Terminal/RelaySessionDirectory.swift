import Foundation

/// One RelayTTY session, as its metadata file describes it.
///
/// Field names follow `shared/types.ts`. Everything past `status` is optional
/// because pty-host writes metadata on a ≤5 s dirty flush and a freshly spawned
/// session's file is sparse until the first one lands.
struct RelaySession: Codable, Identifiable, Sendable {
    let id: String
    let command: String
    let args: [String]
    var cwd: String
    let createdAt: Double
    var status: String
    var cols: Int
    var rows: Int
    var pid: Int32?
    var title: String?
    var lastActivity: Double?
    var totalBytesWritten: Double?
    /// The `comm` name of the foreground process, absent when the session leader
    /// is in the foreground. For Claude Code this is literally the version
    /// string, so treat it as a glyph hint and nothing more.
    var foregroundProcess: String?
    /// pty-host's own heuristic: "idle", "active", "done", …
    var agentState: String?

    var isRunning: Bool { status == "running" }

    /// What to show in a picker row.
    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return ([command] + args).joined(separator: " ")
    }
}

/// Reads `~/.relay-tty/sessions/`. Observation only — MaxPane never writes here;
/// pty-host owns every one of these files.
struct RelaySessionDirectory {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".relay-tty", isDirectory: true)
    static let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
    static let socketsDir = root.appendingPathComponent("sockets", isDirectory: true)

    static func socketPath(_ id: String) -> String {
        socketsDir.appendingPathComponent("\(id).sock").path
    }

    static func sessionPath(_ id: String) -> String {
        sessionsDir.appendingPathComponent("\(id).json").path
    }

    /// Every session on disk that is actually alive.
    ///
    /// `status` is not enough on its own: pty-host writes "running" and a
    /// crashed host never gets to correct it, so the pid is checked too. This is
    /// the same liveness rule RelayTTY's own disk directory applies.
    func live() -> [RelaySession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.sessionsDir.path) else { return [] }
        let decoder = JSONDecoder()
        var out: [RelaySession] = []
        for name in names where name.hasSuffix(".json") {
            let path = Self.sessionsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path),
                  let session = try? decoder.decode(RelaySession.self, from: data),
                  session.isRunning
            else { continue }
            guard let pid = session.pid, isAlive(pid) else { continue }
            out.append(session)
        }
        return out.sorted { ($0.lastActivity ?? $0.createdAt) > ($1.lastActivity ?? $1.createdAt) }
    }

    func session(_ id: String) -> RelaySession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.sessionPath(id))) else { return nil }
        return try? JSONDecoder().decode(RelaySession.self, from: data)
    }

    /// PRD §7.1's picker: live sessions not already on the strip.
    func attachable(excluding attached: Set<String>) -> [RelaySession] {
        live().filter { !attached.contains($0.id) }
    }

    private func isAlive(_ pid: Int32) -> Bool {
        // Signal 0 tests for existence and permission without delivering anything.
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Watches the sessions directory so pty panes notice a `cd`, a title change or
/// a session dying without polling hard.
///
/// pty-host flushes session metadata on a ≤5 s dirty timer, so the `fs` events
/// arrive in bursts; a short debounce collapses each burst into one callback.
/// A timer backstops the watch because `DispatchSource` on a directory misses
/// atomic replaces on some filesystems.
final class RelaySessionWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private let onChange: ([RelaySession]) -> Void
    private let directory = RelaySessionDirectory()
    private let queue = DispatchQueue(label: "maxpane.relay.sessions")

    init(pollInterval: TimeInterval, onChange: @escaping ([RelaySession]) -> Void) {
        self.onChange = onChange
        startWatching()
        startPolling(every: pollInterval)
    }

    deinit {
        source?.cancel()
        timer?.cancel()
        if fd >= 0 { close(fd) }
    }

    private func startWatching() {
        let path = RelaySessionDirectory.sessionsDir.path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        s.setEventHandler { [weak self] in self?.scheduleEmit() }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        s.resume()
        source = s
    }

    private func startPolling(every interval: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.emit() }
        t.resume()
        timer = t
    }

    private func scheduleEmit() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.emit() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func emit() {
        let sessions = directory.live()
        DispatchQueue.main.async { [onChange] in onChange(sessions) }
    }
}
