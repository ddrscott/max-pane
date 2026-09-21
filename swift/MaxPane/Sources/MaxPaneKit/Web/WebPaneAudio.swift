import WebKit

/// Whether a web view is making sound, and whether it has been muted.
///
/// WebKit's public API has no answer: `requestMediaPlaybackState` says
/// playing, paused or suspended, and a muted video is "playing". What Safari's
/// tab speaker reads is SPI on `WKWebView`, and that is what this reads:
///
/// - `_isPlayingAudio` — true while an element with an audio track is playing
///   unmuted at a volume above zero. Measured in `WebMediaPlaybackTests`: false
///   for a paused video, false for one the *page* muted, true a moment after a
///   click starts it, and **still true while the page is muted from here**
///   (`_setPageMuted:`), which is why Safari can show a muted speaker. It is
///   KVO-observable under `playingAudioKey`.
/// - `_mediaMutedState` / `_setPageMuted:` — the mute the embedder owns, a
///   bit set whose first bit is audio. It silences; it does not pause, and
///   the page cannot see it (`video.muted` stays false).
///
/// Every call is guarded the way picture-in-picture's key is
/// (`WebPaneController.enablePictureInPicture`): KVC on a key nothing answers
/// raises `NSUnknownKeyException`, which Swift cannot catch, so the selector is
/// looked for first and a WebKit that drops it answers nil, "unknown", never a
/// crash. `WebMediaPlaybackTests` pins that the selectors still exist.
/// ADR-0034; the audio indicators (ADR-0035) are the caller.
///
/// - `_setMediaVolumeForTesting:` — the page's media volume, 0 to 1. The name
///   is WebKit's filing, not its behaviour: disassembled on macOS 26 it is a
///   tail call into `WebPageProxy::setMediaVolume`, the same page-level
///   multiplier legacy `WebView.setMediaVolume:` exposed, which WebCore folds
///   into every media element's effective volume (`HTMLMediaElement::
///   effectiveVolume` is the element's own volume times the page's). So it
///   covers every `<video>` and `<audio>` in every frame, ones added later
///   included, it multiplies the page's own slider rather than overwriting
///   it, the page cannot see or undo it, and it is re-sent to a web process
///   that is relaunched. What it does **not** reach: Web Audio
///   (`AudioContext`), and an element routed through a
///   `MediaElementAudioSourceNode`, which WebCore exempts by name. Mute
///   covers both. There is no getter, so the pane remembers what it set.
@MainActor
enum WebPaneAudio {
    /// The KVO key path for "this view is making sound".
    static let playingAudioKey = "_isPlayingAudio"
    static let mutedStateKey = "_mediaMutedState"
    /// KVC's spelling for `_setPageMuted:` — it tries `_set<Key>:` itself.
    static let pageMutedKey = "pageMuted"
    static let setPageMuted = NSSelectorFromString("_setPageMuted:")
    static let setMediaVolume = NSSelectorFromString("_setMediaVolumeForTesting:")
    /// `_WKMediaAudioMuted`.
    static let audioMutedBit: UInt = 1 << 0

    /// Nil when this WebKit no longer says.
    static func isPlayingAudio(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: NSSelectorFromString(playingAudioKey)) else { return nil }
        return (webView.value(forKey: playingAudioKey) as? NSNumber)?.boolValue
    }

    /// Whether the embedder's mute is on. Nil when this WebKit no longer says.
    static func isMuted(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: NSSelectorFromString(mutedStateKey)),
              let state = webView.value(forKey: mutedStateKey) as? NSNumber
        else { return nil }
        return state.uintValue & audioMutedBit != 0
    }

    /// Silence the page without pausing it. Returns whether WebKit took it.
    @discardableResult
    static func setMuted(_ muted: Bool, on webView: WKWebView) -> Bool {
        guard webView.responds(to: setPageMuted) else {
            Log.debug("WKWebView has no _setPageMuted:; the pane cannot be muted")
            return false
        }
        webView.setValue(NSNumber(value: muted ? audioMutedBit : 0), forKey: pageMutedKey)
        return true
    }

    /// Whether this WebKit can turn a page down. The slider is only offered
    /// when it can: a slider that moves and changes nothing is worse than none.
    static func canSetVolume(_ webView: WKWebView) -> Bool { webView.responds(to: setMediaVolume) }

    /// Whether any `WKWebView` can, for a surface with no web view to hand.
    static var volumeIsSupported: Bool { WKWebView.instancesRespond(to: setMediaVolume) }

    /// The page's media volume, 0 to 1, multiplied into every media element's
    /// own. Returns whether WebKit took it. A `float` argument, which KVC
    /// cannot spell for a selector that is not a setter, so it is called
    /// through its implementation.
    @discardableResult
    static func setVolume(_ volume: Double, on webView: WKWebView) -> Bool {
        guard webView.responds(to: setMediaVolume), let method = webView.method(for: setMediaVolume) else {
            Log.debug("WKWebView has no _setMediaVolumeForTesting:; the pane's volume cannot be set")
            return false
        }
        typealias Call = @convention(c) (AnyObject, Selector, Float) -> Void
        unsafeBitCast(method, to: Call.self)(webView, setMediaVolume, Float(min(max(volume, 0), 1)))
        return true
    }
}

/// Watches one web view's `_isPlayingAudio`.
///
/// KVO, measured: the key fires on play, on pause, and when the page takes its
/// own volume to zero and back. (`_mediaMutedState` does not fire, and does
/// not need to: the mute is the pane's own.) Classic `addObserver`, because
/// the key is a string WebKit does not declare and Swift's key-path observing
/// has no spelling for that. A WebKit without the selector is never observed,
/// so the pane reads as silent: unknown, never a crash.
@MainActor
final class WebAudioWatch: NSObject {
    private weak var webView: WKWebView?
    private let onChange: @MainActor (Bool) -> Void
    private var observing = false

    init(_ webView: WKWebView, onChange: @escaping @MainActor (Bool) -> Void) {
        self.webView = webView
        self.onChange = onChange
        super.init()
        guard webView.responds(to: NSSelectorFromString(WebPaneAudio.playingAudioKey)) else { return }
        webView.addObserver(self, forKeyPath: WebPaneAudio.playingAudioKey, options: [.initial, .new], context: nil)
        observing = true
    }

    /// Before the web view goes. Idempotent.
    func stop() {
        guard observing else { return }
        observing = false
        webView?.removeObserver(self, forKeyPath: WebPaneAudio.playingAudioKey)
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // The value is read when the hop lands, not carried across it: two
        // quick changes then cannot arrive out of order and leave a speaker on.
        Task { @MainActor [weak self] in
            guard let self, self.observing, let webView = self.webView else { return }
            self.onChange(WebPaneAudio.isPlayingAudio(webView) ?? false)
        }
    }
}
