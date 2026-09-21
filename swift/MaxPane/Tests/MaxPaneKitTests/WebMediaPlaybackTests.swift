import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Sound on the first click, and no sound without one, in real WebKit.
///
/// The owner: *"I seem to have to hit play, then click in the video
/// component."* What was measured before anything was changed (ADR-0034):
///
/// - WebKit was not muting anything. `mediaTypesRequiringUserActionForPlayback`
///   defaults to none on macOS, and a page that called `play()` on load played
///   **with sound**. That is the opposite bug, on a strip that restores its
///   pages at launch, and `gesturelessSoundIsRefused` is its guard.
/// - A click on a web view that is not first responder, in a window that is
///   not key, carries user activation and plays with sound at once. The focus
///   path was not the cause.
/// - His YouTube pane is on Mobile Layout, which is served m.youtube.com, whose
///   player mutes its own `<video>` before it starts and shows TAP TO UNMUTE —
///   with or without the blocker, in a bare `WKWebView` too. `/mobile` is that
///   player reduced to what matters: the page mutes itself, Play only plays,
///   and a click on the video unmutes. `withoutTheScript` is the owner's two
///   clicks reproduced; `playOverAPageMutedVideo` is the fix.
///
/// **Nothing here is audible.** The fixture's audio track is digital silence;
/// WebKit's "is playing audio" is about the track, not the samples.
///
/// A click is a real `mouseDown`/`mouseUp` pair handed to the view the window
/// hit-tests, so it reaches the page as a trusted event with user activation.
/// (`NSWindow.sendEvent` drops mouse events for a window that was never
/// ordered in, and these windows never are — measured.) No test reaches for
/// `evaluateJavaScript("v.play()")`: WebKit runs that *with* a gesture, which
/// is the thing under test. For the same reason the autoplay tests do not
/// evaluate anything until they have their answer: the page reports over
/// `fetch('/log/…')` and the speaker is read from the web view.
@Suite("media playback, in real WebKit", .serialized)
@MainActor
struct WebMediaPlaybackTests {
    @Test("WebKit's own default lets anything play; a pane asks for a gesture, and web_autoplay says which")
    func policy() async throws {
        // The reason the switch exists. If WebKit changes this default, the
        // comment in `buildWebView` and ADR-0034 want another look.
        #expect(WKWebViewConfiguration().mediaTypesRequiringUserActionForPlayback == [])
        #expect(Config().webAutoplay == .gesture)
        #expect(WebMediaPlayback.mediaTypesRequiringUserAction(.gesture) == .audio)
        #expect(WebMediaPlayback.mediaTypesRequiringUserAction(.allow) == [])
        let field = try #require(ConfigField.all.first { $0.key == "web_autoplay" })
        guard case .choice(let options) = field.control else {
            Issue.record("web_autoplay is not a choice")
            return
        }
        #expect(options == ["gesture", "allow"])
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            #expect(web.configuration.mediaTypesRequiringUserActionForPlayback == .audio)
            #expect(web.configuration.userContentController.userScripts.contains { $0.source == WebMediaPlayback.source })
        }
    }

    @Test("play() on load, with sound, is refused; the muted fallback runs and makes no sound")
    func gesturelessSoundIsRefused() async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            f.open("/autoplay")
            #expect(await f.eventually { f.beacons.contains("autoplay-rejected:NotAllowedError") }, "\(f.beacons)")
            #expect(!f.beacons.contains("autoplay-resolved"))
            // And it stays quiet, not just for the first frame.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)
            #expect(!f.beacons.contains("playing"))

            // What a player does next: mute itself and try again. That runs —
            // a silent video is not what the rule is about.
            f.open("/fallback")
            #expect(await f.eventually { f.beacons.contains("muted-autoplay-resolved") }, "\(f.beacons)")
            #expect(f.beacons.contains("sound-autoplay-rejected:NotAllowedError"))
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)
            #expect(await f.js("!v.paused && v.muted") as? Bool == true)
        }
    }

    @Test("web_autoplay = \"allow\" is WebKit's default back: the same page plays with sound, unasked")
    func allowIsTheOldBehaviour() async throws {
        try await MediaFixture.with(autoplay: .allow) { f in
            let web = try #require(f.controller.webView)
            #expect(web.configuration.mediaTypesRequiringUserActionForPlayback == [])
            f.open("/autoplay")
            #expect(await f.eventually { f.beacons.contains("autoplay-resolved") }, "\(f.beacons)")
            // The control for the test above: the speaker reading can say yes.
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true })
        }
    }

    @Test("one click plays with sound: a click handler's play(), and the native controls; focused before the click or not",
          arguments: ["/handler", "/controls"], [false, true])
    func oneClick(page: String, focusedFirst: Bool) async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            f.open(page)
            #expect(await f.eventually { f.beacons.contains("loaded") })
            if focusedFirst { f.window.makeFirstResponder(web) }
            #expect((f.window.firstResponder === web) == focusedFirst)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)
            try await f.click("v")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true }, "\(f.beacons)")
            #expect(await f.eventually { await f.js("!v.paused && !v.muted && v.currentTime > 0") as? Bool == true })
            #expect(f.beacons.filter { $0.hasPrefix("click:") } == ["click:v:trusted:active"])
        }
    }

    @Test("the same, in a private lane and in a docked one", arguments: [true, false])
    func oneClickElsewhere(isPrivate: Bool) async throws {
        try await MediaFixture.with(isPrivate: isPrivate, docked: !isPrivate) { f in
            let web = try #require(f.controller.webView)
            #expect(web.configuration.mediaTypesRequiringUserActionForPlayback == .audio)
            f.open("/handler")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            try await f.click("v")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true }, "\(f.beacons)")
            #expect(await f.js("!v.paused && !v.muted") as? Bool == true)
        }
    }

    @Test("a popup's page inherits the policy and the script")
    func popupInherits() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            #expect(await f.js(web, "signIn('\(f.provider.origin)/provider?token=x', 'auth')") as? Int == 1)
            let dialog = try #require(f.controller.popupDialog)
            #expect(dialog.webView.configuration.mediaTypesRequiringUserActionForPlayback == .audio)
            #expect(dialog.webView.configuration.userContentController.userScripts.contains { $0.source == WebMediaPlayback.source })
        }
    }

    @Test("Play over a video the page muted plays with sound, in one click")
    func playOverAPageMutedVideo() async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            f.open("/mobile")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            #expect(await f.js("v.muted && v.paused") as? Bool == true)
            try await f.click("play")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true }, "\(f.beacons)")
            #expect(await f.js("!v.paused && !v.muted") as? Bool == true)
            // The page hears about it the way it hears about its own unmute.
            #expect(f.beacons.contains("volumechange"))
        }
    }

    @Test("without the script that is the owner's two clicks: Play runs it silent, a click on the video unmutes")
    func withoutTheScript() async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            web.configuration.userContentController.removeAllUserScripts()
            f.open("/mobile")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            try await f.click("play")
            #expect(await f.eventually { await f.js("!v.paused") as? Bool == true })
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(await f.js("v.muted") as? Bool == true)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)
            try await f.click("v", dy: 0.2)
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true }, "\(f.beacons)")
        }
    }

    @Test("a mute the person made is theirs: Play does not lift it; nor one on a video nobody clicked on")
    func theScriptsLimits() async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            f.open("/mobile")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            // The site's own mute button, pressed: a gesture, so the person's.
            try await f.click("mute")
            #expect(await f.eventually { f.beacons.contains("muted-by-button") })
            try await f.click("play")
            #expect(await f.eventually { await f.js("!v.paused") as? Bool == true })
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(await f.js("v.muted") as? Bool == true)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)

            // A Play that is not over the video: the page muted it, the click
            // was somewhere else, and it is left as the page made it.
            f.open("/mobile")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            try await f.click("outside")
            #expect(await f.eventually { await f.js("!v.paused") as? Bool == true })
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(await f.js("v.muted") as? Bool == true)
            #expect(WebPaneAudio.isPlayingAudio(web) == false)
        }
    }

    @Test("the pane's own mute silences without pausing, the page cannot see it, and WebKit still has the SPI")
    func paneAudio() async throws {
        try await MediaFixture.with { f in
            let web = try #require(f.controller.webView)
            // If these fail WebKit renamed them, and the guards in
            // `WebPaneAudio` are quietly answering "unknown".
            #expect(web.responds(to: NSSelectorFromString(WebPaneAudio.playingAudioKey)))
            #expect(web.responds(to: NSSelectorFromString(WebPaneAudio.mutedStateKey)))
            #expect(web.responds(to: WebPaneAudio.setPageMuted))
            #expect(WebPaneAudio.isMuted(web) == false)

            f.open("/handler")
            #expect(await f.eventually { f.beacons.contains("loaded") })
            try await f.click("v")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true })

            #expect(WebPaneAudio.setMuted(true, on: web))
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == true })
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(await f.js("!v.paused && !v.muted") as? Bool == true)
            // Measured, and what Safari's muted tab speaker sits on: a page
            // muted from outside still reports that it is playing audio.
            #expect(WebPaneAudio.isPlayingAudio(web) == true)

            #expect(WebPaneAudio.setMuted(false, on: web))
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == false })
        }
    }
}

