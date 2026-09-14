import Foundation

/// Which set of state a launch runs against: its ledger, its config, its cookie
/// jars, its control socket, its snapshots.
///
/// One argument instead of five. Isolating an instance used to mean setting
/// `MAXPANE_LEDGER`, `MAXPANE_SOCKET`, `MAXPANE_CONFIG` and `MAXPANE_DATA_SALT`
/// consistently, and every omission failed differently and in silence: no
/// socket and the CLI drove whichever instance held the default path, no salt
/// and the throwaway instance derived *exactly* the cookie-jar UUIDs the real
/// one uses, no ledger and the test wrote into the strip someone was working
/// in. Five chances to get it wrong per launch, and no feedback when you did.
///
/// The four variables still win where they are set, so `scripts/test.sh` and
/// anything else that points one path somewhere keeps working. What changed is
/// that getting isolation right no longer requires remembering all of them.
public struct Profile: Sendable, Equatable {
    /// The profile a launch with no `--profile` gets — the one he is working in.
    public static let defaultName = "default"

    public let name: String

    public init(name: String = Profile.defaultName) { self.name = name }

    public var isDefault: Bool { name == Self.defaultName }

    // MARK: - naming

    /// Names go into a directory path and into a `sockaddr_un`, whose `sun_path`
    /// is 104 bytes on Darwin. The default profile's socket already spends 77 of
    /// them, so a name is capped well short of what a filesystem would take:
    /// past that, `bind` fails at launch and the CLI's only symptom is "max pane
    /// not listening".
    public static let maximumNameLength = 32

    /// Why this name cannot be a profile, or nil if it can be.
    ///
    /// Rejecting rather than sanitising is the point. A name that is quietly
    /// rewritten — `../../` scrubbed to `default`, say — puts the launch you
    /// meant to isolate back on the live strip, which is the failure this whole
    /// change exists to remove.
    public static func complaint(about name: String) -> String? {
        if name.isEmpty { return "a profile name cannot be empty" }
        if name.count > maximumNameLength {
            return "a profile name is at most \(maximumNameLength) characters (\"\(name)\" is \(name.count))"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "a profile name may only contain letters, digits, '.', '_' and '-' (got \"\(name)\")"
        }
        if name == "." || name == ".." { return "\"\(name)\" is not a profile name" }
        return nil
    }

    // MARK: - selection

    /// `--profile <name>`, `--profile=<name>`, then `MAXPANE_PROFILE`, then the
    /// default. The same three rules the Rust CLI applies, so `maxpane
    /// --profile test ls` reaches the instance launched with `--profile test`.
    ///
    /// Returns a complaint instead of throwing so the caller can decide what to
    /// do about it; the app stops, because continuing means running against
    /// *some* profile and the whole value here is knowing which.
    public static func resolve(
        arguments: [String], environment: [String: String]
    ) -> (profile: Profile, complaint: String?) {
        var named: String?
        var i = arguments.startIndex
        while i < arguments.endIndex {
            let arg = arguments[i]
            if arg == "--profile" {
                guard i + 1 < arguments.endIndex else {
                    return (Profile(), "--profile needs a name")
                }
                named = arguments[i + 1]
                i += 2
                continue
            }
            if arg.hasPrefix("--profile=") {
                named = String(arg.dropFirst("--profile=".count))
            }
            i += 1
        }
        let chosen = named ?? environment["MAXPANE_PROFILE"]
        guard let chosen, chosen != defaultName else { return (Profile(), nil) }
        if let complaint = complaint(about: chosen) { return (Profile(), complaint) }
        return (Profile(name: chosen), nil)
    }

    private static let resolution = resolve(
        arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    /// The profile this process is running as.
    public static var current: Profile { resolution.profile }

    /// Why the profile asked for on the command line was refused, if it was.
    /// Non-nil means the process must not touch any of these paths: it asked for
    /// isolation and did not get it.
    public static var currentComplaint: String? { resolution.complaint }

    // MARK: - paths

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxPane", isDirectory: true)
    }

