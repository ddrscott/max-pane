import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Mobile Layout, proven in real WebKit rather than argued.
///
/// "The page renders as it would on an iPhone" is two claims: what the site is
/// *told* — the user agent, which is what a server and every `isMobile()` in
/// the world reads — and what WebKit *does* with the document, which is the
/// content mode. The first is asserted here. The second is measured and
/// printed, page with a viewport and page without, because on macOS
/// `preferredContentMode = .mobile` is documented for iPad and its effect on
/// a Mac is a number to read, not a promise to make.
///
/// One local site, one real `WebPaneController` in a 656 pt column — the
/// portrait lane the feature is for — in a window no screen shows.
@Suite("mobile layout, in real WebKit", .serialized)
@MainActor
struct WebMobileLayoutTests {
    @Test("on: an iPhone user agent, reloaded into the page; off: the desktop one again, exactly")
    func userAgentFollowsTheToggle() async throws {
        try await MobileFixture.with { f in
            #expect(await f.ready("/page"))
            let desktop = try #require(await f.js("navigator.userAgent") as? String)
            #expect(desktop.contains("Macintosh") && desktop.contains("Safari/605.1.15") && desktop.contains("MaxPane/"))
            #expect(!desktop.contains("iPhone") && !desktop.contains("Mobile/"))
            #expect(!f.controller.mobile)
            let desktopWidth = await f.js("window.innerWidth") as? Int
            #expect(desktopWidth == Int(f.controller.webView?.bounds.width ?? 0))

            f.controller.setMobile(true)
            #expect(f.controller.mobile)
            #expect(f.controller.webView?.customUserAgent == BrowserUserAgent.mobile)
            // The page is asked again, not patched: the new string arrives with
            // a reload, which is what a site needs to serve its phone layout.
            #expect(await f.eventually { (await f.js("navigator.userAgent") as? String)?.contains("iPhone") == true })
            let phone = try #require(await f.js("navigator.userAgent") as? String)
            #expect(phone.contains("iPhone") && phone.contains("Mobile/") && phone.hasSuffix("MaxPane/" + f.appVersion))
            #expect(phone == BrowserUserAgent.mobile)
            #expect(!phone.contains("Macintosh"))

            // What the content mode does on a Mac, measured.
            let viewportWidth = await f.js("window.innerWidth") as? Int
            let coarse = await f.js("matchMedia('(pointer: coarse)').matches") as? Bool
            let touch = await f.js("'ontouchstart' in window") as? Bool
            let maxTouch = await f.js("navigator.maxTouchPoints") as? Int
            let platform = await f.js("navigator.platform") as? String
            _ = await f.js("location.href = '/wide'; 0")
            #expect(await f.ready("/wide"))
            let wideWidth = await f.js("window.innerWidth") as? Int
            let wideDoc = await f.js("document.documentElement.clientWidth") as? Int
            print("""
                MOBILE LAYOUT MEASURED (web view \(Int(f.controller.webView?.bounds.width ?? 0)) pt wide):
                  desktop, viewport page: innerWidth=\(desktopWidth.map(String.init) ?? "nil")
                  mobile,  viewport page: innerWidth=\(viewportWidth.map(String.init) ?? "nil") \
                pointer:coarse=\(coarse.map(String.init) ?? "nil") ontouchstart=\(touch.map(String.init) ?? "nil") \
                maxTouchPoints=\(maxTouch.map(String.init) ?? "nil") platform=\(platform ?? "nil")
                  mobile,  no-viewport page: innerWidth=\(wideWidth.map(String.init) ?? "nil") \
                clientWidth=\(wideDoc.map(String.init) ?? "nil")
                """)
            // The flag went to the ledger: a fresh reader of the same file sees
            // it, which is what a relaunch is.
            let again = try StripStore(ledgerPath: f.ledgerPath)
            #expect(again.pane(f.controller.paneId)?.mobile == true)

            // Off: the desktop string, character for character, and a reload.
            f.controller.setMobile(false)
            #expect(!f.controller.mobile)
            // Cleared with nil; WebKit reads it back as "". Either is "none".
            #expect((f.controller.webView?.customUserAgent ?? "").isEmpty)
            #expect(await f.eventually { (await f.js("navigator.userAgent") as? String) == desktop })
            #expect(try StripStore(ledgerPath: f.ledgerPath).pane(f.controller.paneId)?.mobile == false)
            #expect(await f.eventually { await f.js("window.innerWidth") as? Int == desktopWidth })
        }
    }

