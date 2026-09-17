import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Picture-in-picture, proven in real WebKit rather than argued.
///
/// WebKit's page setting `allowsPictureInPictureMediaPlayback` is false on
/// macOS unless the embedder says otherwise, and the only way to say so is
/// SPI on `WKPreferences` (`WebPaneController.enablePictureInPicture`). What a
/// page reads is `video.webkitSupportsPresentationMode('picture-in-picture')`,
/// which is what YouTube's and Vimeo's PiP buttons and the native controls'
/// glyph all sit on — so that is what is checked, on a real `<video>` with a
/// loaded source from a loopback site, in a pane and in a popup's page.
///
/// **A PiP window is never opened in the default run.** It would land on the
/// owner's display. `MAXPANE_PIP=1` runs the one test that does, which is how
/// "a PiP window outlives the pane's eviction and its lane's close" was
/// measured for `docs/acceptance.md`.
@Suite("picture-in-picture, in real WebKit", .serialized)
@MainActor
struct WebPictureInPictureTests {
    @Test("the preference is on, and a loaded video says it can go to picture-in-picture")
    func supportsPresentationMode() async throws {
        try await PiPFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            let preferences = web.configuration.preferences
            // The SPI is still there — if this fails, WebKit renamed it and the
            // guard in `enablePictureInPicture` is quietly leaving PiP off.
            #expect(preferences.responds(to: PiPFixture.setter))
            #expect(preferences.value(forKey: WebPaneController.pictureInPictureKey) as? Bool == true)

            #expect(await f.loaded())
            #expect(await f.js("document.pictureInPictureEnabled") as? Bool == true)
            #expect(await f.js("v.webkitSupportsPresentationMode('inline')") as? Bool == true)
            #expect(await f.js("v.webkitSupportsPresentationMode('picture-in-picture')") as? Bool == true)
            #expect(await f.js("v.webkitPresentationMode") as? String == "inline")
        }
    }

    @Test("WebKit's own default is off, and the guard reports what it did")
    func bareDefaultAndGuard() {
        let bare = WKPreferences()
        // No profile guard: nothing here spawns a content process or names a jar.
        guard bare.responds(to: PiPFixture.setter) else {
            // A WebKit without the SPI: the guard must decline, not raise.
            #expect(!WebPaneController.enablePictureInPicture(on: bare))
            return
        }
        // The reason the switch exists: false until the embedder says so.
        #expect(bare.value(forKey: WebPaneController.pictureInPictureKey) as? Bool == false)
        #expect(WebPaneController.enablePictureInPicture(on: bare))
        #expect(bare.value(forKey: WebPaneController.pictureInPictureKey) as? Bool == true)
    }

    @Test("a popup's page inherits it from the pane's configuration")
    func popupInherits() async throws {
        try await PopupFixture.with { f in
            #expect(await f.openerReady())
            let web = try #require(f.controller.webView)
            #expect(await f.js(web, "signIn('\(f.provider.origin)/provider?token=x', 'auth')") as? Int == 1)
            let dialog = try #require(f.controller.popupDialog)
            let preferences = dialog.webView.configuration.preferences
            #expect(preferences.value(forKey: WebPaneController.pictureInPictureKey) as? Bool == true)
            #expect(await f.eventually { await f.js(dialog.webView, "document.pictureInPictureEnabled") as? Bool == true })
        }
    }

    /// The one test that puts a window on the display. It enters PiP through
    /// `evaluateJavaScript`, which WebKit runs with a user gesture, then does
    /// to the pane exactly what the strip does: `evict()` under memory
    /// pressure (ADR-0003), and `tearDown()` when its lane closes. Eviction
    /// must decline while the video is in PiP and go ahead once it is back
    /// inline; the page's own fullscreen request must still fill the pane
    /// while PiP is up; and a lane closing under a PiP video must take the
    /// window with it and nothing else — no crash, no orphan window. The
    /// measurements are in `docs/acceptance.md`.
    @Test("MAXPANE_PIP: a video in picture-in-picture, through eviction and the lane's close")
    func throughEvictionAndClose() async throws {
        guard ProcessInfo.processInfo.environment["MAXPANE_PIP"] != nil else {
            print("SKIPPED the picture-in-picture window: MAXPANE_PIP=1 runs it, and it puts a PiP window on the display")
            return
        }
        try await PiPFixture.with { f in
            #expect(await f.ready())
            #expect(await f.loaded())
            let before = PiPFixture.pipWindows()
            let ownersBefore = PiPFixture.owners()
            #expect(await f.call("await v.play(); return v.paused") as? Bool == false)
            let entered = await f.call("await v.requestPictureInPicture(); return v.webkitPresentationMode")
            #expect(entered as? String == "picture-in-picture", "\(String(describing: entered))")
            #expect(await f.js("document.pictureInPictureElement === v") as? Bool == true)
            #expect(await f.eventually { await f.js("events.join('|')") as? String == "webkitpresentationmodechanged:picture-in-picture|enterpictureinpicture:picture-in-picture" })
            // What the display shows is WebKit's and PIPAgent's business, and a
            // `swift test` process may not see it at all: printed, not asserted.
            _ = await f.eventually(2) { PiPFixture.pipWindows() > before }
            print("PIP: entered; \(PiPFixture.pipWindows() - before) new PiP window(s) among \(PiPFixture.owners().count) window owners (new: \(PiPFixture.owners().subtracting(ownersBefore).sorted())), video \(await f.js("v.paused") as? Bool == false ? "playing" : "paused")")

            // The page's first fullscreen request fills the pane, as without PiP.
            #expect(await f.call("await box.requestFullscreen(); return 'resolved'") as? String == "resolved")
            #expect(await f.eventually { f.controller.isPaneFullscreen })
            #expect(await f.js("v.webkitPresentationMode") as? String == "picture-in-picture")
            _ = await f.call("await document.exitFullscreen()")
            #expect(await f.eventually { !f.controller.isPaneFullscreen })

            // Eviction declines while the video is in PiP: the window is the
            // page's, and the page stays.
            #expect(await f.eventually { f.controller.isInPictureInPicture })
            f.controller.evict()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            #expect(f.controller.webView != nil)
            #expect(PiPFixture.pipWindows() - before == 1)
            #expect(await f.js("v.webkitPresentationMode") as? String == "picture-in-picture")
            print("PIP: eviction asked while in PiP: \(PiPFixture.pipWindows() - before) window(s) up, web view kept")

            // Back inline — the PiP window's ✕, in effect — and the next plan
            // reclaims it.
            #expect(await f.call("await v.webkitSetPresentationMode('inline'); return v.webkitPresentationMode") as? String == "inline")
            #expect(await f.eventually { !f.controller.isInPictureInPicture })
            f.controller.evict()
            #expect(await f.eventually { f.controller.webView == nil })
            #expect(await f.eventually { PiPFixture.pipWindows() == before })

            // And a lane closing under a PiP video: the page goes, and with it
            // the window — printed, since that is WebKit's behaviour, not ours.
            f.controller.rehydrate()
            #expect(await f.ready())
            #expect(await f.loaded())
            // The request goes first in its call: the user gesture a call
            // carries covers its synchronous part, and an `await v.play()`
            // ahead of it spends it (`NotAllowedError`, measured).
            _ = await f.call("await v.play()")
            var again: Any?
            let reentered = await f.eventually {
                again = await f.call("const p = v.requestPictureInPicture(); try { await p } catch (e) { return String(e) } return v.webkitPresentationMode")
                return again as? String == "picture-in-picture"
            }
            #expect(reentered, "\(String(describing: again))")
            #expect(await f.eventually { PiPFixture.pipWindows() > before })

            // The lane closes: what the strip does to the controller.
            try f.store.closeLane(f.laneId)
            f.controller.tearDown()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("PIP: after the lane's close, \(PiPFixture.pipWindows() - before) window(s) up; the process is alive")
            #expect(await f.eventually { PiPFixture.pipWindows() == before })
        }
    }
}