@MainActor
final class MediaFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    let window: NSWindow
    private var mark = 0

    /// Skipped outside `./scripts/test.sh` for the reason every real-WebKit
    /// suite is: a test process with no profile names the owner's cookie jars.
    static func with(
        autoplay: WebAutoplay = .gesture, isPrivate: Bool = false, docked: Bool = false,
        _ body: (MediaFixture) async throws -> Void
    ) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED media playback in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await MediaFixture(autoplay: autoplay, isPrivate: isPrivate, docked: docked)
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init(autoplay: WebAutoplay, isPrivate: Bool, docked: Bool) async throws {
        site = try await LocalSite(
            pages: [
                "/blank": "<!doctype html><title>blank</title>",
                "/autoplay": Self.autoplay, "/fallback": Self.fallback,
                "/handler": Self.handler, "/controls": Self.controls, "/mobile": Self.mobile,
                "/opener": Self.opener, "/late": Self.late,
            ],
            files: ["/tiny.mp4": (type: "video/mp4", data: Self.video)])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: site.origin + "/blank", near: nil, private: isPrivate)
        if docked {
            try store.dockLane(try #require(store.state.lanes.first).id, side: .left, mode: .inset)
        }
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        var config = Config()
        config.webAutoplay = autoplay
        controller = WebPaneController(
            pane: pane, lane: lane, store: store, config: config,
            blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
        // Off every screen, and never ordered in.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.popupParent = { [weak window] in window }
    }

    /// Load a page without evaluating anything in it. What it reports from
    /// here on is `beacons`.
    func open(_ path: String) {
        mark = site.requests.count
        controller.webView?.load(URLRequest(url: URL(string: site.origin + path)!))
    }

    /// What the current page has reported, in order.
    var beacons: [String] {
        site.requests.dropFirst(mark).filter { $0.hasPrefix("/log/") }.map { String($0.dropFirst(5)) }
    }

    func js(_ script: String) async -> Any? {
        guard let web = controller.webView else { return nil }
        return try? await web.evaluateJavaScript(script)
    }

    /// A real click on the element with this id: `mouseDown` and `mouseUp` to
    /// the view the window hit-tests at that point.
    func click(_ id: String, dx: Double = 0.5, dy: Double = 0.5) async throws {
        let web = try #require(controller.webView)
        let rect = try #require(await js("(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()") as? [Double])
        let x = rect[0] + rect[2] * dx, y = rect[1] + rect[3] * dy
        // Asked again each time: the pane lays its web view out with
        // constraints, and under a loaded run the first pass may not have
        // happened yet. And the pane's first-paint cover sits over the page
        // until it has drawn, when a click is the cover's.
        func windowPoint() -> NSPoint {
            web.convert(NSPoint(x: x, y: web.isFlipped ? y : Double(web.bounds.height) - y), to: nil)
        }
        let onPage = await eventually(15) {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let hit = window.contentView?.hitTest(windowPoint()) else { return false }
            return hit === web || hit.isDescendant(of: web)
        }
        let point = windowPoint()
        #expect(onPage, "the click would land on \(String(describing: window.contentView?.hitTest(point).map { Swift.type(of: $0) })), not the page")
        let target = try #require(window.contentView?.hitTest(point))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            try? await Task.sleep(nanoseconds: 30_000_000)
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

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A video with sound, and a page that says what happens to it.
    static let head = """
        <!doctype html><title>media</title><style>body{margin:0} button{display:block;height:30px}</style>
        <div id="box" style="position:relative;width:300px;height:200px">
        <video id="v" src="/tiny.mp4" playsinline preload="auto" loop width="300" height="200" style="background:#333"></video>
        </div>
        <script>
        const v = document.getElementById('v');
        const say = (x) => { fetch('/log/' + x).catch(() => {}); };
        v.addEventListener('loadeddata', () => say('loaded'));
        for (const e of ['playing', 'pause', 'volumechange']) v.addEventListener(e, () => say(e));
        document.addEventListener('click', (e) => say('click:' + e.target.id + (e.isTrusted ? ':trusted' : ':synthetic')
          + (navigator.userActivation.isActive ? ':active' : ':inactive')), true);
        </script>
        """
    static let autoplay = head + """
        <script>v.play().then(() => say('autoplay-resolved'), (e) => say('autoplay-rejected:' + e.name));</script>
        """
    /// With sound first, muted when that is refused: what players do.
    static let fallback = head + """
        <script>
        v.play().then(() => say('sound-autoplay-resolved'), (e) => {
          say('sound-autoplay-rejected:' + e.name);
          v.muted = true;
          v.play().then(() => say('muted-autoplay-resolved'), (e) => say('muted-autoplay-rejected:' + e.name));
        });
        </script>
        """
    static let handler = head + """
        <script>v.addEventListener('click', () => { v.play(); });</script>
        """
    static let controls = head + """
        <script>v.controls = true;</script>
        """
    /// A page that opens a popup holding the video: a sign-in window with a
    /// welcome jingle, reduced. For "a popup's audio belongs to its opener".
    static let opener = """
        <!doctype html><title>opener</title>
        <script>function openPopup() { return window.open('/handler', 'p', 'width=420,height=320') ? 1 : 0; }</script>
        """
    /// A page with no media until it is asked: `addLater()` builds a second
    /// video after the fact, the way a feed does.
    static let late = """
        <!doctype html><title>late</title><div id="host"></div>
        <script>
        function addLater() {
          const v = document.createElement('video');
          v.id = 'v2'; v.src = '/tiny.mp4'; v.loop = true; v.playsInline = true;
          document.getElementById('host').appendChild(v);
          return v.play().then(() => 1, () => 0);
        }
        </script>
        """
    /// m.youtube.com's player, reduced: it mutes itself before it starts, its
    /// Play (over the video) only plays, a click on the video unmutes, and it
    /// has a mute button of its own. `outside` is a Play that is not over it.
    static let mobile = head + """
        <button id="play" style="position:absolute;left:120px;top:85px;width:60px">play</button>
        <button id="mute">mute</button><button id="outside">play from outside</button>
        <script>
        v.muted = true;
        document.getElementById('play').addEventListener('click', (e) => { e.stopPropagation(); v.play(); });
        document.getElementById('outside').addEventListener('click', () => { v.play(); });
        document.getElementById('mute').addEventListener('click', () => { v.muted = true; say('muted-by-button'); });
        v.addEventListener('click', () => { v.muted = false; });
        </script>
        """

    /// Two seconds of a 64×64 h264 frame **with an AAC track of digital
    /// silence**, so a run is inaudible, from
    /// `ffmpeg -f lavfi -i anullsrc=r=22050:cl=mono -f lavfi -i color=c=0x1a1a1a:s=64x64:d=2:r=10 -shortest -c:v libx264 -profile:v baseline -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -b:a 8k -movflags +faststart`.
    /// Served, not inlined: WebKit's media player will not take a `data:` URL.
    static let video = Data(base64Encoded: """
        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
        AAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4x
        LjEwMQAAAAhmcmVlAAAD921kYXTcAExhdmM2My4xLjEwMQACMEAOAAACVAYF//9Q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3Jl
        IDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93
        d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6
        MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0x
        IHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRo
        cmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBi
        bHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21p
        bj0xMCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTQwLjAgcWNvbXA9MC42MCBxcG1pbj0w
        IHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAAFmWIhDomKAAIEMnJyddddddddddddeABGCAHARggBwEY
        IAcAAAAGQZogEaCMARggBwEYIAcAAAAGQZpAEqCMARggBwEYIAcAAAAGQZpgEqCMARggBwEYIAcAAAAGQZqAEqCMARggBwEYIAcA
        AAAGQZqgEqCMARggBwEYIAcAAAAGQZrAEqCMARggBwEYIAcBGCAHAAAABkGa4BKgjAEYIAcBGCAHAAAABkGbABKgjAEYIAcBGCAH
        AAAABkGbIBKgjAEYIAcBGCAHAAAABkGbQBKgjAEYIAcBGCAHAAAABkGbYBKgjAEYIAcBGCAHAAAABkGbgBKgjAEYIAcBGCAHAAAA
        BkGboBKgjAEYIAcBGCAHARggBwAAAAZBm8ASoIwBGCAHARggBwAAAAZBm+ASoIwBGCAHARggBwAAAAZBmgASoIwBGCAHARggBwAA
        AAZBmiASoIwBGCAHARggBwAAAAZBmkASoIwBGCAHARggBwAAAAZBmmASoIwBGCAHARggBw==
        """, options: .ignoreUnknownCharacters)!
}
