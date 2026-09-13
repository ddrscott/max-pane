import Foundation
import Testing

@testable import MaxPaneKit

/// A profile has to isolate all five things or it isolates none of them: the
/// failures it exists to prevent — a test writing into the live strip, a CLI
/// driving the wrong instance, a throwaway login landing in the real cookie jar
/// — are each one path being left behind.
@Suite("Profile")
struct ProfileTests {
    @Test("no profile named is the default profile")
    func defaultIsDefault() {
        let (profile, complaint) = Profile.resolve(arguments: ["MaxPane"], environment: [:])
        #expect(complaint == nil)
        #expect(profile.name == Profile.defaultName)
        #expect(profile.isDefault)
    }

    @Test("--profile in either spelling, then MAXPANE_PROFILE")
    func selection() {
        #expect(Profile.resolve(arguments: ["MaxPane", "--profile", "test"], environment: [:]).profile.name == "test")
        #expect(Profile.resolve(arguments: ["MaxPane", "--profile=test"], environment: [:]).profile.name == "test")
        #expect(Profile.resolve(arguments: ["MaxPane"], environment: ["MAXPANE_PROFILE": "test"]).profile.name == "test")
        // The argument wins: it is the more specific of the two, and a stale
        // export in a shell must not quietly redirect a launch that said where
        // it wanted to go.
        let both = Profile.resolve(
            arguments: ["MaxPane", "--profile", "a"], environment: ["MAXPANE_PROFILE": "b"])
        #expect(both.profile.name == "a")
    }

    @Test("a name that would escape the profiles directory is refused, not scrubbed")
    func refusesBadNames() {
        // Scrubbing would resolve to the default profile, which is the live
        // strip — the exact place the caller was trying to stay out of.
        for bad in ["../../etc", "..", "", "with space", "a/b", String(repeating: "x", count: 33)] {
            let (_, complaint) = Profile.resolve(arguments: ["MaxPane", "--profile", bad], environment: [:])
            #expect(complaint != nil, "expected \"\(bad)\" to be refused")
        }
        #expect(Profile.complaint(about: "gauntlet-p1.2_x") == nil)
        #expect(Profile.resolve(arguments: ["MaxPane", "--profile"], environment: [:]).complaint != nil)
    }

    @Test("every path a profile owns moves with it")
    func pathsAreDisjoint() {
        let live = Profile()
        let test = Profile(name: "test")
        #expect(live.supportDirectory != test.supportDirectory)
        #expect(live.configDirectory != test.configDirectory)
        #expect(live.snapshotsDirectory != test.snapshotsDirectory)
        // Both under profiles/, the default included: a layout where the
        // default is the parent would put every other profile inside it.
        #expect(live.supportDirectory.path.hasSuffix("/MaxPane/profiles/default"))
        #expect(test.supportDirectory.path.hasSuffix("/MaxPane/profiles/test"))
    }

    @Test("a profile socket path fits in sun_path")
    func socketFits() {
        // 104 bytes on Darwin. Over it, `bind` fails at launch and the only
        // symptom the CLI can report is "max pane not listening".
        let longest = Profile(name: String(repeating: "x", count: Profile.maximumNameLength))
        #expect(longest.socketPath.utf8.count < 104)
    }

    @Test("the default profile's cookie jars are exactly the ones it already has")
    @MainActor
    func defaultSaltIsEmpty() {
        // WebKit keys the on-disk store by this UUID. Salting the default
        // profile would point it at new empty stores, and every login on the
        // machine would be gone with nothing to restore from.
        #expect(Profile().ownDataSalt.isEmpty)
        #expect(DataStorePool.uuid(for: Profile().ownDataSalt + DataStorePool.defaultShardId)
            == DataStorePool.uuid(for: DataStorePool.defaultShardId))
    }

    @Test("a named profile cannot reach the default profile's logins")
    @MainActor
    func namedSaltIsSeparate() {
        let test = Profile(name: "test")
        #expect(!test.ownDataSalt.isEmpty)
        for shard in ["shard-0", "shard-1", "shard-2"] {
            #expect(DataStorePool.uuid(for: test.ownDataSalt + shard)
                != DataStorePool.uuid(for: Profile().ownDataSalt + shard))
        }
        // And two named profiles cannot reach each other's.
        #expect(DataStorePool.uuid(for: Profile(name: "a").ownDataSalt + "shard-0")
            != DataStorePool.uuid(for: Profile(name: "b").ownDataSalt + "shard-0"))
    }

    @Test("a path in a dot-command survives a quote in it")
    func quoting() {
        #expect(Profile.sqlQuoted("/tmp/o'brien/ledger.db") == "/tmp/o''brien/ledger.db")
    }
}

