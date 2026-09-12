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
    @Test("a shell session gets --login so cwd tracking works")
    func shellSessionGetsLogin() {
        let argv = RelaySessionSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/Users/s/code",
            command: "/bin/zsh", args: [])
        #expect(argv == ["a1b2c3d4", "80", "40", "/Users/s/code", "/bin/zsh", "--login"])
    }

    @Test("a non-shell command is wrapped in the user's login shell")
    func nonShellIsWrapped() {
        let argv = RelaySessionSpawner.buildArgs(
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
        let argv = RelaySessionSpawner.buildArgs(
            id: "a1b2c3d4", cols: 80, rows: 40, cwd: "/tmp",
            command: "echo", args: ["it's; rm -rf /"])
        #expect(argv.last == #"'echo' 'it'\''s; rm -rf /'; exit $?"#)
    }

    @Test("every shell basename is recognised", arguments: [
        "/bin/zsh", "/bin/bash", "/usr/local/bin/fish", "sh", "/bin/dash",
    ])
    func recognisesShells(_ path: String) {
        #expect(RelaySessionSpawner.isShellCommand(path))
    }

    @Test("a command that merely lives in a shell-ish path is not a shell")
    func doesNotMistakeCommandsForShells() {
        #expect(!RelaySessionSpawner.isShellCommand("/bin/zshfoo"))
        #expect(!RelaySessionSpawner.isShellCommand("claude"))
    }

    @Test("session ids are 8 lowercase hex characters")
    func sessionIdShape() {
        for _ in 0..<50 {
            let id = RelaySessionSpawner.newSessionID()
            #expect(id.count == 8)
            #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
}

/// OSC 7 sniffing — ADR-0005's sub-second cwd path.
@Suite("OSC 7 extraction")
@MainActor
struct OSC7Tests {
    private func bytes(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }

    @Test("finds a BEL-terminated sequence")
    func findsBelTerminated() {
        let path = TerminalPaneController.extractOSC7Path(
            bytes("some output\u{1b}]7;file://mac/Users/s/code/max-pane\u{07}more"))
        #expect(path == "/Users/s/code/max-pane")
    }

    @Test("finds an ST-terminated sequence")
    func findsStTerminated() {
        let path = TerminalPaneController.extractOSC7Path(
            bytes("\u{1b}]7;file://mac/Users/s/life\u{1b}\\"))
        #expect(path == "/Users/s/life")
    }

    @Test("takes the newest when a burst contains several")
    func takesTheNewest() {
        let path = TerminalPaneController.extractOSC7Path(
            bytes("\u{1b}]7;file://mac/first\u{07}out\u{1b}]7;file://mac/second\u{07}"))
        #expect(path == "/second")
    }

    @Test("decodes percent-escaped paths")
    func decodesPercentEscapes() {
        let path = TerminalPaneController.extractOSC7Path(
            bytes("\u{1b}]7;file://mac/Users/s/My%20Projects/a%2Bb\u{07}"))
        #expect(path == "/Users/s/My Projects/a+b")
    }

    @Test("ignores ordinary output and other OSC sequences")
    func ignoresOtherSequences() {
        #expect(TerminalPaneController.extractOSC7Path(bytes("just some text")) == nil)
        // OSC 0 is a title, not a directory.
        #expect(TerminalPaneController.extractOSC7Path(bytes("\u{1b}]0;a title\u{07}")) == nil)
        #expect(TerminalPaneController.extractOSC7Path(bytes("")) == nil)
    }

    @Test("does not crash on a truncated sequence at the end of a frame")
    func survivesTruncation() {
        // A frame boundary can land mid-sequence; the next frame carries the rest.
        #expect(TerminalPaneController.extractOSC7Path(bytes("\u{1b}]7;file://mac/Users/s")) == "/Users/s")
        #expect(TerminalPaneController.extractOSC7Path(bytes("\u{1b}]7;fi")) == nil)
    }
}

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
}
