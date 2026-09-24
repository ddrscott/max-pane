import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// The daily release check, what the bar and the popover say about it, what
/// Update… runs, the lane that outlives its exit, and the relaunch helper's
/// scrubbed environment (ADR-0038). Nothing here reaches api.github.com:
/// every feed is a closure.
@Suite("app update")
@MainActor
struct AppUpdateTests {
    nonisolated static let feedJSON = """
        {"tag_name":"v0.8.0","name":"0.8.0","draft":false,"prerelease":false,
         "html_url":"https://github.com/ddrscott/max-pane/releases/tag/v0.8.0",
         "published_at":"2026-09-30T18:04:11Z"}
        """
    static let release = Release(
        tag: "v0.8.0", url: "https://github.com/ddrscott/max-pane/releases/tag/v0.8.0",
        name: "0.8.0", publishedAt: "2026-09-30T18:04:11Z")

    // MARK: versions

    @Test("versions order by number, not by string; a v and build metadata are dropped; a prerelease precedes its release")
    func versionOrdering() throws {
        let v = { (s: String) in try #require(SemanticVersion(s), "\(s)") }
        #expect(try v("0.10.0") > v("0.9.0"))
        #expect(try v("v0.8.0") == v("0.8.0"))
        #expect(try v("0.8") == v("0.8.0"))
        #expect(try v("1.0.0+build.7") == v("1.0.0"))
        #expect(try v("0.8.0-beta.1") < v("0.8.0"))
        #expect(try v("0.8.0-beta.1") < v("0.8.0-beta.2"))
        #expect(try v("0.8.0-alpha") < v("0.8.0-beta"))
        #expect(try v("0.8.0-beta") < v("0.8.0-beta.1"))
        #expect(try v("0.7.0") < v("0.8.0-beta.1"))
        #expect(SemanticVersion("Unreleased") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.x") == nil)
        #expect(SemanticVersion("1.2.3-") == nil)
        #expect(try v("0.8.0-beta.1").description == "0.8.0-beta.1")
        #expect(try v("v0.8").description == "0.8.0")
        // The changelog's sections carry it, and Unreleased does not.
        let log = Changelog.parse("## [Unreleased]\n- a\n## [0.10.0] - 2026-10-01\n- b\n## [0.9.0] - 2026-09-01\n- c\n")
        #expect(log.sections.map(\.semanticVersion) == [nil, SemanticVersion("0.10.0"), SemanticVersion("0.9.0")])
        #expect(try log.sections[1].semanticVersion! > log.sections[2].semanticVersion!)
    }

    // MARK: the feed

    @Test("the feed's JSON is one release; a draft, a prerelease or junk is none")
    func feed() throws {
        let release = try #require(ReleaseFeed.parse(Data(Self.feedJSON.utf8)))
        #expect(release == Self.release)
        #expect(release.version == SemanticVersion("0.8.0"))
        #expect(release.label == "v0.8.0")
        #expect(ReleaseFeed.parse(Data("{\"tag_name\":\"v0.9.0\",\"draft\":true}".utf8)) == nil)
        #expect(ReleaseFeed.parse(Data("{\"tag_name\":\"v0.9.0\",\"prerelease\":true}".utf8)) == nil)
        #expect(ReleaseFeed.parse(Data("{\"name\":\"no tag\"}".utf8)) == nil)
        #expect(ReleaseFeed.parse(Data("<html>rate limited</html>".utf8)) == nil)
        // A body with no page falls back to the releases list.
        #expect(ReleaseFeed.parse(Data("{\"tag_name\":\"v0.9.0\"}".utf8))?.url == ReleaseFeed.releasesPage)
        #expect(ReleaseFeed.url.host == "api.github.com")
    }

    @Test("newer than the plist is available; the same, older, or an unparseable tag is current")
    func decide() {
        #expect(UpdateStatus.decide(installed: "0.7.0", release: Self.release) == .available(Self.release))
        #expect(UpdateStatus.decide(installed: "0.8.0", release: Self.release) == .current(Self.release))
        // A build from main past the release: the corner's +N says so; no ↻.
        #expect(UpdateStatus.decide(installed: "0.9.0", release: Self.release) == .current(Self.release))
        let odd = Release(tag: "nightly", url: "x")
        #expect(UpdateStatus.decide(installed: "0.7.0", release: odd) == .current(odd))
        #expect(UpdateStatus.decide(installed: "0.7.0", release: Self.release).available == Self.release)
        #expect(UpdateStatus.unknown.available == nil)
    }

    // MARK: the checker

    /// A checker over a fake feed and a settable clock.
    @MainActor
    final class Rig {
        /// The clock, the memory and the change count, held apart from the
        /// checker so the closures handed to it capture no half-built self.
        @MainActor final class State {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            var memory: UpdateChecker.Memory?
            var changes = 0
        }
        let state = State()
        let box = Box()
        let checker: UpdateChecker
        var now: Date {
            get { state.now }
            set { state.now = newValue }
        }
        var memory: UpdateChecker.Memory? { state.memory }
        var changes: Int { state.changes }
        var sent: [URLRequest] { box.requests }

        init(installed: String = "0.7.0", memory: UpdateChecker.Memory? = nil,
             relay: RelayRequirement.Reading = .init(path: "/usr/local/bin/relay", installed: SemanticVersion("1.22.0")),
             answer: @escaping @Sendable (URLRequest) async throws -> UpdateChecker.Response) {
            let state = self.state
            let box = self.box
            state.memory = memory
            checker = UpdateChecker(
                installed: installed,
                fetch: { request in
                    box.record(request)
                    return try await answer(request)
                },
                now: { state.now },
                load: { state.memory },
                save: { state.memory = $0 },
                relayVersion: { relay })
            checker.onChange = { state.changes += 1 }
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [URLRequest] = []
            func record(_ r: URLRequest) { lock.withLock { seen.append(r) } }
            var requests: [URLRequest] { lock.withLock { seen } }
        }
    }

    static let ok: @Sendable (URLRequest) async throws -> UpdateChecker.Response = { _ in
        UpdateChecker.Response(status: 200, body: Data(feedJSON.utf8), etag: "\"abc\"")
    }

    @Test("the first check reads the feed, names the release, remembers the ETag and the time")
    func firstCheck() async throws {
        let rig = Rig(answer: Self.ok)
        #expect(rig.checker.status == .unknown)
        #expect(rig.checker.isDue)
        await rig.checker.checkIfDue()
        #expect(rig.checker.status == .available(Self.release))
        #expect(rig.checker.relay?.installed == SemanticVersion("1.22.0"))
        #expect(rig.checker.lastError == nil)
        #expect(rig.checker.lastCheck == rig.now)
        #expect(rig.memory == UpdateChecker.Memory(lastCheck: rig.now, etag: "\"abc\"", release: Self.release))
        #expect(rig.changes == 1)
        let request = try #require(rig.sent.first)
        #expect(request.url == ReleaseFeed.url)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "max-pane/0.7.0")
        #expect(!rig.checker.isDue)
    }

    @Test("once a day: a second check within the day reads nothing; the day after, it sends the ETag and a 304 keeps the answer")
    func onceADay() async throws {
        let rig = Rig(answer: { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"" {
                return UpdateChecker.Response(status: 304, body: Data())
            }
            return try await Self.ok(request)
        })
        await rig.checker.checkIfDue()
        #expect(rig.checker.fetchCount == 1)
        rig.now += 3_600 * 23
        await rig.checker.checkIfDue()
        #expect(rig.checker.fetchCount == 1, "not due yet")
        rig.now += 3_600 * 2
        await rig.checker.checkIfDue()
        #expect(rig.checker.fetchCount == 2)
        #expect(rig.sent.last?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(rig.checker.status == .available(Self.release), "a 304 keeps yesterday's release")
        #expect(rig.checker.lastCheck == rig.now)
        #expect(rig.checker.lastError == nil)
        // Help › Check for Updates… asks whatever the clock says.
        await rig.checker.check()
        #expect(rig.checker.fetchCount == 3)
    }

    @Test("yesterday's release is the answer from the first frame, before any check")
    func remembered() {
        let yesterday = UpdateChecker.Memory(
            lastCheck: Date(timeIntervalSince1970: 1_800_000_000 - 3_600), etag: "\"abc\"", release: Self.release)
        let rig = Rig(memory: yesterday, answer: Self.ok)
        #expect(rig.checker.status == .available(Self.release))
        #expect(!rig.checker.isDue)
        // The same memory on the release itself: current, no ↻.
        #expect(Rig(installed: "0.8.0", memory: yesterday, answer: Self.ok).checker.status == .current(Self.release))
    }

    @Test("no network: one line of error kept for the popover, the status untouched, and not again until tomorrow")
    func offline() async {
        struct Down: Error {}
        let rig = Rig(answer: { _ in throw Down() })
        await rig.checker.checkIfDue()
        #expect(rig.checker.status == .unknown)
        #expect(rig.checker.lastError == "could not reach github.com")
        #expect(rig.checker.lastCheck == rig.now)
        #expect(!rig.checker.isDue, "an outage is not retried every hour")
        #expect(rig.changes == 1)
        // A 403 (rate limited) or a body with nothing in it: the same shape.
        let limited = Rig(answer: { _ in UpdateChecker.Response(status: 403, body: Data()) })
        await limited.checker.check()
        #expect(limited.checker.lastError == "the release feed answered 403")
        let empty = Rig(answer: { _ in UpdateChecker.Response(status: 200, body: Data("{}".utf8)) })
        await empty.checker.check()
        #expect(empty.checker.lastError == "the release feed had no release in it")
        #expect(empty.checker.status == .unknown)
    }

    @Test("a check that fails after a good one keeps the release it had")
    func failureKeepsRelease() async {
        struct Down: Error {}
        let counter = Rig.Box()
        let rig = Rig(answer: { request in
            counter.record(request)
            if counter.requests.count > 1 { throw Down() }
            return try await Self.ok(request)
        })
        await rig.checker.check()
        await rig.checker.check()
        #expect(rig.checker.status == .available(Self.release))
        #expect(rig.checker.lastError == "could not reach github.com")
    }

    @Test("the memory round-trips through JSON as UserDefaults keeps it")
    func memoryCodable() throws {
        let memory = UpdateChecker.Memory(lastCheck: Date(timeIntervalSince1970: 1_800_000_000), etag: "\"x\"", release: Self.release)
        let data = try JSONEncoder().encode(memory)
        #expect(try JSONDecoder().decode(UpdateChecker.Memory.self, from: data) == memory)
    }

    // MARK: what the bar and the popover say

    @Test("the bar reads ↻ vNEXT for a release, ↻ relay-tty 1.22.0 for a short relay alone, nothing otherwise")
    func barText() {
        let short = RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("1.20.0"))
        let fine = RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("1.22.0"))
        #expect(UpdateNotice.barText(.available(Self.release), relay: fine) == "↻ v0.8.0")
        #expect(UpdateNotice.barText(.available(Self.release), relay: short) == "↻ v0.8.0")
        #expect(UpdateNotice.barText(.current(Self.release), relay: fine) == nil)
        #expect(UpdateNotice.barText(.unknown, relay: nil) == nil)
        #expect(UpdateNotice.barText(.current(Self.release), relay: short) == "↻ relay-tty 1.22.0")
        #expect(UpdateNotice.barTooltip(.available(Self.release), relay: short) ==
            "Max Pane v0.8.0 is out. Click to update in a terminal lane (Help › Update…).\n"
            + "relay-tty 1.20.0 is installed · 1.22.0 or newer is needed for BLOCKED")
        #expect(UpdateNotice.barTooltip(.current(Self.release), relay: fine) == nil)
    }

    @Test("the popover's lines: the release as an action, up to date with when, the error, and relay-tty when short")
    func popoverLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let short = RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("1.20.0"))
        #expect(UpdateNotice.lines(status: .available(Self.release), lastCheck: now, lastError: nil, relay: nil, now: now) ==
            [.init(text: "↻ v0.8.0 is available · update…", isAction: true)])
        #expect(UpdateNotice.lines(status: .current(Self.release), lastCheck: now - 30, lastError: nil, relay: nil, now: now) ==
            [.init(text: "up to date · v0.8.0 is the latest release · checked just now")])
        #expect(UpdateNotice.lines(status: .current(Self.release), lastCheck: now - 3 * 3_600, lastError: nil, relay: short, now: now) ==
            [.init(text: "up to date · v0.8.0 is the latest release · checked 3 hours ago"),
             .init(text: "relay-tty 1.20.0 is installed · 1.22.0 or newer is needed for BLOCKED")])
        #expect(UpdateNotice.lines(status: .unknown, lastCheck: now - 3 * 86_400, lastError: "could not reach github.com", relay: nil, now: now) ==
            [.init(text: "could not reach github.com · checked 3 days ago")])
        #expect(UpdateNotice.lines(status: .unknown, lastCheck: nil, lastError: nil, relay: nil, now: now) ==
            [.init(text: "not checked for updates yet")])
        #expect(UpdateNotice.checked(now - 600, now: now) == " · checked 10 min ago")
        #expect(UpdateNotice.checked(now - 3_600, now: now) == " · checked 1 hour ago")
    }

    @Test("the status bar shows the ↻ at the right and takes it away; a click on it is the update")
    func statusBar() {
        let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: 900, height: StatusBar.height))
        #expect(bar.updateText == "")
        bar.setUpdate("↻ v0.8.0", tooltip: "Max Pane v0.8.0 is out.")
        #expect(bar.updateText == "↻ v0.8.0")
        #expect(bar.updateTooltip == "Max Pane v0.8.0 is out.")
        bar.setUpdate("↻ v0.9.0", tooltip: nil)
        #expect(bar.updateText == "↻ v0.9.0")
        bar.setUpdate(nil, tooltip: nil)
        #expect(bar.updateText == "")
    }

    @Test("the popover draws the update lines above the changelog, and the action line runs Update…")
    func popover() throws {
        let lines = UpdateNotice.lines(
            status: .available(Self.release), lastCheck: nil, lastError: nil,
            relay: .init(path: "/x/relay", installed: SemanticVersion("1.20.0")))
        let popup = ChangelogPopup(model: ChangelogPopupModel(
            changelog: Changelog.parse("## [Unreleased]\n- a\n## [0.7.0] - 2026-09-22\n- b\n"), notices: lines))
        #expect(popup.noticeTexts == [
            "↻ v0.8.0 is available · update…",
            "relay-tty 1.20.0 is installed · 1.22.0 or newer is needed for BLOCKED",
        ])
        #expect(popup.headerTexts.count == 2)
        // With nothing to say, nothing is drawn: a swift run's popup is as it was.
        let plain = ChangelogPopup(model: ChangelogPopupModel(changelog: Changelog.parse("## [Unreleased]\n- a\n")))
        #expect(plain.noticeTexts.isEmpty)
    }

    // MARK: what Update… runs

    @Test("update_command wins; then brew; then the release page")
    func plan() {
        #expect(UpdatePlan.decide(updateCommand: "make install", brewOnPath: true, release: Self.release) == .command("make install"))
        #expect(UpdatePlan.decide(updateCommand: "  ", brewOnPath: true, release: nil) == .command("brew upgrade --cask max-pane"))
        #expect(UpdatePlan.decide(updateCommand: nil, brewOnPath: true, release: nil) == .command(UpdatePlan.brewLine))
        #expect(UpdatePlan.decide(updateCommand: nil, brewOnPath: false, release: Self.release) == .releasePage(Self.release.url))
        #expect(UpdatePlan.decide(updateCommand: nil, brewOnPath: false, release: nil) == .releasePage(ReleaseFeed.releasesPage))
        // The line is one a login shell reads: ⌘O's door, not `maxpane run`'s.
        #expect(TypedCommand.parse(UpdatePlan.brewLine) == .program("brew", args: ["upgrade", "--cask", "max-pane"]))
    }

    @Test("update_command is a config key, in the settings window, off by default")
    func setting() throws {
        #expect(Config().updateCommand == nil)
        let field = try #require(ConfigField.all.first { $0.name == "updateCommand" })
        #expect(field.key == "update_command")
        #expect(field.group == .terminals)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-update-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try "update_command = \"brew upgrade --cask ddrscott/tap/max-pane\"\n".write(to: file, atomically: true, encoding: .utf8)
        let (config, problems, _) = ConfigFile.load(from: file)
        #expect(problems.isEmpty)
        #expect(config.updateCommand == "brew upgrade --cask ddrscott/tap/max-pane")
    }

    // MARK: relay-tty

    @Test("relay --version is read whatever it is wrapped in, and 1.22.0 is the line")
    func relayVersion() {
        #expect(RelayRequirement.parse("relay-tty 1.22.0\n") == SemanticVersion("1.22.0"))
        #expect(RelayRequirement.parse("1.23.1") == SemanticVersion("1.23.1"))
        #expect(RelayRequirement.parse("Now using node v22.1.0\nv1.21.0\n") == SemanticVersion("22.1.0"),
                "the first version-shaped token is taken; nvm chatter is on stderr in practice")
        #expect(RelayRequirement.parse("relay-tty version 1.20.0 (abc123)") == SemanticVersion("1.20.0"))
        #expect(RelayRequirement.parse("") == nil)
        #expect(RelayRequirement.parse("command not found") == nil)
        #expect(RelayRequirement.minimum == SemanticVersion("1.22.0"))
        let short = RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("1.21.9"))
        #expect(short.isShort)
        #expect(short.shortLine == "relay-tty 1.21.9 is installed · 1.22.0 or newer is needed for BLOCKED")
        #expect(!RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("1.22.0")).isShort)
        #expect(!RelayRequirement.Reading(path: "/x/relay", installed: SemanticVersion("2.0.0")).isShort)
        // Not found, or found and mute, is not "short": the spawner says that.
        #expect(!RelayRequirement.Reading(path: nil, installed: nil).isShort)
        #expect(RelayRequirement.Reading(path: "/x/relay", installed: nil).shortLine == nil)
    }

    // MARK: the commands

    @Test("Check for Updates… and Update… are Help-menu commands with no default key")
    func commands() {
        #expect(Command.checkForUpdates.menu == .help)
        #expect(Command.updateApp.menu == .help)
        #expect(Keymap.defaults.chords(for: .checkForUpdates).isEmpty)
        #expect(Keymap.defaults.chords(for: .updateApp).isEmpty)
        #expect(Command.updateApp.title == "Update…")
        #expect(Command.checkForUpdates.title == "Check for Updates…")
        // Rebindable, like everything else.
        let bound = Keymap(overrides: KeyBindings(["updateApp": ["cmd+shift+u"]]))
        #expect(bound.chords(for: .updateApp) == [KeyChord(key: "u", modifiers: [.command, .shift])])
    }

    // MARK: the relaunch helper

    @Test("the helper's environment is the eight login keys and the system PATH, and nothing from Claude")
    func relaunchEnvironment() {
        let env = Relaunch.environment(from: [
            "HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/x",
            "LANG": "en_US.UTF-8", "SSH_AUTH_SOCK": "/tmp/agent", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "PATH": "/opt/homebrew/bin:/Users/x/.nvm/bin:/usr/bin",
            "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_PID": "123", "CLAUDE_EFFORT": "high",
            "ANTHROPIC_API_KEY": "sk-ant-secret", "ANTHROPIC_BASE_URL": "https://x",
            "MAXPANE_PROFILE": "default", "MAXPANE_SOCKET": "/tmp/s", "TERM": "xterm", "EDITOR": "vim",
        ])
        #expect(env == [
            "HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "SHELL": "/bin/zsh", "TMPDIR": "/tmp/x",
            "LANG": "en_US.UTF-8", "SSH_AUTH_SOCK": "/tmp/agent", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        #expect(!env.keys.contains { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC") || $0.hasPrefix("MAXPANE") })
        // A key that is missing stays missing; PATH is always there.
        #expect(Relaunch.environment(from: [:]) == ["PATH": Relaunch.path])
        #expect(Relaunch.environment(from: ["HOME": ""]) == ["PATH": Relaunch.path])
    }

    @Test("the helper waits for the pid to be gone, then opens the bundle with -n, with the scrubbed environment")
    func relaunchHelper() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fake `open` first on the helper's PATH: it writes its argv, the
        // time, and its environment where the test can read them.
        let log = dir.appendingPathComponent("open.log")
        let fakeOpen = dir.appendingPathComponent("open")
        try """
            #!/bin/sh
            { echo "argv: $*"; echo "at: $(date +%s.%N)"; env | sort; } > \(LocalSpawner.shellEscape(log.path))
            """.write(to: fakeOpen, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)

        // The "app": a sleep that ends on its own, standing in for this
        // process quitting after the helper was started.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.6"]
        try app.run()
        let bundle = "/Applications/Max Pane's Test.app"
        var env = Relaunch.environment(from: [
            "HOME": dir.path, "CLAUDE_CODE_CHILD_SESSION": "1", "ANTHROPIC_API_KEY": "sk-ant-x",
        ])
        env["PATH"] = dir.path + ":" + Relaunch.path
        let started = Date()
        let helper = try Relaunch.spawnHelper(pid: app.processIdentifier, bundle: bundle, environment: env)
        #expect(helper.environment?["CLAUDE_CODE_CHILD_SESSION"] == nil)

        // The helper is a Process this test holds; the app holds nothing.
        while helper.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(helper.terminationStatus == 0)
        #expect(!app.isRunning, "the helper only ends after the pid is gone")
        #expect(Date().timeIntervalSince(started) >= 0.5, "it waited for the sleep rather than opening at once")
        let text = try String(contentsOf: log, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "argv: -n \(bundle)")
        #expect(lines.contains("HOME=\(dir.path)"))
        #expect(lines.contains("PATH=\(env["PATH"]!)"))
        #expect(!lines.contains { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC") })
        #expect(!lines.contains { $0.hasPrefix("MAXPANE") }, "nothing of this test process's environment leaks")
    }

    @Test("the helper gives up rather than opening a minute later")
    func relaunchScript() {
        let script = Relaunch.script(pid: 4242, bundle: "/Applications/MaxPane.app")
        #expect(script.contains("kill -0 4242"))
        #expect(script.contains("exec open -n '/Applications/MaxPane.app'"))
        #expect(script.contains("-ge 300"))
        #expect(script.contains("exit 1"))
    }

    // MARK: the banner

    @Test("the banner's action state: the line in grey, the button in the accent with its $, none for an empty label")
    func banner() {
        let banner = ReconnectingBanner()
        banner.setState(.action("updated · exit 0", label: "relaunch"))
        #expect(!banner.isHidden)
        #expect(banner.actionLabel == "$ RELAUNCH")
        var pressed = 0
        banner.onAction = { pressed += 1 }
        banner.setState(.action("update failed · exit 1 · ⌘W closes this lane", label: ""))
        #expect(banner.actionLabel == "")
        banner.setState(.exited(0))
        #expect(banner.actionLabel == "")
        banner.setState(.action("updated · exit 0", label: "relaunch"))
        #expect(banner.actionLabel == "$ RELAUNCH")
        _ = pressed
    }

    // MARK: the lane that outlives its exit

    /// A strip with one terminal lane over a fake attachment.
    @MainActor
    final class LaneRig {
        let dir: URL
        let store: StripStore
        let strip: StripViewController
        let window: NSWindow
        var attachments: [String: ExitAttachment] = [:]
        var controllers: [String: TerminalPaneController] = [:]

        init(session: String) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-update-lane-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            strip = StripViewController(store: store, config: Config())
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 1200, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            strip.controllerFactory = { [unowned self] pane, _ in
                let config = Config()
                let controller = TerminalPaneController(
                    pane: pane, store: store, config: config,
                    controller: TerminalControllerPool.makeController(for: config))
                let attachment = ExitAttachment(sessionId: pane.sessionKey?.id ?? "")
                controller.attach(attachment)
                self.attachments[pane.id] = attachment
                self.controllers[pane.id] = controller
                return controller
            }
            strip.view.frame = window.contentView!.bounds
            strip.view.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(strip.view)
        }
        func settle() async {
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        func tearDown() {
            window.orderOut(nil)
            strip.view.removeFromSuperview()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @MainActor
    final class ExitAttachment: RelayAttachment {
        let sessionId: String
        init(sessionId: String) { self.sessionId = sessionId }
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) {}
        func claimSize(cols: Int, rows: Int) {}
    }

    @Test("a held session's exit keeps the lane and hands over the code; RELAUNCH lands on its banner; an unheld one closes")
    func laneOutlivesExit() async throws {
        let rig = try LaneRig(session: "upd00001")
        defer { rig.tearDown() }
        var codes: [Int32] = []
        // Before the lane exists, as the window controller does it.
        rig.strip.holdExit(ofSession: "upd00001") { codes.append($0) }
        try rig.store.newTerminalLane(relaySessionId: "upd00001", near: nil)
        try rig.store.newTerminalLane(relaySessionId: "other001", near: nil)
        await rig.settle()
        let held = try #require(rig.store.state.lanes[0].panes.first)
        let other = try #require(rig.store.state.lanes[1].panes.first)
        let heldAttachment = try #require(rig.attachments[held.id])
        let otherAttachment = try #require(rig.attachments[other.id])

        heldAttachment.onExit?(0)
        otherAttachment.onExit?(0)
        #expect(codes == [0])
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(rig.store.pane(held.id) != nil, "the held lane stays")
        #expect(rig.store.pane(other.id) == nil, "an ordinary exit still closes its pane")

        var relaunched = 0
        #expect(rig.strip.showExitAction(ofSession: "upd00001", text: "updated · exit 0", label: "relaunch") { relaunched += 1 })
        let controller = try #require(rig.controllers[held.id])
        #expect(controller.bannerText == "UPDATED · EXIT 0")
        #expect(controller.exitActionLabel == "$ RELAUNCH")
        controller.pressExitAction()
        #expect(relaunched == 1)
        // A hold is spent by its exit: a second exit report is an ordinary one.
        #expect(!rig.strip.showExitAction(ofSession: "nope", text: "", label: "") {})
    }

    // MARK: the sheets

    /// The bar with a `↻` and the popover with its update lines, in both
    /// appearances. Gated on `MAXPANE_SHOTS`.
    ///
    ///     ./scripts/test.sh shots /tmp/shots
    @Test("renders the ↻ in the bar and the update lines in the popover")
    func renderSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED renders the update sheets — set MAXPANE_SHOTS=DIR")
            return
        }
        try AppearanceSheet.render(to: dir, named: "status-bar-update") {
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: StatusBar.height))
            let bar = StatusBar(frame: sheet.bounds)
            bar.update(
                state: StripState(lanes: [], scrollX: 0, focusedPaneId: nil, gatherFilter: nil, hiddenLaneIds: [], revision: 1),
                telemetry: [:], webBytes: 0)
            bar.setUpdate("↻ v0.8.0", tooltip: nil)
            sheet.addSubview(bar)
            bar.layoutSubtreeIfNeeded()
            return sheet
        }
        var open: [Popup] = []
        try AppearanceSheet.render(to: dir, named: "changelog-popup-update") {
            let text = try String(contentsOf: ChangelogTests.repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
            let lines = UpdateNotice.lines(
                status: .available(Self.release), lastCheck: nil, lastError: nil,
                relay: .init(path: "/x/relay", installed: SemanticVersion("1.20.0")))
            let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: Changelog.parse(text), notices: lines))
            open.append(popup)
            let panel = try #require(popup.window)
            panel.setContentSize(ChangelogPopup.size)
            return try #require(panel.contentView)
        }
        try AppearanceSheet.render(to: dir, named: "banner-relaunch") {
            let banner = ReconnectingBanner(frame: NSRect(x: 0, y: 0, width: 420, height: 22))
            banner.setState(.action("updated · exit 0", label: "relaunch"))
            return banner
        }
        _ = open
    }
}
