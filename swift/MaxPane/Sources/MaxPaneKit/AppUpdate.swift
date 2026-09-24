import AppKit
import Foundation

/// Knowing that the tap has moved on, and doing something about it.
///
/// The version in the corner knows what this build is; nothing knew what the
/// newest release was, so a release was learnt of on GitHub, in a browser,
/// and the upgrade typed somewhere by hand — which the project's memory says
/// must never be a Claude-driven terminal, because a launch that inherits
/// its environment poisons every pane (`LocalSpawner.scrubClaudeMarkers`).
///
/// Four small things, each testable on its own (ADR-0038):
///
/// - `ReleaseFeed` reads GitHub's `releases/latest`; `UpdateStatus` compares
///   it with `CFBundleShortVersionString` by `SemanticVersion`.
/// - `UpdateChecker` runs that once a day and on Help › Check for Updates…,
///   with an `ETag`, and says one line in the log when the network is not
///   there. Never a dialog for a failure.
/// - `UpdatePlan` decides what Help › Update… runs: `update_command` from
///   the config file, else `brew upgrade --cask max-pane`, else the release
///   page in a web lane for a DMG install with no Homebrew.
/// - `Relaunch` is a detached `/bin/sh` that waits for this process to be
///   gone and `open -n`s the bundle again, started with a scrubbed, minimal
///   environment so nothing from this process — `CLAUDE*`, `ANTHROPIC*`,
///   the lot — reaches the new one.
///
/// Refused: Sparkle (a framework, a signing key and an appcast for what is
/// one HTTP GET), a background download (the upgrade is watched in a lane,
/// where its output is), and a silent relaunch (the strip is the owner's
/// desk; it goes away when he says).

// MARK: - the feed

/// One GitHub release, as much of it as the app reads.
public struct Release: Equatable, Sendable, Codable {
    /// `v0.8.0`, as tagged.
    public let tag: String
    /// The release's page, for the no-Homebrew path and for the popover.
    public let url: String
    public let name: String?
    /// `2026-09-30T18:04:11Z`, as GitHub writes it.
    public let publishedAt: String?

    public init(tag: String, url: String, name: String? = nil, publishedAt: String? = nil) {
        self.tag = tag
        self.url = url
        self.name = name
        self.publishedAt = publishedAt
    }

    /// The tag as a version, or nil for a tag that is not one.
    public var version: SemanticVersion? { SemanticVersion(tag) }
    /// `v0.8.0`, however the tag was spelled.
    public var label: String { version.map { "v\($0)" } ?? tag }
}

public enum ReleaseFeed {
    /// GitHub's "latest": the newest release that is neither a draft nor a
    /// prerelease. No auth; 60 requests an hour is more than a day needs.
    public static let url = URL(string: "https://api.github.com/repos/ddrscott/max-pane/releases/latest")!
    /// Where a person goes when the feed cannot say, or Homebrew is not here.
    public static let releasesPage = "https://github.com/ddrscott/max-pane/releases"

    /// The release in the feed's JSON, or nil for anything that is not one:
    /// a draft, a prerelease, a body with no `tag_name`, not JSON at all.
    public static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        return Release(
            tag: tag,
            url: object["html_url"] as? String ?? releasesPage,
            name: object["name"] as? String,
            publishedAt: object["published_at"] as? String)
    }
}

// MARK: - the comparison

/// What the check knows about this build against the feed.
public enum UpdateStatus: Equatable, Sendable {
    /// Never checked, or nothing usable has come back yet.
    case unknown
    /// The feed's newest is this build, or older than it (a build from main
    /// is ahead of the release; the corner's `+N` says so).
    case current(Release)
    /// Newer than this build: what `↻` shows.
    case available(Release)

    public var available: Release? {
        if case .available(let release) = self { return release }
        return nil
    }

    /// `installed` is `CFBundleShortVersionString`. A tag that is not a
    /// version cannot be newer than anything, and reads as current.
    public static func decide(installed: String, release: Release) -> UpdateStatus {
        guard let mine = SemanticVersion(installed), let theirs = release.version else { return .current(release) }
        return theirs > mine ? .available(release) : .current(release)
    }
}

// MARK: - the check

/// Once a day, and when asked. Everything that touches the network or the
/// clock comes in through the initialiser, so a test runs the whole thing
/// against a fake feed and never reaches api.github.com.
@MainActor
public final class UpdateChecker {
    /// What one GET returns: the body, the HTTP status, and the headers the
    /// check reads (`ETag`). A thrown error is "no network", said once.
    public struct Response: Sendable {
        public let status: Int
        public let body: Data
        public let etag: String?
        public init(status: Int, body: Data, etag: String? = nil) {
            self.status = status
            self.body = body
            self.etag = etag
        }
    }
    public typealias Fetch = @Sendable (URLRequest) async throws -> Response

