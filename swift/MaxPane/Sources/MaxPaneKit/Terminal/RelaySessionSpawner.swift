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
        case notAProgram(String)
        case exitedBeforeReady(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                // Name the file that is actually read. This said
                // `~/.config/maxpane/config.json` long after the profiles work
                // moved it, so following the advice did nothing at all.
                return """
                    Could not find relay-pty-host. \
                    Set relay_pty_host_path in \(Config.path.path), or in Settings (⌘,).
                    """
            case .notAProgram(let command):
                return """
                    \(command.trimmingCharacters(in: .whitespacesAndNewlines)): not a program. \
                    A command and its arguments are separate words here, not a shell line — \
                    for a pipeline, ask for a shell: maxpane run zsh -c '<your command>'
                    """
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
        // Before anything is started, because after it is started nobody can
        // tell. See `isShellLine`.
        if let command, Self.isShellLine(command) {
            throw SpawnError.notAProgram(command)
        }
        let id = Self.newSessionID()
        let cmd = command ?? Self.userShell()
        return try start(
            id: id,
            argv: Self.buildArgs(id: id, cols: cols, rows: rows, cwd: cwd, command: cmd, args: args),
            command: cmd, args: args)
    }

    /// Start a session running `line` — a whole command line, read by the
    /// user's login shell, the way a shell prompt would read it.
    ///
    /// This is ⌘O's door and only ⌘O's door; `maxpane run` takes argv and
    /// refuses a shell line. See `TypedCommand`.
    @discardableResult
    func spawn(cwd: String, shellLine line: String, cols: Int = 80, rows: Int = 40) throws -> String {
        let id = Self.newSessionID()
        let argv = Self.buildShellArgs(id: id, cols: cols, rows: rows, cwd: cwd, line: line)
        return try start(
            id: id, argv: argv,
            command: Self.userShell(), args: Array(argv.dropFirst(5)))
    }

    /// Start a session from `typed`, whichever of the two things it is.
    @discardableResult
    func spawn(cwd: String, typed: TypedCommand, cols: Int = 80, rows: Int = 40) throws -> String {
        switch typed {
        case .program(let program, let args):
            return try spawn(cwd: cwd, command: program, args: args, cols: cols, rows: rows)
        case .shellLine(let line):
            return try spawn(cwd: cwd, shellLine: line, cols: cols, rows: rows)
        }
    }

    private func start(id: String, argv: [String], command cmd: String, args: [String])
        throws -> String
    {
        guard let binary = Self.locatePtyHost(override: config.relayPtyHostPath) else {
            throw SpawnError.binaryNotFound
        }
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
            // Both, and not just the profile: the socket is the exact path this
            // instance is listening on, which is right even when it came from
            // `MAXPANE_SOCKET` and no profile would derive it. `MAXPANE_PROFILE`
            // is for the person in the pane — `maxpane ls` typed there answers
            // for this instance, and says which one it is.
            env["MAXPANE_SOCKET"] = OpenServer.socketPath
            env["MAXPANE_PROFILE"] = Profile.current.name
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
        // Deliberately NOT `exec`, which is what RelayTTY's own CLI does.
        //
        // `exec` replaces the shell, making the agent the session leader. The
        // classifier's first rule is:
        //
        //     let Some(process) = obs.foreground_process else { return Idle };
        //
        // and `foreground_process` is None precisely when the foreground pgrp
        // *is* the leader. So an exec'd agent can never be anything but `idle` —
        // never `blocked`, never `working` — and BLOCKED is the whole reason
        // this app has a sidebar. Scott's two `relay claude` sessions have read
        // `idle` for days for exactly this reason.
        //
        // Leaving the shell in place costs one extra process and buys the
        // signal. It also means the lane survives the agent exiting, which is
        // what you want from a supervision surface.
        let inner = args.isEmpty
            ? shellEscape(command)
            : shellEscape(command) + " " + args.map(shellEscape).joined(separator: " ")
        return head + [userShell(), "-li", "-c", shellWrapped(inner)]
    }

    /// `relay-pty-host <id> <cols> <rows> <cwd> $SHELL -li -c <line>`.
    ///
    /// The line is **one argv element** and reaches `-c` exactly as it was
    /// typed: never concatenated into a larger program, never escaped and
    /// unescaped again, never re-split. The only thing added is the terminator
    /// `shellWrapped` puts on a new line after it. Whatever the owner typed is
    /// what his shell reads, and nothing else is.
    static func buildShellArgs(id: String, cols: Int, rows: Int, cwd: String, line: String)
        -> [String]
    {
        [id, String(cols), String(rows), cwd,
         userShell(), "-li", "-c", shellWrapped(line, separator: "\n")]
    }

    /// The `-c` program for anything run inside the wrapper shell.
    ///
    /// The trailing `exit` is not decoration. Dropping `exec` is not enough on
    /// its own: both zsh and bash optimise `-c '<one simple command>'` into an
    /// exec anyway, which puts us straight back to the agent being the session
    /// leader. A second command defeats that optimisation, the shell forks, and
    /// the agent finally has a foreground pgrp of its own — which is the entire
    /// precondition for ever being classified `blocked`. `exit $?` keeps
    /// RelayTTY's behaviour of ending the session when the command ends.
    ///
    /// `separator` is `;` for argv we escaped ourselves and a **newline** for a
    /// line a human typed, because `;` is not always a legal thing to put after
    /// one. Measured on this machine: `sleep 5 &; echo after` is a syntax error
    /// in bash and sh (zsh tolerates it), and `echo hi # note; echo after`
    /// swallows the second command into the comment in all three. A newline
    /// terminates every one of those the way a Return at a prompt does.
    static func shellWrapped(_ inner: String, separator: String = "; ") -> String {
        inner + separator + "exit $?"
    }

    /// Whether `command` is a shell line someone expected to be interpreted,
    /// rather than the name of a program.
    ///
    /// `maxpane run "yes | head"` arrives as a single argv word, so the wrapper
    /// asks zsh to run a program called `yes | head`, which exits 127. Nothing
    /// downstream notices: pty-host is listening ~20 ms in and `waitForSocket`
    /// returns there, but the shell does not report "command not found" until it
    /// has finished sourcing its login files — measured at 355 ms to 1.1 s here,
    /// against 270-370 ms of zsh startup. So the session is reported ready, an
    /// id goes back to the CLI, a lane is written, and the whole thing is gone a
    /// beat later.
    ///
    /// A settle after the socket comes up was the obvious fix and is the wrong
    /// one: it would have to outlast the user's `.zshrc` — and the *positive*
    /// signal is worse still, `foregroundProcess` not landing for a full second.
    /// Any fixed window makes this correct or silent depending on how fat
    /// someone's dotfiles are, and costs every good `maxpane run htop` the same
    /// wait. Refusing up front is instant and certain.
    ///
    /// Only the command word is judged, and only when it could not be a program
    /// name: arguments are escaped and passed through correctly, so `rg 'a|b'`
    /// is argv working as intended and must keep working. An executable that
    /// really does live at a path with a space in it is let through for the same
    /// reason — it is a program, whatever its name looks like. Shell functions
    /// and builtins contain none of these characters, so they are never reached
    /// by this at all; aliases already do not survive `shellEscape`.
    static func isShellLine(_ command: String) -> Bool {
        let syntax = CharacterSet(charactersIn: "|&;<>()$`\n\t")
            .union(.whitespaces)
        guard command.rangeOfCharacter(from: syntax) != nil else { return false }
        return !FileManager.default.isExecutableFile(atPath: command)
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

    static func which(_ name: String) -> String? {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        if let hit = search(name, in: inherited) { return hit }

        // A GUI app launched from the Dock, Finder or `open` inherits launchd's
        // PATH — `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. nvm, cargo,
        // Homebrew and every npm global are invisible from there, so `relay`
        // was not found on a machine that plainly has it and ⇧⌘D answered
        // "Could not find relay-pty-host" with the binary sitting in
        // ~/code/relay-tty/bin. Launching from a terminal hid this for months,
        // because a shell hands down the real PATH.
        //
        // So on a miss, ask the login shell what PATH is. Only on a miss: the
        // answer costs a shell startup, and the common case already found it.
        guard let login = loginShellPath else { return nil }
        return search(name, in: login)
    }

    private static func search(_ name: String, in path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `PATH` as the user's login shell builds it, or nil if it cannot be had.
    ///
    /// Computed once per process, lazily, so an app that never spawns never
    /// pays for it.
    static let loginShellPath: String? = readLoginShellPath()

    /// The marker exists because an interactive shell prints whatever the
    /// user's rc file prints — version notices, nvm chatter, a fortune. Taking
    /// "the output" would take that too, and taking the last line would break
    /// on the one rc file that ends with an echo. A sentinel is the only read
    /// that is right regardless of what else is on stdout.
    static let pathMarker = "__MAXPANE_PATH__"

    /// The shell is a parameter so this can be proved against `/bin/sh` rather
    /// than against whatever the person running the tests has in `$SHELL`.
    static func readLoginShellPath(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = 5
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` so the profile runs, and `-i` because PATH is very often set in
        // .zshrc/.bashrc, which a non-interactive shell never reads. Both, or
        // this finds a PATH that is still missing whatever the user added.
        process.arguments = ["-lic", "printf '%s%s\\n' \"\(pathMarker)\" \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Read on this thread and arm a watchdog: an rc file that waits for
        // input would otherwise hang the app at the moment someone pressed
        // ⇧⌘D, which is worse than the error this is here to prevent.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return parseMarkedPath(String(decoding: data, as: UTF8.self))
    }

    /// Pull the marked PATH out of whatever the shell printed.
    ///
    /// The marker is found *anywhere*, not at the start of a line. iTerm2's
    /// shell integration writes OSC sequences to stdout and does not end them
    /// with a newline, so a real answer looks like
    ///
    ///     \u{1b}]1337;ShellIntegrationVersion=5;shell=zsh__MAXPANE_PATH__/Users/…
    ///
    /// and a parser anchored to the line start reads that as no answer at all.
    /// Which is what happened: the fallback was correct and returned nil.
    static func parseMarkedPath(_ output: String) -> String? {
        guard let mark = output.range(of: pathMarker) else { return nil }
        // To the end of that line, then stop at any control byte — a terminal
        // integration may close its sequence after the value as happily as
        // before it, and no PATH entry contains an escape or a bell.
        let value = output[mark.upperBound...]
            .prefix { $0 != "\n" }
            .prefix { !$0.unicodeScalars.contains { scalar in scalar.value < 0x20 } }
        return value.isEmpty ? nil : String(value)
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

extension RelaySessionSpawner {
    /// What one line of typed text asks for.
    ///
    /// # Why ⌘O reads a shell line and `maxpane run` refuses one
    ///
    /// The two doors are handed different things, and that is the whole of the
    /// difference. `maxpane run npm run build` arrives as **argv** — a list of
    /// words some other shell has already separated, quoted and expanded — so
    /// interpreting them a second time would be the classic double-evaluation
    /// bug: a script's `maxpane run "$editor" "$file"` must open a file called
    /// `; rm -rf ~`, not run one. That door therefore passes argv through
    /// literally and refuses a command *word* that could only be a shell line,
    /// which is `isShellLine` and the reason it exists.
    ///
    /// ⌘O is handed **one string that nothing has interpreted yet**, typed by
    /// the owner at his own keyboard. Something has to read it, and the only
    /// correct reader of a command line is a shell. What it used to do instead
    /// was a third thing, worse than either: `line.split(separator: " ")`, a
    /// shell imitation that got pipelines, quoting and globbing all wrong and
    /// was silent about it. `yes | head` became `yes` with the literal arguments
    /// `|` and `head`, which is not an error — it is a lane spewing `y` forever.
    ///
    /// # Why not hand *every* typed line to the shell
    ///
    /// Because a bare `zsh` should still be a login shell that pty-host can poll
    /// for `cd` (see `spawn` and `buildArgs`), and wrapping it would make it a
    /// non-leader and freeze the lane's directory tag. A line with no shell
    /// syntax in it means exactly the same thing either way, so the cheaper and
    /// better-behaved reading wins.
    enum TypedCommand: Equatable {
        /// A program and its arguments, passed as argv and escaped — the same
        /// thing `maxpane run <program> <args…>` does with the same words.
        case program(String, args: [String])
        /// A line only a shell can read, handed to the user's login shell whole.
        case shellLine(String)

        /// Which of the two `text` is, or nil when there is nothing in it.
        ///
        /// The test is the presence of any character whose job is to change the
        /// meaning of the words around it. Splitting on whitespace is correct
        /// only when none of them is there, and wrong the instant one is.
        static func parse(_ text: String) -> TypedCommand? {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            if line.rangeOfCharacter(from: shellSyntax) != nil { return .shellLine(line) }
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let program = words.first else { return nil }
            return .program(program, args: Array(words.dropFirst()))
        }

        /// Characters that make a line a shell's business: pipelines and lists
        /// (`| & ;`), redirection (`< >`), subshells and grouping (`( ) { }`),
        /// expansion (`$` and a backquote), quoting (`' " \`), globbing
        /// (`* ? [ ]`), `~` for home, and `=` for an environment prefix.
        ///
        /// `#` is deliberately absent. It is a comment to a shell, but a line
        /// containing one — `open example.com/#top` — already works as argv, and
        /// routing it through a shell would truncate it. The rule only moves a
        /// line to the shell when the shell reading is the *better* one.
        private static let shellSyntax = CharacterSet(charactersIn: "|&;<>()${}`'\"\\*?[]~=\n\t")
    }
}
