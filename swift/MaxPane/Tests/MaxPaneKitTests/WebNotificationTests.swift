import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// The Notification API, proven in real WebKit rather than argued.
///
/// WebKit has no `window.Notification` on macOS, so everything a page sees of
/// it here is the shim's, and "Slack can notify" is a claim about a promise
/// settling with the right word, a constructor reaching the centre with the
/// right title, and a click finding its way back to the page's handler. A
/// loopback site serves the page, as `WebPopupDialogTests` does; the centre
/// posts into a recorder rather than `UNUserNotificationCenter`, which traps in
/// a process that is not an app bundle; and the sheet is answered through the
/// method its buttons call.
@Suite("web notifications, in real WebKit", .serialized)
@MainActor
struct WebNotificationTests {
    @Test("permission is default; a dismissed ask stays default; a remembered BLOCK is denied and survives a reload")
    func deniedIsRemembered() async throws {
        try await NotificationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            // The shape Slack's and Gmail's feature detection reads.
            #expect(await f.js(web, "shape()") as? String == "true,true,true")
            #expect(await f.js(web, "perm()") as? String == "default")

            // Esc: the promise settles `default`, nothing is remembered, and
            // the page may ask again.
            #expect(await f.js(web, "ask()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            #expect(f.controller.isAsking)
            f.controller.finishAsk(with: .cancelled)
            #expect(await f.eventually { await f.events(web).contains("perm:default") })
            #expect(await f.events(web).contains("promise:true"))
            #expect(await f.js(web, "perm()") as? String == "default")
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .notifications) == nil)

            // BLOCK with the box ticked: denied, in the ledger under this jar.
            #expect(await f.js(web, "ask()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .capture(allowed: false, remember: true))
            #expect(await f.eventually { await f.events(web).contains("perm:denied") })
            #expect(await f.js(web, "perm()") as? String == "denied")
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .notifications) == false)
            #expect(f.recorder.authorizations == 0)

            // A reload reads the answer from the script, before the page runs,
            // and asking again is answered without a sheet.
            try await f.reload(web)
            #expect(await f.js(web, "perm()") as? String == "denied")
            #expect(await f.js(web, "ask()") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("perm:denied") })
            #expect(f.controller.askSheet == nil)

            // And a `new Notification()` on a denied origin is an error, not a post.
            #expect(await f.js(web, "notify('Nope', 'x', '')") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("error:Nope") })
            #expect(f.recorder.posted.isEmpty)
        }
    }

    @Test("a remembered ALLOW asks macOS once; a notification reaches the centre; a click brings the pane forward and reaches the page")
    func grantedRoundTrip() async throws {
        try await NotificationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)

            #expect(await f.js(web, "ask()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .capture(allowed: true, remember: true))
            #expect(await f.eventually { await f.events(web).contains("perm:granted") })
            #expect(await f.js(web, "perm()") as? String == "granted")
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .notifications) == true)
            // macOS is asked at the first grant, and only then.
            #expect(f.recorder.authorizations == 1)

            // The callback form, answered from the script's own state.
            #expect(await f.js(web, "askCb()") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("cb:granted") })
            #expect(f.controller.askSheet == nil)

            try await f.reload(web)
            #expect(await f.js(web, "perm()") as? String == "granted")
            #expect(f.recorder.authorizations == 1)

            // Posted: the site's title and body, the icon dropped because the
            // site has none at that address.
            #expect(await f.js(web, "notify('Hello', 'World', 'thread-1')") as? Int == 1)
            #expect(await f.eventually { f.recorder.posted.count == 1 })
            let first = try #require(f.recorder.posted.first)
            #expect(first.title == "Hello" && first.body == "World" && first.icon == nil)
            #expect(first.identifier.hasSuffix(".tag.thread-1"))
            #expect(await f.eventually { await f.events(web).contains("show:Hello") })
            #expect(f.center.posted[first.identifier] != nil)

            // The click: the app is asked forward, the pane is focused, and
            // the page's handler runs.
            #expect(f.store.state.focusedPaneId == f.otherPaneId)
            f.center.activated(identifier: first.identifier)
            #expect(f.activations == 1)
            #expect(f.store.state.focusedPaneId == f.controller.paneId)
            #expect(await f.eventually { await f.events(web).contains("click:Hello") })
            #expect(await f.eventually { await f.events(web).contains("close:Hello") })
            #expect(f.center.posted.isEmpty)

            // The same tag replaces: the replaced object hears `close`, and
            // the centre holds one identifier for both.
            #expect(await f.js(web, "notify('Again', 'x', 'thread-1')") as? Int == 1)
            #expect(await f.eventually { f.recorder.posted.count == 2 })
            #expect(await f.js(web, "notify('Third', 'y', 'thread-1')") as? Int == 1)
            #expect(await f.eventually { f.recorder.posted.count == 3 })
            #expect(f.recorder.posted[1].identifier == f.recorder.posted[2].identifier)
            #expect(await f.eventually { await f.events(web).contains("close:Again") })
            #expect(f.center.posted.count == 1)

            // The page's `close()` takes it down.
            #expect(await f.js(web, "closeLast()") as? Int == 1)
            #expect(await f.eventually { f.recorder.removed == [first.identifier] })
            #expect(await f.eventually { await f.events(web).contains("close:Third") })
            #expect(f.center.posted.isEmpty)

            // A banner for a pane that has since closed is a no-op.
            #expect(await f.js(web, "notify('Late', 'z', '')") as? Int == 1)
            #expect(await f.eventually { f.recorder.posted.count == 4 })
            let late = f.recorder.posted[3].identifier
            f.controller.tearDown()
            f.center.activated(identifier: late)
            #expect(f.activations == 1)
            #expect(f.center.posted.isEmpty)
            f.center.activated(identifier: "maxpane.nobody")
        }
    }
}