    /// `~/Library/Application Support/MaxPane/profiles/<name>`.
    ///
    /// The default profile lives under `profiles/` too. A layout where the
    /// default is the parent directory and everything else is a child reads
    /// fine and behaves badly — `profiles/` would then be inside the default
    /// profile's own state, so a sweep of one profile's directory would take
    /// the others with it.
    public var supportDirectory: URL {
        Profile.applicationSupport
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// `$XDG_CONFIG_HOME/maxpane` for the default profile, and
    /// `…/maxpane/profiles/<name>` for any other.
    ///
    /// Under the config directory rather than Application Support because a
    /// person edits what is in it. The default profile's file is at the top,
    /// where anyone looking for a Unix program's config looks first; the
    /// others are under `profiles/`, so a test instance still cannot read or
    /// write the one someone is working with.
    public var configDirectory: URL { configDirectory(root: Profile.configRoot) }

    func configDirectory(root: URL) -> URL {
        guard !isDefault else { return root }
        return root
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static var configRoot: URL {
        configRoot(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `$XDG_CONFIG_HOME/maxpane`, or `~/.config/maxpane` when it is unset.
    ///
    /// The XDG spec says a relative `XDG_CONFIG_HOME` is invalid and is to be
    /// ignored, so an empty or relative one falls back like an unset one. An app
    /// opened from the Dock inherits launchd's environment rather than a shell's,
    /// so there it is usually unset, and the fallback is the answer.
    static func configRoot(environment: [String: String], home: URL) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"].map({ ($0 as NSString).expandingTildeInPath }),
           xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("maxpane", isDirectory: true)
        }
        return home.appendingPathComponent(".config/maxpane", isDirectory: true)
    }

    /// Where `config.json` was always written: `~/.config`, whatever
    /// `XDG_CONFIG_HOME` says, because the code that wrote it never asked.
    static var legacyConfigRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/maxpane", isDirectory: true)
    }

    /// This profile's old `config.json`, which `ConfigFile.migrate` copies from
    /// and leaves in place.
    public var legacyConfigPath: URL { legacyConfigPath(root: Profile.legacyConfigRoot) }

    func legacyConfigPath(root: URL) -> URL {
        root.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// True when `MAXPANE_CONFIG` names the file, and nothing is to be migrated
    /// into it: a path someone pointed somewhere is theirs.
    public static var configIsOverridden: Bool {
        ProcessInfo.processInfo.environment["MAXPANE_CONFIG"] != nil
    }

    public var snapshotsDirectory: URL {
        supportDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    /// Create the directories these paths name. Called once at launch.
    ///
    /// Deliberately not done inside the accessors. A property that reads as a
    /// path and silently makes a directory is a property no test can ask a
    /// question of without leaving something behind in the real Application
    /// Support — and this file's whole job is being able to check, cheaply,
    /// that one profile cannot reach another's state.
    public func prepareDirectories() {
        let fm = FileManager.default
        for dir in [supportDirectory, snapshotsDirectory, configDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The ledger. PRD §6.
    public var ledgerPath: String {
        if let override = ProcessInfo.processInfo.environment["MAXPANE_LEDGER"] { return override }
        return supportDirectory.appendingPathComponent("ledger.db").path
    }

    /// The control socket `maxpane` connects to.
    public var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["MAXPANE_SOCKET"] { return override }
        return supportDirectory.appendingPathComponent("open.sock").path
    }

    public var configPath: URL {
        if let override = ProcessInfo.processInfo.environment["MAXPANE_CONFIG"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return configDirectory.appendingPathComponent("config.toml")
    }

    /// What `DataStorePool` mixes into a shard's UUID so two profiles cannot
    /// share a cookie jar.
    public var dataSalt: String {
        ProcessInfo.processInfo.environment["MAXPANE_DATA_SALT"] ?? ownDataSalt
    }

    /// The salt the profile derives for itself, before `MAXPANE_DATA_SALT` has
    /// a say. Split out because `scripts/test.sh` exports that variable for
    /// every Swift test, so a test reading `dataSalt` would be measuring the
    /// harness rather than the profile.
    ///
    /// **The default profile's salt is empty, and has to stay that way.** The
    /// UUID is derived from `salt + shardId` and WebKit keys the on-disk store
    /// by it, so giving the default profile a salt of `"default"` would point
    /// it at brand new empty stores and every login on the machine would be
    /// gone with nothing to restore from.
    var ownDataSalt: String { isDefault ? "" : "profile.\(name)." }

    // MARK: - migration

    /// Where the ledger lived before profiles existed, and where it stays if
    /// the migration refuses to believe its own copy.
    static var legacyLedger: URL { applicationSupport.appendingPathComponent("ledger.db") }

    public enum MigrationError: LocalizedError {
        case sqliteFailed(String)
        case countsDisagree(before: String, after: String)
        case anotherInstanceHasIt(String)

        public var errorDescription: String? {
            switch self {
            case .sqliteFailed(let detail):
                return "Could not copy the ledger into the default profile: \(detail)"
            case .countsDisagree(let before, let after):
                return """
                    The copy of the ledger does not match the original \
                    (\(before) before, \(after) after). Nothing was moved; the original \
                    is untouched at \(Profile.legacyLedger.path).
                    """
            case .anotherInstanceHasIt(let socket):
                return """
                    Another Max Pane is already running on this ledger \
                    (it is listening at \(socket)). Quit it and launch again: moving the \
                    ledger while it is open would leave that instance writing to a file \
                    nothing reads any more.
                    """
            }
        }
    }

    /// Whether something is listening on a Unix socket at this path.
    ///
    /// The one hazard the count check cannot see. A build from before profiles
    /// existed keeps the ledger open at the old path, and renaming a file out
    /// from under SQLite does not fail — the open descriptor follows the inode,
    /// so the old instance goes on committing lanes into what is now the backup
    /// and every one of them is invisible in the profile. A stale socket file
    /// left by a crash refuses the connection, which is the difference that
    /// matters here.
    static func isListening(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return connected == 0
    }

    /// Move the pre-profiles layout into `profiles/default/`, once.
    ///
    /// Call before anything opens a path. A no-op on a machine that never ran
    /// the old layout, and a no-op the second time.
    ///
    /// The ledger is copied with `sqlite3 .backup` rather than `cp`, because a
    /// SQLite database in WAL mode is not one file: the one time it mattered
    /// the `-wal` held 4 MB of committed lanes, and a file copy would have
    /// produced a strip missing everything from the last checkpoint on.
    /// `.backup` checkpoints into the destination, so the result is a single
    /// complete file.
    ///
    /// Verification is lane and pane counts, because those are what a person
    /// would notice and what the failure mode actually looks like. On any
    /// disagreement the copy is deleted and the original is left exactly where
    /// it was, so the recovery is to launch an older build.
    public static func migrateLegacyLayout() throws {
        // The legacy root, not `configRoot`: this moves a `config.json` that was
        // only ever written under `~/.config`.
        try migrate(support: applicationSupport, configRoot: legacyConfigRoot)
    }

    /// The two roots are parameters so this can be proved against a directory
    /// in `/tmp` rather than against the one ledger on the machine that must
    /// not be experimented on.
    static func migrate(support: URL, configRoot: URL) throws {
        let fm = FileManager.default
        let profiles = support.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(defaultName, isDirectory: true)

        // Config first: a rename, so there is no window in which the file
        // exists in both places and no copy to reconcile if this is
        // interrupted.
        let oldConfig = configRoot.appendingPathComponent("config.json")
        let newConfig = configRoot.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(defaultName, isDirectory: true)
            .appendingPathComponent("config.json")
        if fm.fileExists(atPath: oldConfig.path), !fm.fileExists(atPath: newConfig.path) {
            try? fm.createDirectory(
                at: newConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldConfig, to: newConfig)
        }

        let oldLedger = support.appendingPathComponent("ledger.db")
        let newLedger = profiles.appendingPathComponent("ledger.db")
        guard fm.fileExists(atPath: oldLedger.path), !fm.fileExists(atPath: newLedger.path)
        else { return }
        // A zero-byte file is what a crashed first launch leaves behind. There
        // is nothing in it to lose and `.backup` would fail on it, so treat it
        // as absent rather than as a reason to refuse to start.
        let size = (try? fm.attributesOfItem(atPath: oldLedger.path)[.size] as? UInt64) ?? nil
        guard (size ?? 0) > 0 else { return }

        let oldSocket = support.appendingPathComponent("open.sock").path
        if isListening(at: oldSocket) { throw MigrationError.anotherInstanceHasIt(oldSocket) }

        try fm.createDirectory(at: profiles, withIntermediateDirectories: true)
        try sqlite(oldLedger, ".backup '\(sqlQuoted(newLedger.path))'")

        let before = try counts(of: oldLedger)
        let after = try counts(of: newLedger)
        guard before == after else {
            try? fm.removeItem(at: newLedger)
            throw MigrationError.countsDisagree(before: before, after: after)
        }

        // The original *is* the backup. Set aside rather than deleted, and
        // named for what it is, so recovering is a rename and not a restore.
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: oldLedger.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(
                at: from, to: URL(fileURLWithPath: oldLedger.path + ".pre-profiles" + suffix))
        }

        // Snapshots last and best-effort. A pane row holds the absolute path of
        // its snapshot, so moving the directory orphans the ones on disk — but
        // an orphaned snapshot is a dimmed panel with the URL on it, which is
        // exactly what a pane with no snapshot to take already shows. Leaving
        // them behind instead would put the default profile's thumbnails where
        // a second profile would write its own.
        let oldSnapshots = support.appendingPathComponent("snapshots", isDirectory: true)
        let newSnapshots = profiles.appendingPathComponent("snapshots", isDirectory: true)
        if fm.fileExists(atPath: oldSnapshots.path), !fm.fileExists(atPath: newSnapshots.path) {
            try? fm.moveItem(at: oldSnapshots, to: newSnapshots)
        }
    }

    /// `lane` and `pane` counts, as one line, read with the `sqlite3` binary so
    /// the original is never opened by anything that could migrate its schema.
    private static func counts(of db: URL) throws -> String {
        try sqlite(db, "select (select count(*) from lane) || ' lanes, ' "
            + "|| (select count(*) from pane) || ' panes';")
    }

    @discardableResult
    private static func sqlite(_ db: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            throw MigrationError.sqliteFailed("\(error)")
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MigrationError.sqliteFailed(
                String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sqlQuoted(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "''")
    }
}
