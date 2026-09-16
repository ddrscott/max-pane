import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Ad and tracker blocking, proven in real WebKit rather than argued.
///
/// "The list is on the view" is a claim about requests that never leave the
/// network process, so the proof is a server that logs what reached it: a
/// page on one loopback site asks a second site for two images, one matching
/// a rule and one not, and the second site's log has one of them. The popup
/// test does the same from a `window.open` dialog, because WebKit copies the
/// opener's configuration and *keeps the same `WKUserContentController`
/// object* — an assumption `buildWebView` relies on and this test pins. The
/// per-site switch flips the exemption for `127.0.0.1` and reloads, and the
/// blocked image arrives.
///
/// The blocker here is the test's own, over a temporary rule-list store, with
/// a one-rule list: the real one is a 9 MB download and its compile time is a
/// number for the log, not a thing a unit test should depend on.
@Suite("content blocking, in real WebKit", .serialized)
@MainActor
struct WebContentBlockingTests {
    @Test("a request matching a rule never reaches the server; one that does not, does")
    func blocksTheMatchingRequest() async throws {
        try await BlockingFixture.with { f in
            #expect(f.blocker.lists.count == 1 && f.blocker.ruleCount == 1)
            #expect(f.blocker.isBlocking(host: "127.0.0.1"))
            // On no site yet, so the menu item has nothing to tick.
            #expect(f.controller.blockingState == nil)
            #expect(!f.controller.chrome.isBlockingChipShown)

            try await f.open("/page")
            #expect(await f.settled(f.controller.webView))
            #expect(f.controller.blockingState == true)
            #expect(!f.controller.chrome.isBlockingChipShown)
            #expect(await f.eventually { f.tracker.hits("/ok.png") == 1 })
            #expect(f.tracker.hits("/ad/pixel.png") == 0, "blocked, so never requested: \(f.tracker.requests)")
        }
    }

    @Test("a popup over the pane carries the opener's list")
    func popupCarriesTheList() async throws {
        try await BlockingFixture.with { f in
            try await f.open("/page")
            #expect(await f.settled(f.controller.webView))

            #expect(await f.js(f.controller.webView, "popup('/popup')") as? Bool == true)
            #expect(await f.eventually { f.controller.popupDialog != nil })
            let popup = try #require(f.controller.popupDialog?.webView)
            // The same controller object, which is the whole mechanism.
            #expect(popup.configuration.userContentController === f.controller.webView?.configuration.userContentController)
            #expect(await f.settled(popup))
            #expect(await f.eventually { f.tracker.hits("/popup-ok.png") == 1 })
            #expect(f.tracker.hits("/ad/popup.png") == 0, "blocked in the popup too: \(f.tracker.requests)")
        }
    }

    @Test("switched off for the site, the blocked request goes through; on again, it stops")
    func perSiteSwitch() async throws {
        try await BlockingFixture.with { f in
            try await f.open("/page")
            #expect(await f.settled(f.controller.webView))
            #expect(f.tracker.hits("/ad/pixel.png") == 0)

            // Off, through the same door the menu and the chip use.
            f.controller.toggleBlocking()
            #expect(f.blocker.exemptDomains == ["127.0.0.1"])
            #expect(f.persisted == ["127.0.0.1 off"])
            #expect(f.controller.blockingState == false)
            #expect(await f.eventually { f.controller.chrome.isBlockingChipShown })
            #expect(await f.eventually { f.tracker.hits("/ok.png") == 2 })
            #expect(await f.eventually { f.tracker.hits("/ad/pixel.png") == 1 }, "let through: \(f.tracker.requests)")

            // On again: another reload, and the ad request does not come back.
            f.controller.toggleBlocking()
            #expect(f.blocker.exemptDomains.isEmpty)
            #expect(f.persisted == ["127.0.0.1 off", "127.0.0.1 on"])
            #expect(f.controller.blockingState == true)
            #expect(await f.eventually { f.tracker.hits("/ok.png") == 3 })
            #expect(await f.eventually { !f.controller.chrome.isBlockingChipShown })
            #expect(f.tracker.hits("/ad/pixel.png") == 1, "blocked again: \(f.tracker.requests)")
        }
    }

