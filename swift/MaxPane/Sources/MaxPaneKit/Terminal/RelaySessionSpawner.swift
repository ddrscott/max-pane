import Foundation

/// Starts a new RelayTTY session by spawning `relay-pty-host` directly.
///
/// This is what RelayTTY's own CLI and server both do, and it needs no running
/// Node server: `~/.config/relay-tty/server.json` is only removed on a *clean*
/// shutdown, so its presence proves nothing. The server picks up CLI-spawned
/// sessions through its own file watcher, so a session started here shows up in
/// the phone client like any other.
///
/// Nothing about the wire protocol is touched. This is the documented argv.
public struct RelaySessionSpawner {
    enum SpawnError: LocalizedError {
        case binaryNotFound
        case exitedBeforeReady(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find relay-pty-host. Set relayPtyHostPath in ~/.config/maxpane/config.json."
            case .exitedBeforeReady(let id):
                return "Session \(id) exited before its socket was ready."
            case .timedOut(let id):
                return "Session \(id) did not become ready within 3 seconds."
            }
        }
    }

    let config: Config

    init(config: Config) { self.config = config }

    /// Start a session in `cwd` and return its id once the socket accepts a
    /// connection.
    ///
    /// `command` defaults to the user's shell, which is the case that makes cwd
    /// tracking work: pty-host polls the session leader, so a shell leader means
    /// the tag follows `cd`. A non-shell command is wrapped in `$SHELL -li -c
    /// "exec …"`, which makes the command itself the leader and freezes its cwd
    /// at the launch directory — correct for an agent, but worth knowing.
    @discardableResult
    func spawn(cwd: String, command: String? = nil, args: [String] = [],
               cols: Int = 80, rows: Int = 40) throws -> String {
        guard let binary = Self.locatePtyHost(override: config.relayPtyHostPath) else {
            throw SpawnError.binaryNotFound
        }
        let id = Self.newSessionID()
        let cmd = command ?? Self.userShell()
        let argv = Self.buildArgs(id: id, cols: cols, rows: rows, cwd: cwd, command: cmd, args: args)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["RELAY_SESSION_ID"] = id
        env["RELAY_ORIG_COMMAND"] = cmd
        env["RELAY_ORIG_ARGS"] = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        // PRD §7.1: anything in this session that opens a URL the polite way
        // gets a web lane next to it instead of a Safari window. The shim
        // reads RELAY_SESSION_ID, which pty-host sets in the child anyway, so
        // it knows which terminal asked.
        if let shim = Self.shimPath() {
            env["BROWSER"] = shim
            env["MAXPANE_SOCKET"] = OpenServer.socketPath
        }
        process.environment = env
        // Detached with stdio ignored: the session must outlive MaxPane, which
        // is the entire reason terminal content survives a crash.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        try Self.waitForSocket(id: id, pid: process.processIdentifier)
        return id
    }

    // MARK: - argv

    /// `relay-pty-host <id> <cols> <rows> <cwd> <command> [args...]`.
    ///
    /// `--login` is consumed by pty-host rather than passed to the child: it
    /// sets `argv[0]` to `-<basename>` so the shell reads its login files.
    static func buildArgs(id: String, cols: Int, rows: Int, cwd: String,
                          command: String, args: [String]) -> [String] {
        let head = [id, String(cols), String(rows), cwd]
        if isShellCommand(command) {
            return head + [command, "--login"] + args
        }
        let inner = args.isEmpty
            ? "exec \(shellEscape(command))"
            : "exec \(shellEscape(command)) " + args.map(shellEscape).joined(separator: " ")
        return head + [userShell(), "-li", "-c", inner]
    }

    static func isShellCommand(_ command: String) -> Bool {
        let known: Set<String> = ["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh", "dash"]
        return known.contains((command as NSString).lastPathComponent)
    }

    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func userShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/sh"
    }

    /// 8 lowercase hex characters. Anything else is rejected by the relay
    /// server's WS and API routes.
    static func newSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - discovery

    /// Find a `relay-pty-host` that can classify agent state.
    ///
    /// There is usually more than one on a machine and **they are not
    /// equivalent.** A RelayTTY checkout ships a prebuilt `bin/relay-pty-host`
    /// and also builds one into `crates/pty-host/target/release/`; only the
    /// newer of the two runs the agent-state classifier that decides whether a
    /// session is `blocked`.
    ///
    /// Picking the wrong one fails in the worst possible way: sessions start
    /// fine, output flows fine, and `agentState` is simply never written — so
    /// the sidebar, the picker and the status bar all go quiet about the one
    /// thing they exist to tell you, with nothing anywhere reporting an error.
    /// That is exactly what happened: three separate builders reported "I never
    /// saw a BLOCKED chip" before anyone thought to compare the binaries.
    ///
    /// So: gather every candidate and take the one that actually has the
    /// classifier, newest first. An explicit `relayPtyHostPath` still wins, for
    /// the case where the user knows better than this heuristic.
    static func locatePtyHost(override: String?) -> String? {
        let fm = FileManager.default
        if let override, fm.isExecutableFile(atPath: override) { return override }

        let candidates = candidatePtyHosts()
        guard !candidates.isEmpty else { return nil }

        // Prefer one that can classify; among those, the newest.
        let classifying = candidates.filter { hasAgentClassifier(at: $0) }
        let pool = classifying.isEmpty ? candidates : classifying
        if classifying.isEmpty, let first = candidates.first {
            Log.warn("""
                no relay-pty-host on this machine has the agent-state classifier                 (using \(first)) — sessions will start, but nothing will ever                 report BLOCKED. Build one:                 cargo build --release --manifest-path <relay-tty>/crates/pty-host/Cargo.toml
                """)
        }
        return pool.max(by: { modified($0) < modified($1) })
    }

    /// Every `relay-pty-host` worth considering, in no particular order.
    static func candidatePtyHosts() -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        func consider(_ path: String) {
            guard fm.isExecutableFile(atPath: path), !found.contains(path) else { return }
            found.append(path)
        }

        // Walk up from wherever `relay` resolves — an npm global install, or a
        // source checkout whose CLI is `dist/cli/index.js`.
        if let relay = which("relay") {
            var dir = URL(fileURLWithPath: relay).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<5 {
                consider(dir.appendingPathComponent("crates/pty-host/target/release/relay-pty-host").path)
                consider(dir.appendingPathComponent("bin/relay-pty-host").path)
                dir = dir.deletingLastPathComponent()
            }
        }
        consider("/usr/local/bin/relay-pty-host")
        if let onPath = which("relay-pty-host") { consider(onPath) }
        return found
    }

    /// Whether a binary contains the agent-state classifier.
    ///
    /// Sniffed by looking for one of the prompt patterns the classifier matches
    /// on, which is crude but decisive and costs one read of a 700 KB file at
    /// launch. There is no version flag that would answer this.
    static func hasAgentClassifier(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data("Do you want to proceed".utf8)) != nil
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }

    private static func which(_ name: String) -> String? {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - readiness

    /// Poll until the socket accepts a connection.
    ///
    /// The file existing is *not* sufficient — pty-host creates it before it
    /// listens, so a successful `connect()` is the only real test.
    static func waitForSocket(id: String, pid: pid_t, timeout: TimeInterval = 3.0) throws {
        let path = RelaySessionDirectory.socketPath(id)
        let deadline = Date().addingTimeInterval(timeout)
        var delay: TimeInterval = 0.05

        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH {
                throw SpawnError.exitedBeforeReady(id)
            }
            if FileManager.default.fileExists(atPath: path), canConnect(path) {
                return
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 0.5)
        }
        throw SpawnError.timedOut(id)
    }

    private static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return ok == 0
    }
}

extension RelaySessionSpawner {
    /// `maxpane-open`, which ships in the bundle's `Helpers` directory.
    ///
    /// Not `Contents/MacOS`: macOS filesystems are case-insensitive by default,
    /// and a helper called `maxpane` there would overwrite the app's own
    /// `MaxPane` executable.
    static func shimPath() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/maxpane-open").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        // Running straight out of `swift build`, the shim sits beside the binary.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("maxpane-open").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }
}
