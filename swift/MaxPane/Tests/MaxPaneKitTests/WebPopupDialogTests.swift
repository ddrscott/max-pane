import AppKit
import Network
import Testing
import WebKit
@testable import MaxPaneKit

/// A page's popup as a dialog, proven against real WebKit rather than argued.
///
/// The owner uses this app as his browser, so "OAuth works" is a claim about
/// `window.opener`, `postMessage` and a shared cookie jar surviving the trip
/// through our code — and none of that can be seen from a unit test of the
/// policy. So: two local sites on two ports, which are two origins to WebKit,
/// an opener page on one and a "provider" on the other, and a real
/// `WebPaneController` in a real window driving real `window.open`s.
///
/// LinkedIn's "Sign in with Google" itself cannot be driven from here — it needs
/// the owner's account — so this is its shape: a size in the features string, a
/// `postMessage` to the opener, a cookie, and `window.close()`.
@Suite("web popups, in real WebKit", .serialized)
@MainActor
struct WebPopupDialogTests {
    @Test("a sign-in popup is a dialog: the opener hears from it, reads its cookie, and gets the keyboard back")
    func signInRoundTrip() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            let token = UUID().uuidString
            let lanes = f.store.state.lanes.count

            #expect(await f.js(web, "signIn('\(f.provider.origin)/provider?token=\(token)', 'auth')") as? Int == 1)
            let dialog = try #require(f.controller.popupDialog)
            #expect(dialog.isOpen)
            #expect(f.store.state.lanes.count == lanes)

            // The size the page asked for, the bar on top, centred in the window.
            let size = PopupGeometry.dialogSize(page: NSSize(width: 500, height: 600), bar: WebPopupBar.height)
            let resting = Popup.frame(size: size, minSize: dialog.window?.minSize ?? .zero, in: f.dialogArea)
            #expect(await f.eventually { dialog.window?.frame == resting })

            // The provider's `window.opener.postMessage`, from its own origin.
            let heard = "\(f.provider.origin) signed-in \(token)"
            #expect(await f.eventually { (await f.js(web, "heard.join('|')") as? String)?.contains(heard) == true })
            // The cookie it set is in the jar the opener reads.
            #expect(await f.eventually { (await f.js(web, "document.cookie") as? String)?.contains(token) == true })
            // And the bar says where the form really is.
            #expect(dialog.bar.url.hasPrefix(f.provider.origin))

            #expect(f.store.state.focusedPaneId == f.otherPaneId)
            _ = await f.js(dialog.webView, "window.close(); 1")
            #expect(await f.eventually { f.controller.popupDialog == nil })
            #expect(await f.eventually { dialog.window?.isVisible != true })
            #expect(f.store.state.focusedPaneId == f.controller.paneId)
            #expect(f.store.state.lanes.count == lanes)
        }
    }

    @Test("five clicks on Sign in are one dialog and no lanes, wherever the opener is; a link is still a lane")
    func oneDialogPerOpener() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            let lanes = f.store.state.lanes.count
            let url = "\(f.provider.origin)/provider?token=\(UUID().uuidString)"

            // The opener in no window at all, as a lane scrolled out of the
            // materialisation window is.
            f.controller.view.removeFromSuperview()
            for _ in 0..<5 { _ = await f.js(web, "signIn('\(url)', '_blank')") }
            #expect(await f.js(web, "handles.length") as? Int == 5)
            #expect(f.controller.popupDialog?.isOpen == true)
            #expect(f.store.state.lanes.count == lanes)
            #expect(f.window.childWindows?.count == 1)
            // Centred over the window it was given, not over a pane that is nowhere.
            let size = PopupGeometry.dialogSize(page: NSSize(width: 500, height: 600), bar: WebPopupBar.height)
            #expect(await f.eventually {
                guard let panel = f.controller.popupDialog?.window else { return false }
                return panel.frame == Popup.frame(size: size, minSize: panel.minSize, in: f.dialogArea)
            })
            // The four it replaced are closed as far as the page can tell, so a
            // library polling `popup.closed` hears that the attempt ended.
            #expect(await f.eventually { await f.js(web, "closedCount()") as? Int == 4 })

            // A popup from the popup — an account chooser — stacks over it.
            let dialog = try #require(f.controller.popupDialog)
            #expect(await f.eventually {
                await f.js(dialog.webView, "typeof chooser === 'function' ? 1 : 0") as? Int == 1
            })
            _ = await f.js(dialog.webView, "chooser('\(f.provider.origin)/chooser')")
            let child = try #require(dialog.child)
            #expect(child.isOpen)
            #expect(child.window?.parent === dialog.window)
            #expect(f.store.state.lanes.count == lanes)

            // Esc on the sign-in takes the chooser with it.
            dialog.popupCancelled()
            #expect(await f.eventually { f.controller.popupDialog == nil && !child.isOpen })
            #expect(await f.eventually { f.window.childWindows?.isEmpty ?? true })

            // A bare `window.open(url)` is still a conversation.
            _ = await f.js(web, "bare('\(url)')")
            #expect(f.controller.popupDialog?.isOpen == true)
            #expect(f.store.state.lanes.count == lanes)
            f.controller.popupDialog?.dismiss()
            #expect(await f.eventually { f.controller.popupDialog == nil })

            // A clicked `target=_blank` link is a page to read: a lane, no dialog.
            _ = await f.js(web, "document.getElementById('read').click(); 1")
            #expect(await f.eventually { f.store.state.lanes.count == lanes + 1 })
            #expect(f.controller.popupDialog == nil)

            // The opener leaving for another origin ends the conversation.
            _ = await f.js(web, "signIn('\(url)', 'again')")
            #expect(f.controller.popupDialog?.isOpen == true)
            _ = await f.js(web, "location.href = '\(f.provider.origin)/chooser'; 1")
            #expect(await f.eventually { f.controller.popupDialog == nil })
        }
    }
}