    /// What survives a relaunch: when the feed was last read, the `ETag`
    /// it answered with, and the release it named. Kept in `UserDefaults`
    /// — it is a cache of someone else's fact, not state the ledger owns.
    public struct Memory: Equatable, Sendable, Codable {
        public var lastCheck: Date?
        public var etag: String?
        public var release: Release?
        public init(lastCheck: Date? = nil, etag: String? = nil, release: Release? = nil) {
            self.lastCheck = lastCheck
            self.etag = etag
            self.release = release
        }
    }

    /// A day. The feed changes a few times a month; the cost of being a day
    /// late is nothing, and the tap has to have moved before brew can.
    public static let interval: TimeInterval = 86_400
    /// How often the clock is looked at, so a day rolls over while the app
    /// stays open for a week.
    public static let tick: TimeInterval = 3_600

    public private(set) var status: UpdateStatus = .unknown
    /// The relay-tty reading from the same tick, nil until it has been taken.
    public private(set) var relay: RelayRequirement.Reading?
    public private(set) var lastCheck: Date?
    /// Why the last check came back with nothing, for the popover after a
    /// Help › Check for Updates… that could not; nil after one that could.
    public private(set) var lastError: String?
    /// How many times the feed was asked, for tests.
    public private(set) var fetchCount = 0
    /// Status, relay reading or error changed.
    public var onChange: (() -> Void)?

    private let installed: String
    private let fetch: Fetch
    private let now: () -> Date
    private let load: @MainActor () -> Memory?
    private let save: @MainActor (Memory) -> Void
    private let relayVersion: @Sendable () async -> RelayRequirement.Reading
    private var memory: Memory
    private var timer: Timer?
    private var inFlight = false

    public init(
        installed: String,
        fetch: @escaping Fetch = UpdateChecker.urlSession,
        now: @escaping () -> Date = Date.init,
        load: @escaping @MainActor () -> Memory? = UpdateChecker.loadDefaults,
        save: @escaping @MainActor (Memory) -> Void = UpdateChecker.saveDefaults,
        relayVersion: @escaping @Sendable () async -> RelayRequirement.Reading = RelayRequirement.readInstalled
    ) {
        self.installed = installed
        self.fetch = fetch
        self.now = now
        self.load = load
        self.save = save
        self.relayVersion = relayVersion
        memory = load() ?? Memory()
        lastCheck = memory.lastCheck
        // Yesterday's answer is this morning's until the feed says otherwise:
        // the `↻` is on screen from the first frame, not from the first tick.
        if let release = memory.release { status = UpdateStatus.decide(installed: installed, release: release) }
    }

    /// Whether a day has passed since the feed was last read.
    public var isDue: Bool {
        guard let lastCheck else { return true }
        return now().timeIntervalSince(lastCheck) >= Self.interval
    }

    /// Check now if it is due, and every hour from now on. Idempotent.
    public func start() {
        guard timer == nil else { return }
        Task { await self.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    public func checkIfDue() async {
        guard isDue else { return }
        await check()
    }

    /// Read the feed and relay-tty's version, whatever the clock says. One
    /// at a time: a second call while one is out is the same check.
    public func check() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        async let relayReading = relayVersion()

        var request = URLRequest(url: ReleaseFeed.url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("max-pane/\(installed)", forHTTPHeaderField: "User-Agent")
        if let etag = memory.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.timeoutInterval = 15
        fetchCount += 1
        let checkedAt = now()
        do {
            let response = try await fetch(request)
            switch response.status {
            case 304:
                // Nothing new since the ETag; what we remembered stands.
                lastError = nil
            case 200..<300:
                if let release = ReleaseFeed.parse(response.body) {
                    memory.release = release
                    memory.etag = response.etag
                    status = UpdateStatus.decide(installed: installed, release: release)
                    lastError = nil
                } else {
                    lastError = "the release feed had no release in it"
                    Log.warn("update check: \(lastError!)")
                }
            default:
                lastError = "the release feed answered \(response.status)"
                Log.warn("update check: \(lastError!)")
            }
        } catch {
            // Offline, a metered link, a captive portal: one line, no dialog,
            // and not again until tomorrow.
            lastError = "could not reach github.com"
            Log.warn("update check: \(lastError!) — \(error.localizedDescription)")
        }
        memory.lastCheck = checkedAt
        lastCheck = checkedAt
        save(memory)

        relay = await relayReading
        onChange?()
    }

    // MARK: defaults

    /// `URLSession.shared`, with caching off: the `ETag` is ours to send.
    public static let urlSession: Fetch = { request in
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return Response(
            status: http?.statusCode ?? 0, body: data,
            etag: http?.value(forHTTPHeaderField: "ETag"))
    }

    static let defaultsKey = "MaxPaneUpdateCheck"

    public static func loadDefaults() -> Memory? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Memory.self, from: data)
    }