/// The parts of the shim that need no WebKit.
@Suite("notification messages and scripts")
struct WebNotificationScriptTests {
    @Test("what a page sends is read back as a message, and junk is not")
    func messages() {
        #expect(WebNotifications.message(["type": "request", "id": 3]) == .request(id: 3))
        #expect(WebNotifications.message([
            "type": "show", "id": 4, "title": "Hi", "body": "there", "icon": "https://a.example/i.png", "tag": "t",
        ]) == .show(id: 4, title: "Hi", body: "there", icon: URL(string: "https://a.example/i.png"), tag: "t"))
        // An empty tag is no tag, and a non-http icon is no icon.
        #expect(WebNotifications.message(["type": "show", "id": 5, "title": "x", "icon": "data:image/png;base64,AAAA", "tag": ""])
            == .show(id: 5, title: "x", body: "", icon: nil, tag: nil))
        #expect(WebNotifications.message(["type": "close", "id": 6]) == .close(id: 6))
        #expect(WebNotifications.message(["type": "dance", "id": 1]) == nil)
        #expect(WebNotifications.message("request") == nil)
    }

    @Test("the grants are written into the script, and a copy with other grants is stale")
    func grantsInSource() {
        let granted = WebNotifications.source(grants: ["https://slack.example": "granted"])
        #expect(granted.hasPrefix(WebNotifications.header))
        #expect(granted.contains(#"const GRANTS = {"https://slack.example":"granted"};"#))
        #expect(WebNotifications.source(grants: [:]).contains("const GRANTS = {};"))
        #expect(WebNotifications.grants(["a": true, "b": false]) == ["a": "granted", "b": "denied"])
    }
}

// MARK: - the fixture

