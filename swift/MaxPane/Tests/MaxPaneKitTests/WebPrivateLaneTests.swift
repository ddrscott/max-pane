import AppKit
import LanedCore
import Testing
import WebKit
@testable import MaxPaneKit

/// A private lane (⇧⌘N): one non-persistent cookie jar per lane, shared with
/// the siblings it ⌘-clicks open, dropped when the last of them closes, and
/// nothing about its pages in the ledger — proven on the ledger, the pool and
/// the header model here, and on a real page in `WebPrivateLaneWebKitTests`.
@Suite("private lanes")
@MainActor
struct WebPrivateLaneTests {
    @Test("⇧⌘N is the key, under File, and a private lane is born knowing its jar")
    func commandAndBirth() throws {
        let chord = try #require(Command.newPrivateWebLane.defaultShortcut)
        #expect(chord.0 == "n" && chord.1 == [.command, .shift])
        #expect(Command.newPrivateWebLane.menu == .file)

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: "https://docs.example/", near: nil)
        try store.newWebLane(url: "about:blank", near: store.state.lanes[0].id, private: true)
        let lane = try #require(store.state.lanes.last)
        #expect(lane.isPrivate)
        #expect(!store.state.lanes[0].isPrivate)
        let pane = try #require(lane.panes.first)
        #expect(pane.dataStoreId == DataStorePool.privateId(forLane: lane.id))
        #expect(LaneHeaderModel(lane: lane, telemetry: nil).isPrivate)
        #expect(!LaneHeaderModel(lane: store.state.lanes[0], telemetry: nil).isPrivate)
    }

    @Test("the pool hands a private jar a non-persistent store, one per jar, and releases it with the lane")
    func poolReleasesOnClose() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: "about:blank", near: nil, private: true)
        let opener = try #require(store.state.lanes.first)
        let jar = try #require(opener.panes.first?.dataStoreId)

        let pool = DataStorePool.shared
        let dataStore = pool.store(jar)
        #expect(!dataStore.isPersistent)
        #expect(pool.store(jar) === dataStore, "a second ask must be the same jar or the lane's cookies split")
        #expect(pool.store(jar) !== pool.store(DataStorePool.defaultShardId))
        #expect(pool.holdsPrivateStore(jar))

        // A ⌘-click sibling joins the opener's jar rather than getting its own.
        try store.newWebLane(url: "https://mail.example/thread", near: opener.id, private: true, sharingJarWith: jar)
        let sibling = try #require(store.state.lanes.last)
        #expect(sibling.id != opener.id && sibling.isPrivate)
        #expect(sibling.panes.first?.dataStoreId == jar)
        #expect(pool.store(jar) === dataStore)

        // Closing the opener is not the end of the jar while the sibling stands.
        try store.closeLane(opener.id)
        #expect(pool.holdsPrivateStore(jar))
        // Closing the last lane in it is.
        try store.closeLane(sibling.id)
        #expect(!pool.holdsPrivateStore(jar))
        // And asking again is a fresh, empty jar, not the old one back.
        #expect(pool.store(jar) !== dataStore)
        pool.releasePrivateStore(jar)
    }

    @Test("a relaunch has never heard of a private lane")
    func relaunchForgets() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ledger.db").path
        do {
            let store = try StripStore(ledgerPath: path)
            try store.newWebLane(url: "https://docs.example/", near: nil)
            try store.newWebLane(url: "https://mail.example/", near: nil, private: true)
            #expect(store.state.lanes.count == 2)
            // Left open: the case a quit with the lane up, or a `kill -9`, leaves.
        }
        let store = try StripStore(ledgerPath: path)
        #expect(store.state.lanes.map(\.isPrivate) == [false])
        #expect(store.state.lanes.first?.panes.first?.url == "https://docs.example/")
        #expect(store.allLanes.count == 1)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The same lane with a real page in it: the web view is on the pool's
/// non-persistent store, the chip is on the bar, and a finished load leaves no
/// visit and no session blob behind. Skips itself without a named profile,
/// like every suite that builds a `WebPaneController`.
@Suite("private lanes, in real WebKit", .serialized)
@MainActor
struct WebPrivateLaneWebKitTests {
    @Test("a private page loads on a non-persistent store, wears the chip, and records nothing")
    func nothingRecorded() async throws {
        try await PrivateFixture.with { f in
            let web = try #require(f.controller.webView)
            #expect(!web.configuration.websiteDataStore.isPersistent)
            #expect(web.configuration.websiteDataStore === DataStorePool.shared.store(f.controller.dataStoreId))
            #expect(f.controller.isPrivate)
            #expect(f.controller.chrome.isPrivateChipShown)
            #expect(await f.ready())
            // The title landed on the lane — a private lane is still a lane
            // you have to find on the strip — but not in history.
            #expect(await f.eventually { f.store.lane(f.lane.id)?.title == "private page" })
            f.controller.flushState()
            #expect(f.store.history("", limit: 10).isEmpty, "a private visit landed in history")
            #expect(f.store.history("private", limit: 10).isEmpty)
            #expect(f.store.paneSession(f.pane.id) == nil, "a private pane wrote its session blob")
            // The same page from a public lane would be a visit, so the
            // silence above is the lane's and not the recorder's.
            f.store.recordVisit(paneId: f.pane.id, url: f.site.origin + "/page", title: "private page")
            #expect(f.store.history("", limit: 10).isEmpty, "the core recorded a visit from a private pane")
        }
    }

    @Test("a lane opened from a private page is private, in the same jar")
    func siblingSharesJar() async throws {
        try await PrivateFixture.with { f in
            #expect(await f.ready())
            f.controller.openLane(f.site.origin + "/other")
            let lanes = f.store.state.lanes
            #expect(lanes.count == 2)
            let sibling = try #require(lanes.last)
            #expect(sibling.id != f.lane.id)
            #expect(sibling.isPrivate)
            #expect(sibling.panes.first?.url == f.site.origin + "/other")
            #expect(sibling.panes.first?.dataStoreId == f.controller.dataStoreId)
        }
    }
}

@MainActor
private final class PrivateFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let lane: Lane
    let pane: Pane
    let controller: WebPaneController
    let window: NSWindow

    static func with(_ body: (PrivateFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED private lanes in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await PrivateFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        site = try await LocalSite(pages: [
            "/page": "<!doctype html><title>private page</title><p>nobody saw this</p>",
            "/other": "<!doctype html><title>other</title><p>or this</p>",
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-private-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: site.origin + "/page", near: nil, private: true)
        lane = try #require(store.state.lanes.first)
        pane = try #require(lane.panes.first)
        controller = WebPaneController(
            pane: pane, lane: lane, store: store, config: Config(),
            blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        window.contentView?.addSubview(controller.view)
    }

    func js(_ script: String) async -> Any? {
        guard let web = controller.webView else { return nil }
        return try? await web.evaluateJavaScript(script)
    }

    func ready() async -> Bool {
        await eventually { await js("document.readyState === 'complete' ? 1 : 0") as? Int == 1 }
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}