    public static func saveDefaults(_ memory: Memory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - what Update… runs

/// What Help › Update… does on this machine.
public enum UpdatePlan: Equatable, Sendable {
    /// A shell line for a terminal lane, watched to its exit.
    case command(String)
    /// No way to run an upgrade here: the release page, in a web lane.
    case releasePage(String)

    /// The shipped path. `max-pane` is the cask's name once the tap is
    /// known, which `brew install --cask ddrscott/tap/max-pane` made it.
    public static let brewLine = "brew upgrade --cask max-pane"

    /// `update_command` wins outright; then Homebrew, if the login shell
    /// can find it; then the page, with the release's own when known.
    public static func decide(updateCommand: String?, brewOnPath: Bool, release: Release?) -> UpdatePlan {
        if let line = updateCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            return .command(line)
        }
        if brewOnPath { return .command(brewLine) }
        return .releasePage(release?.url ?? ReleaseFeed.releasesPage)
    }

    /// The one-line reason the release page opened instead of a lane.
    public static let noBrewNotice =
        "No Homebrew on this Mac's PATH and no update_command in config.toml, "
        + "so the release page is open in a lane: download the DMG from there and "
        + "drag Max Pane to Applications. Or set update_command in Settings."
}

// MARK: - relay-tty's version

/// README › Requirements: relay-tty 1.22.0 or newer, the release that added
/// agent state. An older one starts sessions fine and never says BLOCKED,
/// with nothing anywhere saying why — so the update tick asks `relay
/// --version` and the popover and the status bar name it when it is short.
public enum RelayRequirement {
    public static let minimum = SemanticVersion(parts: [1, 22, 0])

    public struct Reading: Equatable, Sendable {
        /// Where `relay` was found, or nil when it was not.
        public let path: String?
        /// What `--version` printed, as a version, or nil when it printed
        /// nothing that was one.
        public let installed: SemanticVersion?

        public init(path: String?, installed: SemanticVersion?) {
            self.path = path
            self.installed = installed
        }

        /// Found, answered, and older than the minimum. Not found is not
        /// short: the spawner says that, loudly, at the first lane.
        public var isShort: Bool {
            guard let installed else { return false }
            return installed < RelayRequirement.minimum
        }

        /// `relay-tty 1.20.0 is installed · 1.22.0 or newer is needed for BLOCKED`
        public var shortLine: String? {
            guard isShort, let installed else { return nil }
            return "relay-tty \(installed) is installed · \(RelayRequirement.minimum) or newer is needed for BLOCKED"
        }
    }

    /// The version in whatever `relay --version` printed: the first token
    /// that reads as one, so `relay-tty 1.22.0` and a bare `1.22.0` and a
    /// `v1.22.0` under an nvm banner all answer.
    public static func parse(_ output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: { $0.isWhitespace || $0 == "\n" }) {
            if let version = SemanticVersion(String(token)), version.parts.count == 3, token.contains(".") {
                return version
            }
        }
        return nil
    }

    /// Ask the installed `relay`. Off the main thread: it is a Node script
    /// under nvm on this machine and takes a few hundred milliseconds.
    public static let readInstalled: @Sendable () async -> Reading = {
        await Task.detached(priority: .utility) { () -> Reading in
            guard let relay = LocalSpawner.which("relay") else { return Reading(path: nil, installed: nil) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: relay)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return Reading(path: relay, installed: nil) }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return Reading(path: relay, installed: parse(String(decoding: data, as: UTF8.self)))
        }.value
    }
}

// MARK: - the lines the popover and the bar show

/// What the version popover says about updates, above the changelog. Pure,
/// so the wording is pinned by a test rather than read off a screenshot.
public enum UpdateNotice {
    public struct Line: Equatable, Sendable {
        public let text: String
        /// A click runs Help › Update…
        public let isAction: Bool
        public init(text: String, isAction: Bool = false) {
            self.text = text
            self.isAction = isAction
        }
    }

    /// `↻ v0.8.0` for the bar, or nil while there is nothing to say. With
    /// no release to name and relay-tty short, `↻ relay-tty 1.22.0`: the
    /// version to get to, with the tooltip and the popover saying why.
    public static func barText(_ status: UpdateStatus, relay: RelayRequirement.Reading? = nil) -> String? {
        if let release = status.available { return "↻ \(release.label)" }
        if relay?.isShort == true { return "↻ relay-tty \(RelayRequirement.minimum)" }
        return nil
    }