@MainActor
final class NotificationFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let recorder: RecordedNotificationPoster
    let center: WebNotificationCenter
    let controller: WebPaneController
    let window: NSWindow
    /// A second lane with the focus, so a click focusing the pane is a change.
    let otherPaneId: String
    /// How many times the click asked for the app to come forward.
    private(set) var activations = 0

    /// Run `body` against a fresh fixture and always take it down. Skipped
    /// outside `./scripts/test.sh` for the reason every real-WebKit suite is.
    static func with(_ body: (NotificationFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED web notifications in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await NotificationFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        site = try await LocalSite(pages: ["/page": Self.page])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-notify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        recorder = RecordedNotificationPoster()
        center = WebNotificationCenter(poster: recorder)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        try store.newWebLane(url: "about:blank", near: lane.id)
        otherPaneId = try #require(store.state.lanes.first { $0.id != lane.id }?.panes.first?.id)
        try store.focusPane(otherPaneId)
        controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config(), notifications: center)
        // Off every screen, never key: a test has no business putting windows
        // in front of someone, and the "pane in front" rule must not fire.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 1000)
        window.contentView?.addSubview(controller.view)
        controller.popupParent = { [weak window] in window }
        // Recorded, not done: `NSApp.activate` from the runner would steal the
        // desktop's focus.
        center.activateApp = { [weak self] in self?.activations += 1 }
    }

    func js(_ view: WKWebView?, _ script: String) async -> Any? {
        guard let view else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    func events(_ view: WKWebView) async -> [String] {
        (await js(view, "events.slice()") as? [String]) ?? []
    }

    func ready() async -> Bool {
        await eventually {
            await js(controller.webView, "document.readyState === 'complete' && typeof ask === 'function' ? 1 : 0") as? Int == 1
        }
    }

    /// Reload, and wait for the new document: its `events` starts empty.
    func reload(_ view: WKWebView) async throws {
        _ = await js(view, "events.push('reloading'); location.reload(); 1")
        #expect(await eventually { await js(view, "typeof events !== 'undefined' && events.length === 0 && typeof ask === 'function' ? 1 : 0") as? Int == 1 })
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

    /// Every event the page hears, in order, and the calls a site makes: the
    /// promise form, the callback form, a constructor with a tag and an icon
    /// the site does not have, `close()`.
    static let page = """
        <!doctype html><title>Notify</title>
        <script>
          window.events = [];
          function perm() { return Notification.permission; }
          function shape() {
            return ['Notification' in window, typeof Notification === 'function',
                    typeof Notification.requestPermission === 'function'].join(',');
          }
          function ask() {
            const p = Notification.requestPermission();
            events.push('promise:' + (p instanceof Promise));
            p.then(r => events.push('perm:' + r));
            return 1;
          }
          function askCb() { Notification.requestPermission(r => events.push('cb:' + r)); return 1; }
          function notify(title, body, tag) {
            const n = new Notification(title, { body, tag, icon: '/missing.png' });
            for (const t of ['show', 'click', 'close', 'error']) n['on' + t] = () => events.push(t + ':' + title);
            window.last = n;
            return 1;
          }
          function closeLast() { last.close(); return 1; }
        </script>
        <body>notify</body>
        """
}

/// Stands in for `UNUserNotificationCenter`, which cannot be reached from the
/// test runner. Records what was asked of it and answers at once.
final class RecordedNotificationPoster: NotificationPosting, @unchecked Sendable {
    struct Post: Equatable {
        let identifier: String
        let title: String
        var subtitle: String = ""
        let body: String
        let icon: URL?
    }

    private let lock = NSLock()
    private var _authorizations = 0
    private var _posted: [Post] = []
    private var _removed: [String] = []

    var authorizations: Int { lock.withLock { _authorizations } }
    var posted: [Post] { lock.withLock { _posted } }
    var removed: [String] { lock.withLock { _removed } }

    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { _authorizations += 1 }
        completion(true)
    }

    func post(identifier: String, title: String, subtitle: String, body: String, icon: URL?,
              completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { _posted.append(Post(identifier: identifier, title: title, subtitle: subtitle, body: body, icon: icon)) }
        completion(nil)
    }

    func remove(identifiers: [String]) {
        lock.withLock { _removed.append(contentsOf: identifiers) }
    }
}
