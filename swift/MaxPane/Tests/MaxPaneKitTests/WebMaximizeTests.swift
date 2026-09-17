import AppKit
import LanedCore
import Testing
import WebKit
@testable import MaxPaneKit

/// A maximized *page*, in real WebKit: what the page itself sees.
///
/// `MaximizePaneTests` proves where the strip puts a pane's view. This proves
/// the two claims that are about a real `WKWebView` and cannot be argued from
/// frames: the page lays out at the new width (`innerWidth` moves, and moves
/// back), with the chrome bar still above it; and a page that asks for full
/// screen while maximized fills the maximized pane (ADR-0014), and leaving full
/// screen leaves it maximized.
///
/// WebKit's own full screen is never entered — it would take over the owner's
/// display — by the same recorder `WebFullscreenTests` puts in front of the shim.
@Suite("a maximized page, in real WebKit", .serialized)
@MainActor
struct WebMaximizeTests {
    @Test("the page lays out at the maximized width, full screen fills that, and restore gives the lane's width back")
    func pageFollowsThePane() async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED a maximized page in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let site = try await LocalSite(pages: [
            "/page": "<!doctype html><title>Wide</title><style>body{margin:0}</style><div id=box>box</div>",
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-webmax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        let controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config())

        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        window.contentView = host
        let laneView = LaneView(lane: lane, widthBounds: 420...900)
        laneView.frame = NSRect(x: 200, y: 0, width: 600, height: 1000)
        host.addSubview(laneView)
        laneView.setPaneView(controller.view, for: pane.id, at: 0)
        host.layoutSubtreeIfNeeded()
        defer {
            controller.tearDown()
            window.orderOut(nil)
            site.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let web = try #require(controller.webView)
        let content = web.configuration.userContentController
        let existing = content.userScripts.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: $0.isForMainFrameOnly)
        }
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(
            source: FullscreenFixture.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for script in existing { content.addUserScript(script) }
        web.load(URLRequest(url: URL(string: site.origin + "/page")!))

        func js(_ script: String) async -> Any? { try? await web.evaluateJavaScript(script) }
        func eventually(_ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return await condition()
        }
        func innerWidth() async -> Int? { await js("window.innerWidth") as? Int }

        #expect(await eventually { await js("document.readyState") as? String == "complete" })
        #expect(await eventually { await innerWidth() == 600 })

        let maximizer = PaneMaximizer(host: host)
        maximizer.viewportRect = { host.bounds }
        maximizer.laneView = { _ in laneView }
        maximizer.maximize(paneId: pane.id, view: controller.view, in: laneView, title: "Wide", animated: false)
        host.layoutSubtreeIfNeeded()
        #expect(maximizer.isMaximized)
        #expect(await eventually { await innerWidth() == 1600 })
        // The chrome bar came with it, above the page.
        #expect(controller.chrome.isDescendant(of: maximizer.overlay))
        #expect(!controller.chrome.isHidden && controller.chrome.frame.width == 1600)

        // Full screen, while maximized, is the maximized pane.
        let asked = try? await web.callAsyncJavaScript(
            "await box.requestFullscreen(); return 'resolved'", arguments: [:], in: nil, contentWorld: .page)
        #expect(asked as? String == "resolved")
        #expect(await eventually { controller.isPaneFullscreen })
        #expect(web.frame.size == controller.view.bounds.size)
        #expect(controller.view.bounds.width == 1600)
        #expect(await eventually { await js("box.getBoundingClientRect().width") as? Int == 1600 })
        #expect(web.fullscreenState == .notInFullscreen)
        _ = try? await web.callAsyncJavaScript(
            "await document.exitFullscreen()", arguments: [:], in: nil, contentWorld: .page)
        #expect(await eventually { !controller.isPaneFullscreen })
        #expect(maximizer.isMaximized)
        #expect(await innerWidth() == 1600)

        maximizer.restore(animated: false)
        host.layoutSubtreeIfNeeded()
        #expect(!maximizer.isActive)
        #expect(controller.view.isDescendant(of: laneView))
        #expect(await eventually { await innerWidth() == 600 })
    }
}
