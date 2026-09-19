import Testing
import Foundation
@testable import MaxPaneKit

/// The `BROWSER` shim's request format (PRD §7.1).
///
/// The shim is a separate process the app cannot see into, so the only thing
/// keeping them agreeing is this parser and the format string in
/// `crates/maxpane-open`. These tests are that agreement.
@Suite("maxpane CLI protocol")
struct OpenServerParsingTests {
    /// Pull the fields out of an `.open`, or fail the test.
    private func openFields(_ line: String) -> (url: String, session: String, cwd: String)? {
        guard case .open(let url, let session, let cwd)? = OpenServer.parse(line) else { return nil }
        return (url, session, cwd)
    }

    @Test("accepts a well-formed open from a relay session")
    func acceptsWellFormedRequest() {
        let line = #"{"op":"open","url":"https://example.com/a?b=c","session":"a7ab2d3b","cwd":"/Users/s/code"}"#
        let f = openFields(line)
        #expect(f?.url == "https://example.com/a?b=c")
        #expect(f?.session == "a7ab2d3b")
        #expect(f?.cwd == "/Users/s/code")
    }

    @Test("accepts an open with no session, which lands at the end of the strip")
    func acceptsRequestWithoutSession() {
        let f = openFields(#"{"op":"open","url":"https://example.com","session":"","cwd":"/tmp"}"#)
        #expect(f?.session == "")
        #expect(f?.url == "https://example.com")
    }

    @Test("refuses schemes a web pane has no business opening", arguments: [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,<script>x</script>",
        "ftp://example.com",
    ])
    func refusesDangerousSchemes(_ url: String) {
        let line = #"{"op":"open","url":"\#(url)","session":"","cwd":"/tmp"}"#
        #expect(OpenServer.parse(line) == nil, "accepted \(url)")
    }

    @Test("parses a run, with and without arguments")
    func parsesRun() {
        guard case .run(let command, let args, _, let cwd)?
            = OpenServer.parse(#"{"op":"run","command":"htop","args":[],"session":"","cwd":"/tmp"}"#)
        else { return #expect(Bool(false), "did not parse a run") }
        #expect(command == "htop")
        #expect(args.isEmpty)
        #expect(cwd == "/tmp")

        guard case .run(let c2, let a2, _, _)?
            = OpenServer.parse(#"{"op":"run","command":"claude","args":["--foo","bar"],"session":"","cwd":"/"}"#)
        else { return #expect(Bool(false), "did not parse a run with args") }
        #expect(c2 == "claude")
        #expect(a2 == ["--foo", "bar"])
    }

    @Test("an empty run command means the user's shell")
    func emptyRunMeansShell() {
        guard case .run(let command, _, _, _)?
            = OpenServer.parse(#"{"op":"run","command":"","args":[],"session":"","cwd":"/tmp"}"#)
        else { return #expect(Bool(false), "did not parse") }
        #expect(command.isEmpty)
    }

    @Test("parses a list")
    func parsesList() {
        guard case .list? = OpenServer.parse(#"{"op":"ls"}"#) else {
            return #expect(Bool(false), "did not parse ls")
        }
    }

    @Test("refuses anything that is not a known op")
    func refusesOtherOps() {
        #expect(OpenServer.parse(#"{"op":"quit"}"#) == nil)
        #expect(OpenServer.parse(#"{"op":"open","url":""}"#) == nil)
        #expect(OpenServer.parse("not json at all") == nil)
        #expect(OpenServer.parse("") == nil)
    }

    @Test("a reply is one line of JSON the CLI can read back")
    func encodesReply() {
        #expect(OpenServer.encode(.handled) == #"{"ok":true}"#)
        #expect(OpenServer.encode(.refused("nope")) == #"{"ok":false,"error":"nope"}"#)
        #expect(OpenServer.encode(OpenServer.Reply(ok: true, session: "a7ab2d3b"))
            == #"{"ok":true,"session":"a7ab2d3b"}"#)
        // `ls` output is multi-line and must survive as one line on the wire.
        let listed = OpenServer.encode(OpenServer.Reply(ok: true, lanes: "a\nb\n"))
        #expect(!listed.dropLast().contains("\n"))
    }
}

/// `relay-pty-host` argv (see docs/reference/relay-integration.md §8).
///
/// Getting this wrong does not fail loudly — it starts a session with the wrong
/// shape, and the consequence shows up much later as a lane whose project tag
/// never updates.
@Suite("relay-pty-host argv")
struct RelaySpawnTests {
    @Test("panes do not inherit Claude Code's child-session markers")
    func scrubsClaudeMarkers() {
        let env = LocalSpawner.scrubClaudeMarkers([
            "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDE_PID": "1", "CLAUDE_EFFORT": "medium",
            "PATH": "/bin", "SHELL": "/bin/zsh", "ANTHROPIC_API_KEY": "k", "CLAUDE_CONFIG_DIR": "d",
        ])
        #expect(env == ["PATH": "/bin", "SHELL": "/bin/zsh", "ANTHROPIC_API_KEY": "k", "CLAUDE_CONFIG_DIR": "d"])
    }

    @Test("a shell session gets --login so cwd tracking works")
    func shellSessionGetsLogin() {
        let argv = LocalSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/Users/s/code",
            command: "/bin/zsh", args: [])
        #expect(argv == ["a1b2c3d4", "80", "40", "/Users/s/code", "/bin/zsh", "--login"])
    }

    @Test("a non-shell command is wrapped in the user's login shell")
    func nonShellIsWrapped() {
        let argv = LocalSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/Users/s/code",
            command: "claude", args: ["--dangerously-skip-permissions"])
        #expect(argv.count == 8)
        #expect(Array(argv.prefix(4)) == ["a1b2c3d4", "80", "40", "/Users/s/code"])
        #expect(argv[5] == "-li")
        #expect(argv[6] == "-c")
        // No `exec`: it would make the agent the session leader, and the
        // classifier returns Idle unconditionally when the foreground pgrp is
        // the leader — so an exec'd agent can never report `blocked`, which is
        // the one signal the sidebar exists for.
        #expect(argv[7] == #"'claude' '--dangerously-skip-permissions'; exit $?"#)
    }

    @Test("arguments with quotes cannot break out of the wrapper")
    func shellEscapingHolds() {
        let argv = LocalSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/tmp",
            command: "echo", args: ["it's; rm -rf /"])
        #expect(argv.last == #"'echo' 'it'\''s; rm -rf /'; exit $?"#)
    }

    @Test("every shell basename is recognised", arguments: [
        "/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "sh", "/bin/dash",
    ])
    func recognisesShells(_ path: String) {
        #expect(LocalSpawner.isShellCommand(path))
    }

    @Test("a command that merely lives in a shell-ish path is not a shell")
    func doesNotMistakeCommandsForShells() {
        #expect(!LocalSpawner.isShellCommand("/bin/zshfoo"))
        #expect(!LocalSpawner.isShellCommand("claude"))
    }

    @Test("a quoted shell line is refused rather than run as a program name", arguments: [
        "yes | head",
        "npm run build",
        "make && make test",
        "sleep 1; echo done",
        "echo $HOME",
        "cat < in > out",
    ])
    func refusesAShellLine(_ command: String) {
        // Each of these arrives from `maxpane run "…"` as one argv word, and the
        // wrapper would ask zsh for a program of that name — exit 127, roughly a
        // second after the CLI has already been told the session is ready.
        #expect(LocalSpawner.isShellLine(command), "let through: \(command)")
    }

    @Test("a program name is not mistaken for a shell line", arguments: [
        "htop", "claude", "/bin/zsh", "/usr/local/bin/relay-pty-host",
        // Shell functions and builtins reach the wrapper as bare words and still
        // run inside it, so nothing here may refuse them.
        "myfunc", "cd", "echo",
    ])
    func allowsProgramNames(_ command: String) {
        #expect(!LocalSpawner.isShellLine(command), "refused: \(command)")
    }

    @Test("an executable that really does have a space in its path is let through")
    func spaceInARealProgramPath() throws {
        // The check is "shell syntax AND no such program", not "shell syntax".
        // /Applications holds plenty of these and refusing them would be a
        // worse bug than the one this fixes.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("max pane spawn test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("my tool")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(!LocalSpawner.isShellLine(tool.path))
    }

    @Test("the refusal says what to type instead")
    func refusalIsActionable() {
        let message = LocalSpawner.SpawnError.notAProgram("yes | head").errorDescription ?? ""
        #expect(message.contains("yes | head"))
        // The escape hatch is real: `run zsh -c '…'` takes the isShellCommand
        // branch, and a pipeline through it exits 0 with output.
        #expect(message.contains("zsh -c"))
    }

    @Test("spawn refuses a shell line before it starts anything at all")
    func spawnRefusesBeforeStarting() {
        // The guard sits ahead of `locatePtyHost`, so this throws whether or not
        // there is a relay-pty-host on the machine — and, more to the point, no
        // session id exists to hand back and no lane is written for one.
        let before = (try? FileManager.default.contentsOfDirectory(
            atPath: RelaySessionDirectory.sessionsDir.path))?.count ?? 0
        #expect(throws: LocalSpawner.SpawnError.self) {
            try LocalSpawner(config: Config())
                .spawn(cwd: "/tmp", command: "yes | head")
        }
        let after = (try? FileManager.default.contentsOfDirectory(
            atPath: RelaySessionDirectory.sessionsDir.path))?.count ?? 0
        #expect(after == before, "a refused run left a session behind")
    }

    @Test("session ids are 8 lowercase hex characters")
    func sessionIdShape() {
        for _ in 0..<50 {
            let id = LocalSpawner.newSessionID()
            #expect(id.count == 8)
            #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
}

/// OSC 7 is no longer parsed here.
///
/// The tests that lived at this spot exercised a hand-rolled scan for
/// `ESC ]7;file://…` in the raw byte stream, written because SwiftTerm did not
/// expose its own parse of it. Ghostty reports the working directory natively
/// through `TerminalSurfacePwdDelegate`, so the code and its tests are both
/// gone rather than kept as decoration. See ADR-0009.

/// Data-store sharding (PRD §9, ADR-0003).
@Suite("WKWebsiteDataStore sharding")
@MainActor
struct DataStoreShardingTests {
    @Test("a project keeps its shard across launches")
    func shardIsStable() {
        let first = DataStorePool.shardId(for: "/Users/s/code/max-pane", count: 3)
        let again = DataStorePool.shardId(for: "/Users/s/code/max-pane", count: 3)
        #expect(first == again)
        // Swift's own hashValue is seeded per process and would not survive this.
        #expect(first == "shard-\(fnv("/Users/s/code/max-pane") % 3)")
    }

    @Test("projects spread across the shards")
    func projectsSpread() {
        let roots = (0..<60).map { "/Users/s/code/project-\($0)" }
        let shards = Set(roots.map { DataStorePool.shardId(for: $0, count: 3) })
        #expect(shards.count == 3, "60 projects landed in \(shards.count) of 3 shards")
    }

    @Test("an untagged pane and a single-shard config both use shard 0")
    func degeneratesCleanly() {
        #expect(DataStorePool.shardId(for: nil, count: 3) == DataStorePool.defaultShardId)
        #expect(DataStorePool.shardId(for: "/anything", count: 1) == DataStorePool.defaultShardId)
    }

    @Test("a shard's store UUID is stable, because WebKit keys the cookie jar by it")
    func storeUuidIsStable() {
        let a = DataStorePool.uuid(for: "shard-1")
        let b = DataStorePool.uuid(for: "shard-1")
        #expect(a == b)
        #expect(DataStorePool.uuid(for: "shard-2") != a)
        // Well-formed v4, or WebKit rejects it.
        #expect(a.uuidString.count == 36)
    }

    private func fnv(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Config loading has to survive a hand-edited file.
/// What one typed line at ⌘O means.
///
/// The whole decision is a pure function, so every case below is answered
/// without a pane, a session or a `relay-pty-host` anywhere near it — which is
/// the point: the bug this replaces could only be seen by watching a lane spew.
@Suite("a line typed at ⌘O")
struct TypedCommandTests {
    private func parse(_ line: String) -> TypedCommand? {
        TypedCommand.parse(line)
    }

    @Test("the regression: a pipeline is a pipeline, not a program with two arguments")
    func aPipelineIsNotAProgram() {
        // `line.split(separator: " ")` made this `yes` with the literal
        // arguments `|` and `head` — a process that runs forever and floods the
        // pane. Not an error message: a lane spewing `y`.
        #expect(parse("yes | head") == .shellLine("yes | head"))
        #expect(parse("yes | head") != .program("yes", args: ["|", "head"]))
    }

    @Test("a line a shell has to read is given to one", arguments: [
        "yes | head",
        "make && make test",
        "sleep 1; echo done",
        "cat < in > out",
        "echo $HOME",
        "git commit -m \"two words\"",
        "rg 'alpha|beta'",
        "ls *.rs",
        "wc -l $(git ls-files)",
        "vim ~/.zshrc",
        "FOO=1 make",
        "(cd /tmp && ls)",
    ])
    func shellLinesGoToTheShell(_ line: String) {
        #expect(parse(line) == .shellLine(line), "split into argv instead: \(line)")
    }

    @Test("a plain program line is still argv, and is still split into words")
    func programLinesStayArgv() {
        #expect(parse("htop") == .program("htop", args: []))
        #expect(parse("npm run build") == .program("npm", args: ["run", "build"]))
        #expect(parse("claude --dangerously-skip-permissions")
            == .program("claude", args: ["--dangerously-skip-permissions"]))
        // A bare shell has to stay argv: `buildArgs` gives it `--login` and
        // pty-host polls it for `cd`, which is what keeps a lane's directory
        // tag live. Wrapping it would freeze the tag at the launch directory.
        #expect(parse("zsh") == .program("zsh", args: []))
    }

    @Test("a `#` is left as argv, because a shell would eat the rest of the line")
    func hashIsNotShellSyntax() {
        // The rule only moves a line to the shell when the shell reading is the
        // better one. `#` is the case where it is worse.
        #expect(parse("open example.com/#top") == .program("open", args: ["example.com/#top"]))
    }

    @Test("runs of whitespace collapse and the ends are trimmed")
    func whitespaceIsNotArgv() {
        #expect(parse("  npm   run   build  ") == .program("npm", args: ["run", "build"]))
    }

    @Test("an empty line asks for nothing")
    func emptyIsNothing() {
        #expect(parse("") == nil)
        #expect(parse("   \n\t ") == nil)
    }

    @Test("the typed line reaches -c as one argument and is not touched otherwise")
    func theLineIsWhatHeTyped() {
        let line = "yes | head"
        let argv = LocalSpawner.buildShellArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/Users/s/code", line: line)
        #expect(Array(argv.prefix(4)) == ["a1b2c3d4", "80", "40", "/Users/s/code"])
        #expect(argv[4] == LocalSpawner.userShell())
        #expect(argv[5] == "-li")
        #expect(argv[6] == "-c")
        // Nothing around it, nothing inside it: the line, then a newline, then
        // the terminator every wrapped session gets.
        #expect(argv[7] == "yes | head\nexit $?")
        #expect(argv.count == 8)
    }

    @Test("the terminator goes on its own line, because `;` is not always legal after one")
    func terminatorSurvivesABackgroundedLine() {
        // Measured: `sleep 5 &; exit $?` is a syntax error in bash and sh, and
        // `ls # note; exit $?` swallows the exit into the comment in bash, sh
        // and zsh alike. A newline ends both the way Return at a prompt does.
        let argv = LocalSpawner.buildShellArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/tmp", line: "sleep 5 &")
        #expect(argv.last == "sleep 5 &\nexit $?")
        // The escaped-argv path keeps `;` — nothing we escape ourselves can end
        // in a `&` or a comment, and its expected string is asserted above.
        #expect(LocalSpawner.shellWrapped("'htop'") == "'htop'; exit $?")
    }

    @Test("a program line goes down the same escaped path maxpane run uses")
    func programLinesAreEscapedArgv() throws {
        guard case .program(let program, let args)? = parse("claude --foo bar") else {
            return #expect(Bool(false), "not parsed as a program")
        }
        let argv = LocalSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/tmp", command: program, args: args)
        #expect(argv.last == #"'claude' '--foo' 'bar'; exit $?"#)
    }

    // MARK: - the two doors

    @Test("the same words at either door do the same thing")
    func wordsAgreeAcrossDoors() {
        // `maxpane run npm run build` is argv already; ⌘O's `npm run build` has
        // to become the same argv, and does.
        #expect(parse("npm run build") == .program("npm", args: ["run", "build"]))
        #expect(!LocalSpawner.isShellLine("npm"))
    }

    @Test("the doors differ only where they are handed different things")
    func doorsDifferDeliberately() {
        // One argv *word* containing shell syntax is refused by `maxpane run`:
        // a script's `maxpane run "$cmd"` must not have `$cmd` interpreted a
        // second time.
        #expect(LocalSpawner.isShellLine("yes | head"))
        // The same characters typed at ⌘O are one uninterpreted line from the
        // owner's own keyboard, and a shell is the only correct reader of one.
        #expect(parse("yes | head") == .shellLine("yes | head"))
        // And the CLI's refusal names the spelling that works there.
        let message = LocalSpawner.SpawnError.notAProgram("yes | head").errorDescription ?? ""
        #expect(message.contains("zsh -c"))
    }
}

@Suite("config")
struct ConfigTests {
    @Test("clamps a width to the configured range")
    func clampsWidth() {
        var config = Config()
        config.laneMinPt = 420
        config.laneMaxPt = 900
        #expect(config.clampWidth(10) == 420)
        #expect(config.clampWidth(10_000) == 900)
        #expect(config.clampWidth(560) == 560)
    }

    @Test("a min larger than the max does not trap")
    func survivesInvertedBounds() {
        var config = Config()
        config.laneMinPt = 900
        config.laneMaxPt = 420
        #expect(config.widthRange == 420...900)
        #expect(config.clampWidth(600) == 600)
    }

    // MARK: - reading the file

    private func load(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test("a file that sets one key keeps the defaults for the rest")
    func partialFilesWork() throws {
        // This is the whole point. Swift's synthesised decoder throws on a
        // missing key, which made the file all-or-nothing.
        let config = try load(#"{"snapToLanes": false}"#)
        #expect(config.snapToLanes == false)
        #expect(config.laneDefaultPt == Config().laneDefaultPt)
        #expect(config.fontName == Config().fontName)
    }

    @Test("an empty object is all defaults")
    func emptyObject() throws {
        let config = try load("{}")
        #expect(config.laneMinPt == Config().laneMinPt)
        #expect(config.snapToLanes == true)
    }

    @Test("snapping is on unless it is turned off")
    func snapDefaultsOn() {
        #expect(Config().snapToLanes)
        #expect(Config().snapSeconds > 0)
    }

    @Test("a value of the wrong type is skipped, not fatal")
    func oneBadValueDoesNotSinkTheFile() throws {
        // A typo in one setting must not revert every other setting.
        let config = try load(#"{"laneMinPt": "wide", "fontName": "Menlo"}"#)
        #expect(config.laneMinPt == Config().laneMinPt)
        #expect(config.fontName == "Menlo")
    }

    @Test("an unknown key is ignored")
    func unknownKeysAreIgnored() throws {
        let config = try load(#"{"colourScheme": "dracula", "fontSize": 15}"#)
        #expect(config.fontSize == 15)
    }

    @Test("every key round-trips")
    func roundTrip() throws {
        var config = Config()
        config.snapToLanes = false
        config.snapSeconds = 0.5
        config.laneMinPt = 500
        config.relayPtyHostPath = "/opt/relay-pty-host"

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: encoded)
        #expect(decoded.snapToLanes == false)
        #expect(decoded.snapSeconds == 0.5)
        #expect(decoded.laneMinPt == 500)
        #expect(decoded.relayPtyHostPath == "/opt/relay-pty-host")
    }
}

/// Finding `relay-pty-host` when nobody handed the app a PATH.
///
/// A GUI app launched from the Dock gets launchd's `/usr/bin:/bin:/usr/sbin:
/// /sbin`, so every tool installed by nvm, cargo, Homebrew or npm is invisible.
/// The symptom was ⇧⌘D reporting "Could not find relay-pty-host" on a machine
/// with two of them, and it hid for months because launching from a terminal
/// inherits the real PATH.
@Suite("the PATH a Dock launch does not get")
struct LoginShellPathTests {
    @Test("the marked line is read whatever else the rc file printed")
    func parsesMarker() {
        let noisy = """
            nvm: version 22 in use
            \(LocalSpawner.pathMarker)/usr/local/bin:/opt/homebrew/bin
            have a nice day
            """
        #expect(LocalSpawner.parseMarkedPath(noisy)
            == "/usr/local/bin:/opt/homebrew/bin")
    }

    /// The bug that made the first version of this fallback return nil on the
    /// owner's machine. iTerm2's shell integration writes OSC sequences to
    /// stdout with no newline after them, so the marker is never at a line
    /// start and an anchored parser reads a correct answer as no answer.
    @Test("a marker behind iTerm2's escape sequences is still read")
    func parsesMarkerAfterTerminalIntegration() {
        let iterm = "\u{1b}]1337;RemoteHost=spierce@mbp\u{7}\u{1b}]1337;"
            + "ShellIntegrationVersion=5;shell=zsh\u{7}"
            + "\(LocalSpawner.pathMarker)/opt/homebrew/bin:/usr/bin\n"
        #expect(LocalSpawner.parseMarkedPath(iterm) == "/opt/homebrew/bin:/usr/bin")
    }

    @Test("a sequence closed after the value does not land in the PATH")
    func stopsAtATrailingControlByte() {
        let trailing = "\(LocalSpawner.pathMarker)/usr/bin:/bin\u{1b}]1337;done\u{7}\n"
        #expect(LocalSpawner.parseMarkedPath(trailing) == "/usr/bin:/bin")
    }

    /// The reason for the marker: the last line is not the answer, and neither
    /// is the first.
    @Test("output with no marker is no answer, not a wrong one")
    func refusesUnmarkedOutput() {
        #expect(LocalSpawner.parseMarkedPath("/usr/bin:/bin") == nil)
        #expect(LocalSpawner.parseMarkedPath("") == nil)
        #expect(LocalSpawner.parseMarkedPath("\(LocalSpawner.pathMarker)") == nil)
    }

    @Test("a real login shell answers with a real PATH")
    func readsFromARealShell() throws {
        // `/bin/sh`, not `$SHELL`: this has to be the same on every machine that
        // runs the suite, and it costs milliseconds rather than whatever the
        // tester's rc file costs.
        let path = try #require(LocalSpawner.readLoginShellPath(shell: "/bin/sh"))
        #expect(path.contains("/bin"), "a PATH with no /bin in it is not a PATH")
    }

    @Test("a shell that cannot be run is nil, not a crash")
    func missingShellIsNil() {
        #expect(LocalSpawner.readLoginShellPath(shell: "/nope/not/a/shell") == nil)
    }

    /// The actual regression: the walk finds both of this repo's own binaries
    /// once `which` can see the PATH, and finds neither when it cannot.
    @Test("which falls back past an inherited PATH that has nothing in it")
    func fallsBackPastAnEmptyInheritedPath() throws {
        // `sh` exists on every machine and is never in launchd's PATH twice, so
        // it stands in for `relay` without depending on Relay being installed.
        #expect(LocalSpawner.which("sh") != nil)
    }
}
