import AppKit
import LanedCore
import Testing
import WebKit
@testable import MaxPaneKit

/// A pane knows whether it is making sound, and can be muted and turned down,
/// in real WebKit (ADR-0035). `MediaFixture`'s video has an audio track of
/// digital silence, so nothing here is audible.
///
/// What is measured, and what is not. `_isPlayingAudio` and the mute are read
/// back from WebKit. The **volume** is not readable from anywhere: WebKit has
/// no getter, and the page cannot see it (that is the point: `v.volume` is
/// the page's own slider, and the pane's level multiplies it in WebCore).
/// These tests pin that the selector exists and is taken, that the page's own
/// volume is left alone, that playback and the speaker survive it, and the
/// pane's own bookkeeping around zero. That the sound actually gets quieter
/// is the owner's check, by ear (README, *Sound*). **Web Audio
/// (`AudioContext`) is not covered by the volume**, by WebCore's design; the
/// mute covers it.
@Suite("a pane's sound, in real WebKit", .serialized)
@MainActor
struct WebPaneAudioTests {
    /// Short, so a test of "clears after the hold" is not a two second wait.
    private static let hold: TimeInterval = 0.4

    private func play(_ f: MediaFixture) async throws -> WKWebView {
        f.store.audio.hold = Self.hold
        let web = try #require(f.controller.webView)
        f.open("/handler")
        #expect(await f.eventually { f.beacons.contains("loaded") })
        try await f.click("v")
        #expect(await f.eventually { f.store.audio.state(of: f.controller.paneId).playing }, "\(f.beacons)")
        return web
    }

