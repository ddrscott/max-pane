import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// A page's full screen, proven in real WebKit rather than argued.
///
/// The owner uses this app as his browser, and "full screen works" is a claim
/// about what a real page sees: the Fullscreen API existing, an element filling
/// the web view and nothing else, the events a player listens for, and an
/// embedded player on another origin getting the same. So: two local sites on
/// two ports, a host page with a box inside a transformed card and two iframes
/// from the other origin (one with `allow="fullscreen"`, one without), and a
/// real `WebPaneController` in a window no screen shows.
///
/// **WebKit's own full screen is never entered here.** It would take over the
/// owner's display. A recorder script is put in front of `PaneFullscreen`'s, so
/// the functions it keeps as "native" are the recorder's: a call reaching them
/// is the call that would have reached WebKit, and `fullscreenState` is checked
/// to have stayed `.notInFullscreen` throughout.
///
/// YouTube itself cannot be the test — it needs the network and plays ads — so
/// the owner checks ⤢ on a real video after installing.
@Suite("web full screen, in real WebKit", .serialized)
@MainActor
struct WebFullscreenTests {
    @Test("a request fills the pane and nothing else; exitFullscreen and Esc put it back")
    func fillsThePane() async throws {
        try await FullscreenFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            #expect(web.configuration.preferences.isElementFullscreenEnabled)
            // The real API is on — read before the shim replaced the getter.
            #expect(await f.js("window.__nativeEnabled") as? Bool == true)
            #expect(await f.js("document.fullscreenEnabled") as? Bool == true)

            let paneFrame = f.controller.view.frame
            let siblingFrame = f.sibling.view.frame
            let siblingWeb = f.sibling.webView?.frame
            let webBefore = web.frame
            let boxBefore = try #require(await f.js("rect(box)") as? String)

            #expect(await f.call("await box.requestFullscreen(); return 'resolved'") as? String == "resolved")
            #expect(await f.js("document.fullscreenElement === box && document.webkitFullscreenElement === box") as? Bool == true)
            #expect(await f.js("document.webkitIsFullScreen") as? Bool == true)
            #expect(await f.js("log.join('|')") as? String == "fullscreenchange:box|webkitfullscreenchange:box")
            #expect(await f.eventually { f.controller.isPaneFullscreen })

            // The web view is the pane now, and the box is exactly the web view.
            #expect(web.frame.size == f.controller.view.bounds.size)
            #expect(await f.eventually { await f.js("rect(box)") as? String == f.full(web) })
            // On top of a later sibling with a higher z-index, out of a card
            // whose transform would otherwise trap a fixed element.
            #expect(await f.js("document.elementFromPoint(20, 140) === box") as? Bool == true)
            // The site's own `:fullscreen` and `:-webkit-full-screen` rules apply.
            #expect(await f.js("getComputedStyle(box).outlineColor") as? String == "rgb(0, 128, 0)")
            #expect(await f.js("getComputedStyle(box).outlineOffset") as? String == "7px")

            // Nothing outside the pane moved, and the split's other pane is untouched.
            #expect(f.controller.view.frame == paneFrame)
            #expect(f.sibling.view.frame == siblingFrame)
            #expect(f.sibling.webView?.frame == siblingWeb)
            #expect(!f.sibling.isPaneFullscreen)
            #expect(!f.sibling.chrome.isHidden && f.sibling.chrome.alphaValue == 1)
            #expect(await f.eventually { f.controller.chrome.isHidden })
            #expect(web.fullscreenState == .notInFullscreen)

            // exitFullscreen.
            #expect(await f.call("await document.exitFullscreen(); return 'resolved'") as? String == "resolved")
            #expect(await f.js("document.fullscreenElement === null") as? Bool == true)
            #expect(await f.js("log.slice(2).join('|')") as? String == "fullscreenchange:null|webkitfullscreenchange:null")
            #expect(await f.eventually { !f.controller.isPaneFullscreen })
            #expect(await f.js("rect(box)") as? String == boxBefore)
            #expect(web.frame == webBefore)
            #expect(await f.eventually { !f.controller.chrome.isHidden && f.controller.chrome.alphaValue == 1 })

            // Esc, as a key event the web view receives, not a script's event.
            _ = await f.call("await box.requestFullscreen()")
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            f.window.makeFirstResponder(web)
            web.keyDown(with: f.escape())
            web.keyUp(with: f.escape(.keyUp))
            #expect(await f.eventually { await f.js("document.fullscreenElement === null") as? Bool == true })
            #expect(await f.eventually { !f.controller.isPaneFullscreen })
            #expect(await f.js("rect(box)") as? String == boxBefore)
            // Taken from the page, as a browser takes it.
            #expect(await f.js("escapes") as? Int == 0)
            #expect(web.fullscreenState == .notInFullscreen)
        }
    }

    @Test("a cross-origin embed with allow=fullscreen fills the pane; one without is refused")
    func embeddedPlayer() async throws {
        try await FullscreenFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            let embed = try #require(f.frames["embed"])
            let bare = try #require(f.frames["bare"])
            #expect(!embed.isMainFrame && embed.securityOrigin.port != f.host.port)

            // WebKit's permissions policy, read through the shim, not overruled.
            #expect(await f.call("return document.fullscreenEnabled", in: bare) as? Bool == false)
            #expect(await f.call(
                "try { await player.requestFullscreen(); return 'resolved' } catch (e) { return 'refused' }",
                in: bare) as? String == "refused")
            #expect(!f.controller.isPaneFullscreen)

            #expect(await f.call("await player.requestFullscreen(); return 'resolved'", in: embed) as? String == "resolved")
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            #expect(await f.eventually { await f.js("rect(embed)") as? String == f.full(web) })
            #expect(await f.eventually { await f.call("return rect(player)", in: embed) as? String == f.full(web) })
            #expect(await f.js("document.fullscreenElement === embed") as? Bool == true)
            #expect(await f.eventually { (await f.js("log.join('|')") as? String)?.hasPrefix("fullscreenchange:embed") == true })

            // The page around it leaves: both documents hear it.
            _ = await f.call("await document.exitFullscreen()")
            #expect(await f.eventually { await f.call("return log.join('|')", in: embed) as? String == "in|out" })
            #expect(await f.eventually { !f.controller.isPaneFullscreen })
            #expect(await f.call("return rect(player)", in: embed) as? String == "0,0,120,80")
            #expect(await f.js("rect(embed).split(',').slice(2).join(',')") as? String == "300,200")

            // The player leaves from inside: the page around it follows.
            _ = await f.call("await player.requestFullscreen()", in: embed)
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            _ = await f.call("await document.exitFullscreen()", in: embed)
            #expect(await f.eventually { !f.controller.isPaneFullscreen })
            #expect(await f.eventually { await f.js("document.fullscreenElement === null") as? Bool == true })
            #expect(await f.js("rect(embed).split(',').slice(2).join(',')") as? String == "300,200")
            #expect(web.fullscreenState == .notInFullscreen)
        }
    }

    @Test("a second request, or ⇧ on the click, goes to WebKit's own full screen")
    func onestepFurther() async throws {
        try await FullscreenFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)

            _ = await f.call("await box.requestFullscreen()")
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            #expect(await f.js("__nativeCalls.length") as? Int == 0)
            // Already filling the pane: the next request is the display's.
            #expect(await f.call("await box.requestFullscreen(); return __nativeCalls.join(',')") as? String == "box")
            #expect(f.controller.isPaneFullscreen)
            _ = await f.call("await document.exitFullscreen()")
            #expect(await f.eventually { !f.controller.isPaneFullscreen })

            // ⇧ held on the gesture: straight to the display, the pane untouched.
            _ = await f.js("box.dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: true })); 0")
            #expect(await f.eventually { await f.js("__nativeCalls.join(',')") as? String == "box,box" })
            #expect(!f.controller.isPaneFullscreen)
            #expect(await f.js("box.hasAttribute('\(PaneFullscreen.attribute)')") as? Bool == false)

            // The same click without ⇧ is the pane's.
            _ = await f.js("box.dispatchEvent(new MouseEvent('click', { bubbles: true })); 0")
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            #expect(await f.js("__nativeCalls.length") as? Int == 2)
            #expect(web.fullscreenState == .notInFullscreen)
        }
    }

    @Test("navigating away while full screen brings the chrome bar back")
    func navigationRestores() async throws {
        try await FullscreenFixture.with { f in
            #expect(await f.ready())
            _ = await f.call("await box.requestFullscreen()")
            #expect(await f.eventually { f.controller.isPaneFullscreen && f.controller.chrome.isHidden })
            _ = await f.js("location.href = '/other'; 0")
            #expect(await f.eventually { !f.controller.isPaneFullscreen })
            #expect(await f.eventually { !f.controller.chrome.isHidden && f.controller.chrome.alphaValue == 1 })
            #expect(await f.eventually { (f.controller.webView?.url?.path ?? "") == "/other" })
        }
    }

    @Test("the bars ease away and back; the page's size changes at once")
    func barsEase() async throws {
        try await FullscreenFixture.with { f in
            #expect(await f.ready())
            let pane = f.controller
            let web = try #require(pane.webView)
            let before = web.frame

            pane.setPaneFullscreen(true)
            #expect(web.frame.size == pane.view.bounds.size)
            // Still on screen and fading, unless Reduce Motion asked for no middle.
            #expect(pane.chrome.isHidden == Motion.isReduced)
            #expect(await f.eventually { pane.chrome.isHidden })

            pane.setPaneFullscreen(false)
            #expect(web.frame == before)
            #expect(!pane.chrome.isHidden)
            #expect(await f.eventually { pane.chrome.alphaValue == 1 })
            #expect(!pane.chrome.isHidden)
        }
    }

    @Test("a popup's video fills the dialog's page, the origin bar stays, and Esc leaves full screen first")
    func insideAPopup() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            _ = await f.js(web, "signIn('\(f.provider.origin)/provider?token=fullscreen', 'auth')")
            let dialog = try #require(f.controller.popupDialog)
            // The provider's own function, not `readyState`: the popup's first
            // document is an empty `about:blank` that is already complete, and
            // nothing injected at document start runs in it.
            #expect(await f.eventually {
                await f.js(dialog.webView, "typeof chooser === 'function' ? 1 : 0") as? Int == 1
            })

            let size: String?
            do {
                size = try await dialog.webView.callAsyncJavaScript("""
                    const v = document.createElement('div');
                    v.style.cssText = 'width: 40px; height: 30px; background: #000';
                    document.body.appendChild(v);
                    try { await v.requestFullscreen(); } catch (e) {
                      return 'refused: ' + e.message + ' enabled=' + document.fullscreenEnabled
                        + ' shim=' + Object.prototype.hasOwnProperty.call(window, '__maxpaneFullscreen')
                        + ' active=' + (navigator.userActivation ? navigator.userActivation.isActive : 'n/a');
                    }
                    const r = v.getBoundingClientRect();
                    return [r.width, r.height].join(',');
                    """, arguments: [:], in: nil, contentWorld: .page) as? String
            } catch {
                size = "threw: \(error)"
            }
            let page = dialog.webView.bounds.size
            #expect(size == "\(Int(page.width)),\(Int(page.height))")
            #expect(await f.eventually { dialog.pageIsFullscreen })
            // The pane behind it keeps its bar; the dialog keeps its origin.
            #expect(!f.controller.isPaneFullscreen && !f.controller.chrome.isHidden)
            #expect(!dialog.bar.isHidden && dialog.bar.alphaValue == 1)

            dialog.popupCancelled()
            #expect(dialog.isOpen)
            #expect(await f.eventually {
                await f.js(dialog.webView, "document.fullscreenElement === null") as? Bool == true
            })
            dialog.popupCancelled()
            #expect(await f.eventually { f.controller.popupDialog == nil })
        }
    }
}