/// The migration runs once, on his machine, over the strip he works in. These
/// tests are the only place it is ever exercised before that.
@Suite("moving the pre-profiles layout under profiles/")
@MainActor
struct ProfileMigrationTests {
    /// A real ledger, built through the real core, so the schema and the row
    /// counts are the ones the migration will actually meet.
    private func legacyRoot(lanes: Int) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try StripStore(ledgerPath: root.appendingPathComponent("ledger.db").path)
        for i in 0..<lanes { try store.newWebLane(url: "https://lane\(i)", near: nil) }
        return root
    }

    @Test("the strip is the same strip afterwards, and the original is kept")
    func migratesAndVerifies() throws {
        let support = try legacyRoot(lanes: 4)
        let config = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-config-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: config)
        }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try #"{"laneDefaultPt": 700}"#.write(
            to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let snapshots = support.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data([0xff]).write(to: snapshots.appendingPathComponent("pane.jpg"))

        try Profile.migrate(support: support, configRoot: config)

        let moved = support.appendingPathComponent("profiles/default")
        let reopened = try StripStore(ledgerPath: moved.appendingPathComponent("ledger.db").path)
        #expect(reopened.state.lanes.count == 4)
        #expect(reopened.state.lanes.compactMap { $0.panes.first?.url }
            == (0..<4).map { "https://lane\($0)" })

        let fm = FileManager.default
        // The original is the backup, and it is still there.
        #expect(fm.fileExists(atPath: support.appendingPathComponent("ledger.db.pre-profiles").path))
        #expect(!fm.fileExists(atPath: support.appendingPathComponent("ledger.db").path))
        #expect(fm.fileExists(atPath: config.appendingPathComponent("profiles/default/config.json").path))
        #expect(!fm.fileExists(atPath: config.appendingPathComponent("config.json").path))
        #expect(fm.fileExists(atPath: moved.appendingPathComponent("snapshots/pane.jpg").path))
    }

    @Test("running it twice does not touch what the first run produced")
    func isIdempotent() throws {
        let support = try legacyRoot(lanes: 2)
        let config = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-config-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: config)
        }
        try Profile.migrate(support: support, configRoot: config)
        // The second run meets a ledger already at the new path. It must not
        // overwrite it with the set-aside original, which by then is stale by
        // however long the app has been running on the new one.
        let moved = support.appendingPathComponent("profiles/default/ledger.db")
        let store = try StripStore(ledgerPath: moved.path)
        try store.newWebLane(url: "https://after", near: nil)

        try Profile.migrate(support: support, configRoot: config)
        #expect(try StripStore(ledgerPath: moved.path).state.lanes.count == 3)
    }

    @Test("a machine that never ran the old layout has nothing to do")
    func nothingToMigrate() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-fresh-\(UUID().uuidString)", isDirectory: true)
        let config = support.appendingPathComponent("config", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Profile.migrate(support: support, configRoot: config)
        #expect(!FileManager.default.fileExists(
            atPath: support.appendingPathComponent("profiles/default/ledger.db").path))
    }

    @Test("a zero-byte ledger is treated as absent, not as a reason to refuse to start")
    func emptyLedgerIsSkipped() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data().write(to: support.appendingPathComponent("ledger.db"))
        // `.backup` would fail on it, and an app that will not launch until
        // someone deletes a 0-byte file is worse than one that ignores it.
        try Profile.migrate(support: support, configRoot: support)
    }
}

/// The guard that keeps the migration off a ledger someone else has open.
@Suite("is something listening there")
struct ListeningProbeTests {
    /// Under `/tmp`, not `NSTemporaryDirectory()`. The per-process temporary
    /// directory is a ~50-character path under `/var/folders`, and a socket
    /// bound below it does not fit in `sun_path`'s 104 bytes.
    private func shortDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/mp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a path with nothing at it, and a plain file, are both not listening")
    func absentAndStale() throws {
        let dir = try shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!Profile.isListening(at: dir.appendingPathComponent("nothing.sock").path))
        // A socket file left behind by a `kill -9` is the case that must read as
        // free: treating it as occupied would block the migration forever.
        let stale = dir.appendingPathComponent("stale.sock")
        try Data().write(to: stale)
        #expect(!Profile.isListening(at: stale.path))
    }

    @Test("a socket with a listener on it is listening")
    func present() throws {
        let dir = try shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A bare socket rather than an `OpenServer`: the probe asks whether
        // anything is on the other end, not who.
        let path = dir.appendingPathComponent("live.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        #expect(Profile.isListening(at: path))
    }
}