    @Test("playing flips the pane to audible by KVO, pausing clears it only after the hold")
    func playingAndTheHold() async throws {
        try await MediaFixture.with { f in
            let audio = f.store.audio
            let pane = f.controller.paneId
            #expect(audio.mark(of: pane) == .silent)
            var changes = 0
            let token = audio.observe { changes += 1 }
            _ = try await play(f)
            #expect(audio.mark(of: pane) == .audible)
            #expect(f.controller.chrome.audioMark == .audible)
            #expect(changes >= 1, "observers hear about it without polling")

            _ = await f.js("v.pause()")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(f.controller.webView!) == false })
            // Still shown: a half-second blip must not flicker the header.
            #expect(audio.mark(of: pane) == .audible)
            #expect(await f.eventually(3) { audio.mark(of: pane) == .silent })
            audio.stopObserving(token)
        }
    }

    @Test("a blip shorter than the hold is one appearance: playing again inside it cancels the clearing")
    func blip() async throws {
        try await MediaFixture.with { f in
            _ = try await play(f)
            let audio = f.store.audio
            var marks: [AudioMark] = []
            let token = audio.observe { marks.append(audio.mark(of: f.controller.paneId)) }
            _ = await f.js("v.pause()")
            try? await Task.sleep(nanoseconds: 100_000_000)
            _ = await f.js("v.play()")
            try? await Task.sleep(nanoseconds: UInt64((Self.hold + 0.4) * 1_000_000_000))
            #expect(audio.mark(of: f.controller.paneId) == .audible)
            #expect(!marks.contains(.silent), "\(marks)")
            audio.stopObserving(token)
        }
    }

    @Test("mute silences without pausing and the mark says muted, playing or not; unmute restores; it is written to the ledger")
    func mute() async throws {
        try await MediaFixture.with { f in
            let web = try await play(f)
            let audio = f.store.audio
            let pane = f.controller.paneId
            audio.toggleMute(pane: pane)
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == true })
            #expect(audio.mark(of: pane) == .muted)
            #expect(f.controller.chrome.audioMark == .muted)
            #expect(await f.js("!v.paused && !v.muted") as? Bool == true, "muting never pauses, and the page cannot see it")
            // Stays, for as long as it is muted: a muted lane that shows
            // nothing is a lane you forget you muted.
            _ = await f.js("v.pause()")
            try? await Task.sleep(nanoseconds: UInt64((Self.hold + 0.3) * 1_000_000_000))
            #expect(audio.mark(of: pane) == .muted)
            // The ledger has it, for the next launch.
            let reopened = try StripStore(ledgerPath: f.dir.appendingPathComponent("ledger.db").path)
            #expect(reopened.state.lanes.first?.panes.first?.muted == true)

            audio.toggleMute(pane: pane)
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == false })
            #expect(audio.mark(of: pane) == .silent)
        }
    }

    @Test("a muted pane that is evicted and rehydrated comes back muted, before its page can make a sound; so does a private one")
    func evictionKeepsTheMute() async throws {
        for isPrivate in [false, true] {
            try await MediaFixture.with(isPrivate: isPrivate) { f in
                let audio = f.store.audio
                audio.setMuted(true, pane: f.controller.paneId)
                audio.setVolume(40, pane: f.controller.paneId)
                audio.setMuted(true, pane: f.controller.paneId)
                f.controller.evict()
                #expect(await f.eventually { f.controller.webView == nil })
                #expect(audio.mark(of: f.controller.paneId) == .muted)
                f.controller.rehydrate()
                let web = try #require(f.controller.webView)
                #expect(WebPaneAudio.isMuted(web) == true, "muted as it is built, not after the first frame")
                #expect(audio.state(of: f.controller.paneId).volume == 40)
            }
        }
    }

    @Test("a pane you are listening to is not idle memory: it is not evicted while audible")
    func audibleIsNotEvicted() async throws {
        try await MediaFixture.with { f in
            _ = try await play(f)
            f.controller.evict()
            #expect(f.controller.webView != nil)
        }
    }

    @Test("a popup's audio reports on the pane that opened it, and the pane's mute reaches the popup")
    func popupAudioBelongsToItsOpener() async throws {
        try await MediaFixture.with { f in
            f.store.audio.hold = Self.hold
            let audio = f.store.audio
            let pane = f.controller.paneId
            f.open("/opener")
            #expect(await f.eventually { await f.js("typeof openPopup === 'function' ? 1 : 0") as? Int == 1 })
            #expect(await f.js("openPopup()") as? Int == 1)
            let dialog = try #require(f.controller.popupDialog)
            let popup = dialog.webView
            #expect(await f.eventually {
                (try? await popup.evaluateJavaScript("typeof v !== 'undefined' && v.readyState >= 2 ? 1 : 0")) as? Int == 1
            })
            _ = try? await popup.evaluateJavaScript("v.play(); 1")
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(popup) == true })
            #expect(WebPaneAudio.isPlayingAudio(try #require(f.controller.webView)) == false)
            #expect(await f.eventually { audio.mark(of: pane) == .audible }, "the opener is where a person would look")

            audio.setMuted(true, pane: pane)
            #expect(await f.eventually { WebPaneAudio.isMuted(popup) == true })
            audio.setMuted(false, pane: pane)

            dialog.dismiss(returningFocus: false)
            #expect(await f.eventually(4) { audio.mark(of: pane) == .silent }, "a closed popup stops counting")
        }
    }

    @Test("volume: WebKit takes it, the page's own slider is left alone and playback goes on; a late element needs nothing; Web Audio is NOT covered")
    func volume() async throws {
        try await MediaFixture.with { f in
            let web = try await play(f)
            let audio = f.store.audio
            let pane = f.controller.paneId
            // If this fails WebKit dropped the selector: the slider hides
            // itself (`volumeIsSupported`) and the mute still works.
            #expect(web.responds(to: WebPaneAudio.setMediaVolume))
            #expect(WebPaneAudio.volumeIsSupported)
            #expect(WebPaneAudio.setVolume(0.3, on: web))

            audio.setVolume(30, pane: pane)
            try? await Task.sleep(nanoseconds: 400_000_000)
            // The page's own volume is its own: the pane's level multiplies
            // it inside WebCore, so the site's slider still means something
            // and a page that sets its own volume does not escape.
            #expect(await f.js("v.volume") as? Double == 1)
            _ = await f.js("v.volume = 0.5")
            #expect(await f.js("v.volume") as? Double == 0.5)
            #expect(await f.js("!v.paused") as? Bool == true)
            #expect(WebPaneAudio.isPlayingAudio(web) == true, "turned down is still audible")
            #expect(audio.state(of: pane) == PaneAudio(playing: true, muted: false, volume: 30))

            // A media element added after the fact: nothing to re-apply, the
            // level is the page's, not the element's.
            f.open("/late")
            #expect(await f.eventually { await f.js("typeof addLater === 'function' ? 1 : 0") as? Int == 1 })
            _ = try? await web.callAsyncJavaScript("return await addLater()", contentWorld: .page)
            #expect(await f.eventually { WebPaneAudio.isPlayingAudio(web) == true })
            #expect(audio.state(of: pane).volume == 30)
        }
    }

    @Test("zero reads as muted, and unmuting returns to the last level that was not zero")
    func zeroIsMute() async throws {
        try await MediaFixture.with { f in
            let web = try await play(f)
            let audio = f.store.audio
            let pane = f.controller.paneId
            audio.setVolume(60, pane: pane)
            // A drag down to zero passes 1 % on the way; it is not the level
            // to come back to.
            for step in [40, 12, 1, 0] { audio.setVolume(step, pane: pane, restoring: 60) }
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == true })
            #expect(audio.state(of: pane).effectiveVolume == 0)
            #expect(audio.mark(of: pane) == .muted)
            audio.toggleMute(pane: pane)
            #expect(await f.eventually { WebPaneAudio.isMuted(web) == false })
            #expect(audio.state(of: pane).volume == 60)
            // And dragging up from zero unmutes.
            audio.setVolume(0, pane: pane)
            audio.setVolume(25, pane: pane)
            #expect(audio.state(of: pane) == PaneAudio(playing: true, muted: false, volume: 25))
            let reopened = try StripStore(ledgerPath: f.dir.appendingPathComponent("ledger.db").path)
            #expect(reopened.state.lanes.first?.panes.first?.volume == 25)
        }
    }
}