// MARK: - the fixture

@MainActor
final class FullscreenFixture {
    let host: LocalSite
    let embedSite: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    /// The other pane of a split lane, stacked under `controller`.
    let sibling: WebPaneController
    let window: NSWindow
    /// Each iframe's frame, by its `name`, as its page reported in.
    private(set) var frames: [String: WKFrameInfo] = [:]
    private var frameRelay: FullScreenMessageRelay?

    static let frameChannel = "fullscreenTestFrame"

    /// Run `body` against a fresh fixture and always take it down. Skipped
    /// outside `./scripts/test.sh`, which names a profile, for the same reason
    /// `PopupFixture` is: a web view writes to the profile's cookie jar.
    static func with(_ body: (FullscreenFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED web full screen in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await FullscreenFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        embedSite = try await LocalSite(pages: ["/embed": Self.embedPage])
        let embedOrigin = embedSite.origin
        host = try await LocalSite(pages: [
            "/host": Self.hostPage.replacingOccurrences(of: "EMBED", with: embedOrigin),
            "/other": "<!doctype html><title>other</title>other",
        ])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-fullscreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: host.origin + "/host", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        try store.newWebLane(url: "about:blank", near: lane.id)
        let otherLane = try #require(store.state.lanes.first { $0.id != lane.id })
        let otherPane = try #require(otherLane.panes.first)
        controller = WebPaneController(pane: pane, lane: lane, store: store, config: Config())
        sibling = WebPaneController(pane: otherPane, lane: otherLane, store: store, config: Config())
        // Off every screen, and never ordered in.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        // A split lane: this pane on top, its sibling below.
        controller.view.frame = NSRect(x: 0, y: 500, width: 600, height: 500)
        sibling.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(controller.view)
        window.contentView?.addSubview(sibling.view)

        let web = try #require(controller.webView)
        let content = web.configuration.userContentController
        // The recorder goes first, so the "native" functions the shim keeps are
        // the recorder's and WebKit's own full screen is unreachable.
        //
        // Rebuilt as fresh scripts in a Swift array, never re-added from
        // `userScripts` itself: that array is bridged and live, so adding its
        // own elements back while walking it never reaches the end — the test
        // process grew until the system killed it, and filled the disk with
        // swap on the way.
        let existing = content.userScripts.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: $0.isForMainFrameOnly)
        }
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(
            source: Self.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for script in existing { content.addUserScript(script) }
        let relay = FullScreenMessageRelay { [weak self] message in
            guard let name = message.body as? String, !name.isEmpty else { return }
            self?.frames[name] = message.frameInfo
        }
        frameRelay = relay
        content.add(relay, name: Self.frameChannel)
        web.load(URLRequest(url: URL(string: host.origin + "/host")!))
    }

