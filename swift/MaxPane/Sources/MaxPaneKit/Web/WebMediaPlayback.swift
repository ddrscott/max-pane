import WebKit

/// What a page may play without being asked, and what a click on Play means.
///
/// Two halves, both measured in `WebMediaPlaybackTests` before either was
/// written (ADR-0034):
///
/// - **Sound needs a gesture.** `WKWebViewConfiguration` on macOS defaults
///   `mediaTypesRequiringUserActionForPlayback` to none, so a page that called
///   `play()` on load played *with sound*, and a strip restores a dozen pages
///   at launch. `.audio` is Safari's default: `play()` without a gesture is
///   refused with `NotAllowedError` while the element has sound, a muted
///   `play()` still runs, and a click plays with sound at once.
/// - **A click on Play plays with sound.** A mobile player (m.youtube.com, in a
///   Mobile Layout pane) mutes its own `<video>` before it starts, because on a
///   phone that is the only autoplay it can get, and shows TAP TO UNMUTE. With
///   a mouse that is two clicks: Play, then the video. The script lifts a mute
///   *the page* set when *the person* starts that element: `play()` called
///   within a second of a trusted click that landed inside the element's box,
///   while user activation is live. A mute made during a gesture is the
///   person's (the site's own mute button) and is left alone; so is a video
///   that is already playing muted, and one nobody clicked on.
enum WebMediaPlayback {
    /// Set on the configuration, because WebKit reads it when the view is made:
    /// a changed setting reaches panes built after it. A popup's configuration
    /// is copied from the pane's and inherits it.
    static func apply(_ policy: WebAutoplay, to configuration: WKWebViewConfiguration) {
        configuration.mediaTypesRequiringUserActionForPlayback = mediaTypesRequiringUserAction(policy)
    }

    static func mediaTypesRequiringUserAction(_ policy: WebAutoplay) -> WKAudiovisualMediaTypes {
        switch policy {
        case .gesture: return .audio
        case .allow: return []
        }
    }

    /// In the page's own world, because it replaces `play` and the `muted`
    /// setter on the prototype the page uses; every frame, because an embedded
    /// player is a frame; document start, so it is there before the player.
    static let source = #"""
        (() => {
          const proto = window.HTMLMediaElement && HTMLMediaElement.prototype;
          const muted = proto && Object.getOwnPropertyDescriptor(proto, 'muted');
          const nativePlay = proto && proto.play;
          if (!muted || !muted.set || !nativePlay) return;
          // Elements the person muted: `muted = true` during a gesture.
          const byPerson = new WeakSet();
          let click = null;
          const active = () => { try { return navigator.userActivation.isActive; } catch (e) { return false; } };
          for (const type of ['pointerdown', 'mousedown', 'click']) {
            window.addEventListener(type, (e) => {
              if (e.isTrusted) click = { at: performance.now(), x: e.clientX, y: e.clientY };
            }, true);
          }
          Object.defineProperty(proto, 'muted', {
            configurable: true, enumerable: muted.enumerable, get: muted.get,
            set(value) {
              if (value && active()) byPerson.add(this); else if (!value) byPerson.delete(this);
              muted.set.call(this, value);
            },
          });
          const startedByClickOn = (el) => {
            if (!click || performance.now() - click.at > 1000 || !active()) return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0
              && click.x >= r.left && click.x <= r.right && click.y >= r.top && click.y <= r.bottom;
          };
          proto.play = function () {
            let lifted = false;
            try {
              if (muted.get.call(this) && this.paused && !byPerson.has(this) && startedByClickOn(this)) {
                muted.set.call(this, false);
                lifted = true;
              }
            } catch (e) {}
            const result = nativePlay.apply(this, arguments);
            if (!lifted || !result || !result.catch) return result;
            // WebKit's gesture check and `userActivation` are two mechanisms.
            // Where they disagree, give the page back the muted play it asked for.
            const el = this;
            return result.catch((error) => {
              if (!error || error.name !== 'NotAllowedError') throw error;
              muted.set.call(el, true);
              return nativePlay.call(el);
            });
          };
        })();
        """#

    /// Idempotent for the reason `WebNotifications.install` is. No message
    /// handler: the script tells the shell nothing.
    @MainActor
    static func install(on webView: WKWebView) {
        let content = webView.configuration.userContentController
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
}