@MainActor
final class PiPFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    let laneId: String
    let window: NSWindow

    /// The SPI setter KVC resolves `allowsPictureInPictureMediaPlayback` to.
    static let setter = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")

    /// Skipped outside `./scripts/test.sh` for the reason every real-WebKit
    /// suite is: a test process with no profile names the owner's cookie jars.
    static func with(_ body: (PiPFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED picture-in-picture in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await PiPFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        site = try await LocalSite(
            pages: ["/page": Self.page],
            files: ["/tiny.mp4": (type: "video/mp4", data: Self.video)])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-pip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        laneId = lane.id
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

    func call(_ script: String) async -> Any? {
        guard let web = controller.webView else { return nil }
        do {
            return try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            return "error: \(error)"
        }
    }

    func ready() async -> Bool {
        await eventually { await js("document.readyState === 'complete' ? 1 : 0") as? Int == 1 }
    }

    /// The video has a frame, so WebKit's player can answer. Measured: at
    /// `loadedmetadata` (`readyState` 1) `webkitSupportsPresentationMode` is
    /// still false; it is true once the player has current data.
    func loaded() async -> Bool {
        await eventually { await js("v.readyState >= 2 && v.videoWidth > 0") as? Bool == true }
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    /// PiP windows on the display. macOS draws them from its own agent, whose
    /// windows are owned by "Picture in Picture", not by the app, so they are
    /// counted by owner name.
    static func pipWindows() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { $0[kCGWindowOwnerName as String] as? String == "Picture in Picture" }.count
    }

    static func owners() -> Set<String> {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowOwnerName as String] as? String).map { "\($0)" } })
    }

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static let page = """
        <!doctype html><title>pip</title>
        <style>body{margin:0} #box{width:100px;height:100px;background:#333}</style>
        <video id="v" src="/tiny.mp4" muted playsinline preload="auto" controls loop width="64" height="64"></video>
        <div id="box"></div>
        <script>
        const v = document.getElementById('v'); const box = document.getElementById('box');
        const events = [];
        for (const e of ['webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture'])
          v.addEventListener(e, () => events.push(e + ':' + v.webkitPresentationMode));
        </script>
        """

    /// One second of a 64×64 h264 frame, from
    /// `ffmpeg -f lavfi -i color=c=0x1a1a1a:s=64x64:d=1:r=10 -c:v libx264 -pix_fmt yuv420p -movflags +faststart`.
    /// Served, not inlined: WebKit's media player will not take a `data:` URL.
    static let video = Data(base64Encoded: """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANKbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        AnV0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAAAAABAAAAAAHtbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABmG1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVhzdGJsAAAAuHN0c2QA
        AAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4
        MjY0AAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAFmdCwAraEJsBEAAAAwAQAAADAUDxImoBAAVozgOcgAAAABBwYXNwAAAA
        AQAAAAEAAAAUYnRydAAAAAAAABZgAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAKAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0
        c2MAAAAAAAAAAQAAAAEAAAAKAAAAAQAAADxzdHN6AAAAAAAAAAAAAAAKAAACcgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA
        AAAKAAAACgAAABRzdGNvAAAAAAAAAAEAAAN6AAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAA
        AAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMQAAAAhmcmVlAAAC1G1kYXQAAAJUBgX//1Dc
        Rem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29w
        eWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9
        MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVm
        PTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNr
        aXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0w
        IGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWln
        aHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEwIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBj
        cmY9NDAuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0wAIAAAAAWZYiEOiYo
        AAgQycnJ1111111111114AAAAAZBmiARoIwAAAAGQZpAEqCMAAAABkGaYBKgjAAAAAZBmoASoIwAAAAGQZqgEqCMAAAABkGawBKg
        jAAAAAZBmuASoIwAAAAGQZsAEqCMAAAABkGbIBKgjA==
        """, options: .ignoreUnknownCharacters)!
}