    func full(_ web: WKWebView) -> String { "0,0,\(Int(web.bounds.width)),\(Int(web.bounds.height))" }

    func js(_ script: String) async -> Any? {
        guard let view = controller.webView else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    /// An async function body, in the page's world, in `frame` or the top one.
    func call(_ script: String, in frame: WKFrameInfo? = nil) async -> Any? {
        guard let view = controller.webView else { return nil }
        do {
            return try await view.callAsyncJavaScript(script, arguments: [:], in: frame, contentWorld: .page)
        } catch {
            return "error: \(error)"
        }
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func ready() async -> Bool {
        await eventually {
            await js("document.readyState === 'complete' && typeof rect === 'function' ? 1 : 0") as? Int == 1
                && frames["embed"] != nil && frames["bare"] != nil
        }
    }

    /// Esc, delivered to the web view in this process — never posted to the
    /// system, so nothing reaches whatever app is in front.
    func escape(_ type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    func tearDown() {
        controller.webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.frameChannel)
        frameRelay = nil
        controller.tearDown()
        sibling.tearDown()
        window.orderOut(nil)
        host.stop()
        embedSite.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static let recorder = """
        (() => {
          const d = Object.getOwnPropertyDescriptor(Document.prototype, 'fullscreenEnabled');
          window.__nativeEnabled = !!(d && d.get && d.get.call(document));
          window.__nativeCalls = [];
          const record = function () { window.__nativeCalls.push(this.id || this.tagName); return Promise.resolve(); };
          Element.prototype.requestFullscreen = record;
          Element.prototype.webkitRequestFullscreen = record;
        })();
        """

    static let hostPage = """
        <!doctype html><title>Host</title>
        <style>
          body { margin: 0 }
          .card { transform: translateZ(0); overflow: hidden; width: 200px; height: 120px; position: relative; z-index: 1 }
          #box { width: 160px; height: 90px; margin: 10px; background: #333 }
          #box:fullscreen { outline: 3px solid rgb(0, 128, 0) }
          @media (min-width: 1px) { #box:-webkit-full-screen { outline-offset: 7px } }
          .cover { position: relative; z-index: 5; height: 40px; background: #900 }
          iframe { width: 300px; height: 200px; border: 0; display: block }
        </style>
        <div class="card"><div id="box"></div></div>
        <div class="cover">cover</div>
        <iframe id="embed" name="embed" allow="fullscreen" src="EMBED/embed"></iframe>
        <iframe id="bare" name="bare" src="EMBED/embed"></iframe>
        <script>
          // A named <iframe> answers to its name on `window` as its content
          // window, not as the element; a global `const` wins that lookup.
          const embed = document.getElementById('embed');
          const bare = document.getElementById('bare');
          window.log = [];
          window.escapes = 0;
          for (const t of ['fullscreenchange', 'webkitfullscreenchange']) {
            document.addEventListener(t, () =>
              log.push(t + ':' + (document.fullscreenElement ? document.fullscreenElement.id : 'null')));
          }
          document.addEventListener('keydown', e => { if (e.key === 'Escape') escapes += 1; });
          function rect(el) { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].join(','); }
          box.addEventListener('click', e => { e.target.requestFullscreen().catch(() => {}); });
        </script>
        """

    static let embedPage = """
        <!doctype html><title>Embed</title>
        <style>body { margin: 0 } #player { width: 120px; height: 80px; background: #000 }</style>
        <div id="player"></div>
        <script>
          window.log = [];
          document.addEventListener('fullscreenchange', () => log.push(document.fullscreenElement ? 'in' : 'out'));
          function rect(el) { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].join(','); }
          window.webkit.messageHandlers.\(frameChannel).postMessage(window.name);
        </script>
        """
}