    /// The bar's tooltip, on the `↻`: the release and, when short, relay-tty.
    public static func barTooltip(_ status: UpdateStatus, relay: RelayRequirement.Reading?) -> String? {
        var lines: [String] = []
        if let release = status.available {
            lines.append("Max Pane \(release.label) is out. Click to update in a terminal lane (Help › Update…).")
        }
        if let short = relay?.shortLine { lines.append(short) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func lines(
        status: UpdateStatus, lastCheck: Date?, lastError: String?,
        relay: RelayRequirement.Reading?, now: Date = Date()
    ) -> [Line] {
        var out: [Line] = []
        switch status {
        case .available(let release):
            out.append(Line(text: "↻ \(release.label) is available · update…", isAction: true))
        case .current(let release):
            out.append(Line(text: "up to date · \(release.label) is the latest release" + checked(lastCheck, now: now)))
        case .unknown:
            if let lastError {
                out.append(Line(text: "\(lastError)" + checked(lastCheck, now: now)))
            } else {
                out.append(Line(text: "not checked for updates yet"))
            }
        }
        if let short = relay?.shortLine { out.append(Line(text: short)) }
        return out
    }

    /// ` · checked just now`, ` · checked 3 hours ago`, ` · checked 2 days ago`.
    static func checked(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let text: String
        if seconds < 90 { text = "just now" }
        else if seconds < 3_600 { text = "\(Int(seconds / 60)) min ago" }
        else if seconds < 2 * 86_400 {
            let h = Int(seconds / 3_600)
            text = h == 1 ? "1 hour ago" : "\(h) hours ago"
        } else { text = "\(Int(seconds / 86_400)) days ago" }
        return " · checked \(text)"
    }
}

// MARK: - relaunch

/// The new bundle, opened once this process is gone.
///
/// Not `NSWorkspace.open` from inside the app: the new instance would be
/// running beside the old one for the length of the quit, two windows on
/// one ledger. Not a launchd job: a plist for one `open` is a lot of
/// machinery. A `/bin/sh` that outlives this process, polls the pid, then
/// `open -n`s the same path — the bundle brew has just replaced.
///
/// **The environment is built, not inherited.** `open` hands its environment
/// to the app it launches, and this process may carry markers from wherever
/// it was launched: `CLAUDE_CODE_CHILD_SESSION` from a Claude session's Bash
/// tool, `ANTHROPIC_API_KEY` from an rc file. Every pane the new instance
/// spawned would inherit them, and a `claude` in one would believe itself a
/// nested child (project memory: never launch MaxPane from Claude). So the
/// helper starts with the eight variables a login needs and nothing else.
public enum Relaunch {
    /// Carried over from this process when present. `PATH` is not among
    /// them: it is set outright to the system's, below.
    public static let keptKeys = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
    ]
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// How long the helper waits for the old process before giving up
    /// without opening anything: a quit that hangs must not become a launch
    /// a minute later, behind whatever the owner is doing by then.
    public static let patience: TimeInterval = 60

    /// The helper's environment: the kept keys that `env` has, and `PATH`.
    public static func environment(from env: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in keptKeys {
            if let value = env[key], !value.isEmpty { out[key] = value }
        }
        out["PATH"] = path
        return out
    }

    /// The helper, as `sh -c` reads it: wait for `pid` to be gone (up to
    /// `patience`), then `open -n` the bundle. `exec`, so the helper is the
    /// `open` and leaves nothing behind.
    public static func script(pid: pid_t, bundle: String) -> String {
        let ticks = Int(patience / 0.2)
        return """
            i=0
            while kill -0 \(pid) 2>/dev/null; do
              i=$((i + 1))
              if [ "$i" -ge \(ticks) ]; then exit 1; fi
              sleep 0.2
            done
            exec open -n \(LocalSpawner.shellEscape(bundle))
            """
    }

    /// Start the helper. Detached with its stdio on `/dev/null`, so nothing
    /// ties it to this process; the caller then terminates the app.
    @discardableResult
    public static func spawnHelper(
        pid: pid_t = ProcessInfo.processInfo.processIdentifier,
        bundle: String = Bundle.main.bundleURL.path,
        environment: [String: String] = environment(from: ProcessInfo.processInfo.environment),
        shell: String = "/bin/sh"
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script(pid: pid, bundle: bundle)]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// The whole thing: the helper, then the quit. The quit goes through
    /// `NSApp.terminate`, so `applicationWillTerminate` flushes pane state
    /// as it does for ⌘Q.
    @MainActor
    public static func now() {
        do {
            try spawnHelper()
        } catch {
            Log.warn("relaunch: could not start the helper — \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