    @Test("a list is cut at WebKit's ceiling with the exceptions riding along in every part")
    func splitKeepsExceptionsEverywhere() {
        func rule(_ n: Int) -> [String: Any] { ["trigger": ["url-filter": "r\(n)"], "action": ["type": "block"]] }
        let exception: [String: Any] = ["trigger": ["url-filter": "x"], "action": ["type": "ignore-previous-rules"]]
        let rules: [Any] = [rule(1), rule(2), exception, rule(3), rule(4), rule(5)]

        #expect(RuleListSplit.split([], limit: 3).isEmpty)
        #expect(RuleListSplit.split(rules, limit: 6).count == 1)
        let parts = RuleListSplit.split(rules, limit: 3)
        // Two ordinary rules and the exception per part, and every part ends
        // with the exception — the only place it reaches its part's rules from.
        #expect(parts.count == 3)
        for part in parts {
            #expect(part.count <= 3)
            #expect(RuleListSplit.isException(part.last!))
            #expect(part.filter(RuleListSplit.isException).count == 1)
        }
        let filters = parts.flatMap { $0.filter { !RuleListSplit.isException($0) } }
            .compactMap { (($0 as? [String: Any])?["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters == ["r1", "r2", "r3", "r4", "r5"])
    }

    @Test("the registrable domain is what the switch is keyed by")
    func domains() {
        #expect(ContentBlocker.domain(of: "www.youtube.com") == "youtube.com")
        #expect(ContentBlocker.domain(of: "M.YouTube.com") == "youtube.com")
        #expect(ContentBlocker.domain(of: "news.bbc.co.uk") == "bbc.co.uk")
        #expect(ContentBlocker.domain(of: "127.0.0.1") == "127.0.0.1")
        #expect(ContentBlocker.domain(of: "localhost") == "localhost")
        #expect(ContentBlocker.domain(of: "") == nil)
        #expect(ContentBlocker.domain(of: nil) == nil)
        #expect(ContentBlocker.sources("https://a.example/l.json, https://b.example/m.json  ftp://no.example/x").count == 2)
    }
}

@MainActor
final class BlockingFixture {
    let site: LocalSite
    let tracker: LocalSite
    let dir: URL
    let store: StripStore
    let blocker: ContentBlocker
    let controller: WebPaneController
    let window: NSWindow
    /// What the blocker asked to have written, as `domain off` / `domain on`.
    private(set) var persisted: [String] = []

    /// Run `body` against a fresh fixture and always take it down. Skipped
    /// outside `./scripts/test.sh` for the reason every real-WebKit suite is.
    static func with(_ body: (BlockingFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED content blocking in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await BlockingFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        tracker = try await LocalSite(pages: ["/ok.png": "ok", "/popup-ok.png": "ok", "/ad/pixel.png": "ad", "/ad/popup.png": "ad"])
        let trackerOrigin = tracker.origin
        site = try await LocalSite(pages: [
            "/page": Self.page(loading: ["\(trackerOrigin)/ad/pixel.png", "\(trackerOrigin)/ok.png"]),
            "/popup": Self.page(loading: ["\(trackerOrigin)/ad/popup.png", "\(trackerOrigin)/popup-ok.png"]),
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-blocking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        blocker = ContentBlocker(directory: dir.appendingPathComponent("content-rules"))
        try store.newWebLane(url: "about:blank", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config(), blocker: blocker)
        // Off every screen, and never ordered in.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 1000)
        window.contentView?.addSubview(controller.view)
        controller.popupParent = { [weak window] in window }
        blocker.persistExemption = { [weak self] domain, exempt in self?.persisted.append("\(domain) \(exempt ? "off" : "on")") }
        // After the view exists: the list lands on a live view, which is the
        // first-launch path where the compile finishes after the window opens.
        let rules = #"[{"trigger":{"url-filter":"/ad/"},"action":{"type":"block"}}]"#
        try await blocker.install(json: Data(rules.utf8), source: "test")
        #expect(blocker.meta?.identifiers.count == 1)
    }

    func open(_ path: String) async throws {
        let web = try #require(controller.webView)
        web.load(URLRequest(url: URL(string: site.origin + path)!))
    }

    func js(_ view: WKWebView?, _ script: String) async -> Any? {
        guard let view else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    /// The page's two image loads have each ended, one way or the other.
    func settled(_ view: WKWebView?) async -> Bool {
        await eventually { await js(view, "typeof done === 'number' ? done : -1") as? Int == 2 }
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
        controller.popupDialog?.dismiss(returningFocus: false)
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        tracker.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Two images asked for from script, so the handlers are on before the
    /// requests start; `done` counts each one ending, blocked or served.
    static func page(loading sources: [String]) -> String {
        let adds = sources.map { "add('\($0)');" }.joined(separator: " ")
        return """
            <!doctype html><title>Blocking</title>
            <script>
              window.done = 0;
              function add(src) { const i = new Image(); i.onload = i.onerror = () => { done++; }; i.src = src; }
              function popup(path) { return !!window.open(path, 'p', 'width=500,height=600'); }
              \(adds)
            </script>
            <body>blocking</body>
            """
    }
}
