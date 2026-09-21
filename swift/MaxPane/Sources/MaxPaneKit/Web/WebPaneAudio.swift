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
/// ADR-0034; the audio indicators are the intended caller.
@MainActor
enum WebPaneAudio {
    /// The KVO key path for "this view is making sound".
    static let playingAudioKey = "_isPlayingAudio"
    static let mutedStateKey = "_mediaMutedState"
    /// KVC's spelling for `_setPageMuted:` — it tries `_set<Key>:` itself.
    static let pageMutedKey = "pageMuted"
    static let setPageMuted = NSSelectorFromString("_setPageMuted:")
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
}