    @Test("a pane built from a ledger that says mobile asks as a phone from its first request")
    func restoredOnRehydrate() async throws {
        try await MobileFixture.with { f in
            #expect(await f.ready("/page"))
            f.controller.setMobile(true)
            #expect(await f.eventually { (await f.js("navigator.userAgent") as? String)?.contains("iPhone") == true })

            // A second controller for the same pane, as a relaunch builds one.
            let lane = try #require(f.store.lane(f.laneId))
            let pane = try #require(StripStore(ledgerPath: f.ledgerPath).pane(f.controller.paneId))
            #expect(pane.mobile)
            let rebuilt = WebPaneController(pane: pane, lane: lane, store: f.store, config: Config())
            defer { rebuilt.tearDown() }
            rebuilt.view.frame = f.controller.view.frame
            f.window.contentView?.addSubview(rebuilt.view)
            #expect(rebuilt.mobile)
            #expect(rebuilt.webView?.customUserAgent == BrowserUserAgent.mobile)
            #expect(await f.eventually {
                (try? await rebuilt.webView?.evaluateJavaScript("navigator.userAgent") as? String)?.contains("iPhone") == true
            })
        }
    }

    @Test("the mobile token is iPhone Safari's shape, with the same Version and MaxPane last")
    func mobileTokenShape() {
        let token = BrowserUserAgent.mobileToken(safariVersion: "26.6.2", appVersion: "0.1.0")
        #expect(token == "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/26.6.2 Mobile/15E148 Safari/604.1 MaxPane/0.1.0")
        // A one-part version still makes an OS number.
        #expect(BrowserUserAgent.mobileToken(safariVersion: "17", appVersion: "0").contains("iPhone OS 17_0 like"))
        // From the installed Safari, never a pinned number.
        if let version = BrowserUserAgent.installedSafariVersion() {
            #expect(BrowserUserAgent.mobile.contains("Version/\(version) Mobile/15E148 Safari/604.1 MaxPane/"))
        }
    }
}

// MARK: - the fixture

@MainActor
final class MobileFixture {
    let site: LocalSite
    let dir: URL
    let ledgerPath: String
    let store: StripStore
    let laneId: String
    let controller: WebPaneController
    let window: NSWindow

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Skipped outside `./scripts/test.sh`, which names a profile, for the
    /// reason `PopupFixture` is: a web view writes to the profile's cookie jar.
    static func with(_ body: (MobileFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED mobile layout in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await MobileFixture()
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
            "/page": Self.viewportPage,
            "/wide": Self.widePage,
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-mobile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ledgerPath = dir.appendingPathComponent("ledger.db").path
        store = try StripStore(ledgerPath: ledgerPath)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        laneId = lane.id
        controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config())

        // Off every screen, and never ordered in. 656 pt: the portrait lane
        // the feature exists for.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 656, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 656, height: 1000))
        controller.view.frame = NSRect(x: 0, y: 0, width: 656, height: 1000)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
    }

    func js(_ script: String) async -> Any? {
        guard let view = controller.webView else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func ready(_ path: String) async -> Bool {
        await eventually {
            await js("document.readyState === 'complete' && location.pathname === '\(path)' ? 1 : 0") as? Int == 1
        }
    }

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static let viewportPage = """
        <!doctype html><meta name="viewport" content="width=device-width">
        <title>viewport</title>
        <style>body { margin: 0 }</style>
        <div id="ua"></div>
        <script>document.getElementById('ua').textContent = navigator.userAgent + ' ' + window.innerWidth;</script>
        """

    /// No viewport at all: the page a mobile engine lays out at its 980 px
    /// default and a desktop one at the window's width.
    static let widePage = """
        <!doctype html><title>wide</title>
        <style>body { margin: 0 }</style>
        <div id="w"></div>
        <script>document.getElementById('w').textContent = window.innerWidth;</script>
        """
}
