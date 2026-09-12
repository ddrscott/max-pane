import Foundation
import WebKit

/// Where a link goes, before you click it.
///
/// The one thing on the bar's list with no AppKit answer at all. Legacy WebKit
/// had `webView(_:mouseDidMoveOverElement:modifierFlags:)`; `WKWebView` has
/// nothing, and no delegate callback anywhere reports a hovered element. So the
/// page is asked: two capturing listeners that post the anchor's resolved
/// `href` up to the shell.
///
/// The cost is one message per *change* of hovered link, not one per mouse
/// move — the script holds the last value and stays silent otherwise. A page
/// with a dense link grid would otherwise send a few hundred messages a second
/// across the JS bridge for a string that has not changed.
enum LinkHoverProbe {
    /// The name both the handler and the script agree on.
    static let channel = "maxpaneHoveredLink"

    static let source = """
        (function () {
          if (window.__maxpaneHoverProbe) return;
          window.__maxpaneHoverProbe = true;
          var last = null;
          function post(value) {
            if (value === last) return;
            last = value;
            try { window.webkit.messageHandlers.\(channel).postMessage(value); } catch (e) {}
          }
          function anchor(event) {
            var node = event.target;
            if (!node || !node.closest) return null;
            return node.closest('a[href], area[href]');
          }
          // Capturing, because a page that stops propagation on its own links —
          // every card-shaped UI on the web — would otherwise never report one.
          document.addEventListener('mouseover', function (e) {
            var a = anchor(e);
            post(a ? a.href : '');
          }, true);
          document.addEventListener('mouseout', function (e) {
            if (anchor(e)) post('');
          }, true);
          // The pointer can leave through the window rather than through a
          // mouseout, and a status line still naming a link nobody is pointing
          // at is worse than an empty one.
          window.addEventListener('blur', function () { post(''); }, true);
          document.addEventListener('scroll', function () { post(''); }, true);
        })();
        """

    /// Install the script and the handler on a web view, whoever built it.
    ///
    /// Idempotent on purpose. An adopted popup arrives carrying the opener's
    /// `WKUserContentController`, already holding this handler — and
    /// `add(_:name:)` with a name already in use raises an Objective-C
    /// exception, which in Swift is not a thrown error but a dead process.
    @MainActor
    static func install(on webView: WKWebView, handler: WKScriptMessageHandler) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: channel)
        content.add(handler, name: channel)
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        // `forMainFrameOnly: false` — half the links worth previewing are in an
        // iframe, and a status line that goes blank over an embedded comment
        // thread is the one that teaches you not to trust it.
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    @MainActor
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
    }
}

/// Holds the script-message handler WebKit keeps a strong reference to.
///
/// `WKUserContentController` retains its handlers for the life of the content
/// controller, so a controller that registered itself would never deallocate —
/// and a web pane holds a `WKWebView`, which holds the configuration, which
/// holds the controller. The cycle is complete and silent. So the handler is
/// this object instead, and the callback it is built with must capture its
/// owner weakly — that `[weak self]` is the only thing keeping the cycle broken.
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    private let body: @MainActor (Any) -> Void

    init(_ body: @escaping @MainActor (Any) -> Void) {
        self.body = body
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { body(message.body) }
    }
}