/// The origin bar, rendered so it can be looked at in both appearances. Gated on
/// `MAXPANE_SHOTS`; `./scripts/test.sh shots DIR` sets it.
@Suite("popup bar rendering")
@MainActor
struct WebPopupBarRenderTests {
    @Test("renders the origin bar: https mid-load, plain http with a failure, a port with a note")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let rows: [(url: String, progress: Double, note: String?)] = [
            ("https://accounts.google.com/v3/signin/identifier?flowName=GlifWebSignIn&continue=https%3A%2F%2Fwww.linkedin.com", 0.42, nil),
            ("http://login.example.net/oauth/authorize?client_id=12", 0, "server not found — login.example.net"),
            ("https://sso.corp.example:8443/adfs/ls", 0, "copied"),
        ]
        let width: CGFloat = 520
        let gap: CGFloat = 12
        try AppearanceSheet.render(to: dir, named: "web-popup-bar") {
            let height = CGFloat(rows.count) * (WebPopupBar.height + gap) + gap
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * gap, height: height))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBorder
            for (index, row) in rows.enumerated() {
                let y = height - CGFloat(index + 1) * (WebPopupBar.height + gap)
                let bar = WebPopupBar(frame: NSRect(x: gap, y: y, width: width, height: WebPopupBar.height))
                bar.setURL(row.url)
                bar.setProgress(row.progress)
                if let note = row.note { bar.say(note, warning: index == 1) }
                sheet.addSubview(bar)
            }
            // A note fades in on AppKit's clock; a picture taken on the same
            // turn would show the bar without it.
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return sheet
        }
    }
}

// MARK: - the fixture

@MainActor
final class PopupFixture {
    let opener: LocalSite
    let provider: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    let window: NSWindow
    /// A second lane with the focus, so "the keyboard came back" is a change.
    let otherPaneId: String

    /// Run `body` against a fresh fixture and always take it down. Skipped
    /// outside `./scripts/test.sh`: these write a cookie, and without a named
    /// profile the jar they would write it to is the owner's.
    static func with(_ body: (PopupFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED web popups in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await PopupFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    private init() async throws {
        opener = try await LocalSite(pages: [
            "/opener": Self.openerPage,
            "/read": "<!doctype html><title>read</title>read",
        ])
        provider = try await LocalSite(pages: [
            "/provider": Self.providerPage,
            "/chooser": "<!doctype html><title>chooser</title>chooser",
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-popups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: opener.origin + "/opener", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        try store.newWebLane(url: "about:blank", near: lane.id)
        otherPaneId = try #require(store.state.lanes.first { $0.id != lane.id }?.panes.first?.id)
        try store.focusPane(otherPaneId)
        controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config())
        // Far off every screen: the dialog is centred on this, and a test has no
        // business putting windows in front of someone.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1000, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 1000)
        window.contentView?.addSubview(controller.view)
        controller.popupParent = { [weak window] in window }
    }

    var dialogArea: NSRect { window.convertToScreen(window.contentLayoutRect) }

    func js(_ view: WKWebView?, _ script: String) async -> Any? {
        guard let view else { return nil }
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

    func openerReady() async -> Bool {
        await eventually {
            await js(controller.webView, "document.readyState === 'complete' && typeof signIn === 'function' ? 1 : 0")
                as? Int == 1
        }
    }

    func tearDown() async {
        controller.popupDialog?.dismiss(returningFocus: false)
        let cookies = DataStorePool.shared.store(controller.dataStoreId).httpCookieStore
        for cookie in await cookies.allCookies() where cookie.name == "maxpane_popup_test" {
            await cookies.deleteCookie(cookie)
        }
        controller.tearDown()
        window.orderOut(nil)
        opener.stop()
        provider.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static let openerPage = """
        <!doctype html><title>Opener</title>
        <a id="read" href="/read" target="_blank">read</a>
        <script>
          window.heard = [];
          window.handles = [];
          addEventListener('message', e => heard.push(e.origin + ' ' + e.data));
          function signIn(url, name) { handles.push(window.open(url, name, 'width=500,height=600')); return handles.length; }
          function bare(url) { handles.push(window.open(url)); return handles.length; }
          function closedCount() { return handles.filter(h => h && h.closed).length; }
        </script>
        """

    static let providerPage = """
        <!doctype html><title>Provider</title>
        <script>
          const token = new URLSearchParams(location.search).get('token') || 'none';
          document.cookie = 'maxpane_popup_test=' + token + '; path=/';
          if (window.opener) window.opener.postMessage('signed-in ' + token, '*');
          function chooser(url) { window.open(url, 'chooser', 'width=400,height=500'); return 1; }
        </script>
        <body>provider</body>
        """
}

/// A web server on the loopback, for pages that have to come from a real
/// origin. Two of these on two ports are two origins to WebKit.
final class LocalSite: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let log = RequestLog()

    var origin: String { "http://127.0.0.1:\(port)" }

    /// Every path asked for so far, in order. What a blocking test reads: a
    /// request WebKit's rule list stopped is a request that never got here.
    var requests: [String] { log.paths }
    func hits(_ path: String) -> Int { log.paths.filter { $0 == path }.count }

    init(pages: [String: String]) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "maxpane.tests.local-site")
        let log = self.log
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
                log.record(path)
                let body = pages[path]
                let bytes = Data((body ?? "not found").utf8)
                let head = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let once = ResumeOnce()
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
    }

    func stop() { listener.cancel() }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(path)
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
