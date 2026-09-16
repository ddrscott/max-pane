import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Two things every web view the app builds is configured for, proven on a
/// real `WebPaneController` rather than read off the source: a pinch is taken
/// and lands on the zoom ladder, and a known host is upgraded to HTTPS.
///
/// A trackpad cannot be pinched from a test — `NSEvent` has no public
/// constructor for a gesture event — so the pinch goes in where
/// `ChromeWebView.onMagnify` would put it, one phase at a time, with the same
/// numbers the event would carry: `magnification` is a delta per event and
/// zero at the ends.
@Suite("pinch zoom and HTTPS upgrade, in real WebKit", .serialized)
@MainActor
struct WebPinchZoomTests {
    @Test("the configuration upgrades known hosts to HTTPS, and the view takes a pinch")
    func configuration() async throws {
        try await PinchFixture.with { f in
            let web = try #require(f.controller.webView)
            #expect(web.configuration.upgradeKnownHostsToHTTPS)
            #expect(web.allowsMagnification)
            // The pane's own handler is installed, so WebKit never sees the gesture.
            #expect((web as? ChromeWebView)?.onMagnify != nil)
            #expect((web as? ChromeWebView)?.onSmartMagnify != nil)
        }
    }

    @Test("a pinch reflows the page live and lands on the nearest rung, written to the ledger")
    func pinchLandsOnARung() async throws {
        try await PinchFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            // A real width first: under the whole suite's load the view can
            // answer before its first layout, and nothing is narrower than 0.
            var widthBefore = 0
            #expect(await f.eventually {
                widthBefore = (await f.js("innerWidth") as? Int) ?? 0
                return widthBefore > 100
            })

            #expect(f.controller.pinch(by: 0, phase: .began))
            #expect(f.controller.pinch(by: 0.25, phase: .changed))
            #expect(f.controller.pinch(by: 0.16, phase: .changed))
            // 1 × 1.25 × 1.16 = 1.45: live, and not yet the zoom.
            #expect(abs(Double(web.pageZoom) - 1.45) < 0.001)
            #expect(f.controller.zoom == 1)
            #expect(f.controller.isPinching)
            // A page zoom, not a magnification: the page laid out narrower.
            #expect(await f.eventually { (await f.js("innerWidth") as? Int).map { $0 < widthBefore } == true })
            #expect(web.magnification == 1)

            #expect(f.controller.pinch(by: 0, phase: .ended))
            // 1.45 is nearer 1.5 than 1.25. The landing eases, so wait for it.
            #expect(await f.eventually { f.controller.zoom == 1.5 && !f.controller.isPinching })
            #expect(abs(Double(web.pageZoom) - 1.5) < 0.001)
            // Persisted like a ⌘= press: a store reopened on the ledger has it.
            let reopened = try StripStore(ledgerPath: f.dir.appendingPathComponent("ledger.db").path)
            #expect(reopened.state.lanes[0].panes[0].zoom == 1.5)
            // ⌘= afterwards steps from the rung.
            #expect(PaneZoom.next(from: f.controller.zoom, up: true) == 1.75)
        }
    }

    @Test("a pinch out zooms out, and both ends of the ladder hold")
    func pinchOutAndClamp() async throws {
        try await PinchFixture.with { f in
            let web = try #require(f.controller.webView)
            f.controller.pinch(by: 0, phase: .began)
            f.controller.pinch(by: -0.3, phase: .changed)
            #expect(abs(Double(web.pageZoom) - 0.7) < 0.001)
            f.controller.pinch(by: 0, phase: .ended)
            #expect(await f.eventually { f.controller.zoom == 0.67 })

            // Far past the top: clamped live, so the page is never at 6×.
            f.controller.pinch(by: 0, phase: .began)
            f.controller.pinch(by: 8, phase: .changed)
            #expect(Double(web.pageZoom) == PaneZoom.ladder.last!)
            f.controller.pinch(by: 0, phase: .ended)
            #expect(await f.eventually { f.controller.zoom == PaneZoom.ladder.last! })

            // And past the bottom.
            f.controller.pinch(by: 0, phase: .began)
            f.controller.pinch(by: -0.99, phase: .changed)
            #expect(Double(web.pageZoom) == PaneZoom.ladder.first!)
            f.controller.pinch(by: 0, phase: .cancelled)
            #expect(await f.eventually { f.controller.zoom == PaneZoom.ladder.first! })
        }
    }

    @Test("⌘0 mid-pinch wins, and a smart zoom toggles 100% and 150%")
    func keysAndSmartZoom() async throws {
        try await PinchFixture.with { f in
            let web = try #require(f.controller.webView)
            f.controller.pinch(by: 0, phase: .began)
            f.controller.pinch(by: 0.5, phase: .changed)
            f.controller.setZoom(1)
            #expect(!f.controller.isPinching)
            #expect(Double(web.pageZoom) == 1)
            // A late `ended` from the same gesture lands where the key put it.
            f.controller.pinch(by: 0, phase: .ended)
            #expect(await f.eventually { !f.controller.isPinching })
            #expect(f.controller.zoom == 1)

            #expect(f.controller.smartZoom())
            #expect(await f.eventually { f.controller.zoom == 1.5 && !f.controller.isPinching })
            #expect(f.controller.smartZoom())
            #expect(await f.eventually { f.controller.zoom == 1 && !f.controller.isPinching })
        }
    }

    @Test("a popup's view takes a pinch too, on the configuration it inherited")
    func popupInherits() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            #expect(await f.js(web, "signIn('\(f.provider.origin)/provider?token=x', 'auth')") as? Int == 1)
            let dialog = try #require(f.controller.popupDialog)
            #expect(dialog.webView.allowsMagnification)
            #expect(dialog.webView.configuration.upgradeKnownHostsToHTTPS)
            // WebKit's own pinch in a popup: nothing of the pane's is installed.
            #expect((dialog.webView as? ChromeWebView)?.onMagnify == nil)
        }
    }
}

/// The rung a pinch lands on, without WebKit.
struct PaneZoomNearestTests {
    @Test func nearestRung() {
        #expect(PaneZoom.nearest(to: 1.37) == 1.25)
        #expect(PaneZoom.nearest(to: 1.45) == 1.5)
        #expect(PaneZoom.nearest(to: 0.7) == 0.67)
        #expect(PaneZoom.nearest(to: 0.1) == 0.5)
        #expect(PaneZoom.nearest(to: 9) == 3.0)
        #expect(PaneZoom.nearest(to: 1.0) == 1.0)
        #expect(PaneZoom.nearest(to: .nan) == 1.0)
    }
}

@MainActor
final class PinchFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    let window: NSWindow

    /// Skipped outside `./scripts/test.sh` for the reason every real-WebKit
    /// suite is: a test process with no profile names the owner's cookie jars.
    static func with(_ body: (PinchFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED pinch zoom in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await PinchFixture()
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
            "/page": "<!doctype html><title>pinch</title><p style='width:2000px'>wide</p>",
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-pinch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        controller = WebPaneController(
            pane: pane, lane: lane, store: store, config: Config(),
            blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
        // Off every screen, and never ordered in.
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
