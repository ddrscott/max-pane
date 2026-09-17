import WebKit

/// Whether a page has a video in picture-in-picture, so the pane knows.
///
/// A PiP window belongs to the page's process: measured in
/// `WebPictureInPictureTests`, destroying the web view under one closes the
/// window mid-sentence. Eviction (ADR-0003) destroys web views by design, on
/// every scroll settle under memory pressure, and the pane you are half
/// watching in the corner is exactly the one that is scrolled off the strip. So
/// the page reports its presentation mode to the pane, and `evict()` treats a
/// page in PiP the way it treats a page asking a question: not idle memory.
///
/// The events are the standard ones, which WebKit fires alongside its own
/// `webkitpresentationmodechanged`. Neither bubbles, so the listener is on the
/// document in the capture phase, where a non-bubbling event still passes.
/// Every frame, because an embedded player enters PiP from its own frame.
enum WebPictureInPicture {
    static let channel = "maxpanePictureInPicture"

    static let source = #"""
        (() => {
          const post = (on) => {
            try { webkit.messageHandlers.maxpanePictureInPicture.postMessage(on ? 1 : 0); } catch (e) {}
          };
          document.addEventListener('enterpictureinpicture', () => post(true), true);
          document.addEventListener('leavepictureinpicture', () => post(false), true);
          // A page going away takes its window with it either way; say so, so
          // the pane is not left believing in a PiP that no longer exists.
          window.addEventListener('pagehide', () => post(false));
        })();
        """#

    /// `true` for entering, `false` for leaving, nil for anything else.
    static func isEntering(_ body: Any) -> Bool? {
        switch body {
        case let n as NSNumber: return n.intValue != 0
        case let b as Bool: return b
        default: return nil
        }
    }

    /// Install the script and the handler on a web view. Idempotent for the
    /// reason `WebNotifications.install` is.
    @MainActor
    static func install(on webView: WKWebView, handler: WKScriptMessageHandler) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: channel)
        content.add(handler, name: channel)
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    @MainActor
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
    }
}
