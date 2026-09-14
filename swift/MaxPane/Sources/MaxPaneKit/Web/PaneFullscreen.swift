import Foundation
import WebKit

/// A page's full screen, answered inside its pane.
///
/// The owner, with YouTube saying *"Your browser doesn't support full screen"*:
/// *"I'd like to give the webview access to the pane's available area."* WebKit
/// leaves `isElementFullscreenEnabled` off, so the Fullscreen API did not exist
/// and every player either hid ⤢ or said the browser could not do it. Turning
/// the preference on gives WebKit's own full screen, which takes the whole
/// display — one step further than a column of a strip wants to go on a click.
///
/// So this script answers the API itself, in the page's own world (it has to
/// replace the page's prototypes), in every frame, before the page runs:
///
/// - **A request fills the pane.** The element goes into the top layer as a
///   manual popover, so no ancestor's `transform`, `overflow` or stacking
///   context can trap it, and is sized to the viewport — which is the web view,
///   which is the pane. Where a popover is impossible it is `position: fixed`
///   on top instead. `fullscreenchange` and `webkitfullscreenchange` fire at
///   the element, `document.fullscreenElement` names it, the promise resolves.
/// - **`:fullscreen` still matches, near enough.** Sites style their full
///   screen player through that selector, and a pseudo-class cannot be set from
///   script. So the readable style sheets' `:fullscreen` rules are copied once
///   onto `[data-maxpane-fullscreen]`, the attribute the pinned element wears.
///   An attribute and not a class because a framework re-rendering `className`
///   would wipe a class out from under a playing video.
/// - **One more step is WebKit's.** A request made while the pane is already
///   full screen, or with ⇧ held on the gesture behind it, goes to the native
///   function this script kept before the page could see it. ⇧ comes from the
///   event being dispatched, or from the last gesture a capturing listener saw,
///   since `requestFullscreen` carries no event.
/// - **Embedded players.** A cross-origin `<iframe>` can only fill its own
///   frame. The same script in the frame tells the one in its parent, which
///   pins the `<iframe>` element, and so on up. The parent checks the frame is
///   one of its own and that fullscreen is allowed to it.
/// - **Leaving.** `exitFullscreen`, Esc (taken from the page, as a browser
///   takes it), the element leaving the document, or WebKit's own full screen
///   ending — which returns the page to normal rather than to the pane.
///
/// Only the top frame speaks to the shell, with `{active}`; the pane hides its
/// chrome bar on that and nothing else. See ADR-0014.
enum PaneFullscreen {
    /// The name both the handler and the script agree on.
    static let channel = "maxpaneFullscreen"

    /// The attribute the pinned element wears.
    static let attribute = "data-maxpane-fullscreen"

    /// Ask the page to leave full screen, through its own API so an embedded
    /// player hears it the same way it would from its own ✕.
    static let exitScript = "if (document.fullscreenElement) document.exitFullscreen().catch(function () {}); 0"

    /// `{active: Bool}` from the top frame's script, or nil for anything else.
    static func isActive(_ body: Any) -> Bool? {
        (body as? [String: Any])?["active"] as? Bool
    }

    static let source = #"""
        (() => {
          if (Object.prototype.hasOwnProperty.call(window, '__maxpaneFullscreen')) return;
          Object.defineProperty(window, '__maxpaneFullscreen', { value: true });

          const CHANNEL = '\#(channel)';
          const TAG = '__maxpaneFullscreen';
          const PINNED = '\#(attribute)';
          const isTop = window.top === window;
          const E = Element.prototype;
          const D = Document.prototype;
          const V = window.HTMLVideoElement ? HTMLVideoElement.prototype : null;
          const getter = (proto, name) => {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            return d && d.get;
          };

          // WebKit's own, kept before the page can reach ours.
          const native = {
            request: E.requestFullscreen || E.webkitRequestFullscreen,
            exit: D.exitFullscreen || D.webkitExitFullscreen,
            element: getter(D, 'fullscreenElement') || getter(D, 'webkitFullscreenElement'),
            enabled: getter(D, 'fullscreenEnabled') || getter(D, 'webkitFullscreenEnabled'),
          };
          const nativeElement = () => {
            try { return native.element ? native.element.call(document) : null; } catch (e) { return null; }
          };
          // The frame's permissions policy, as WebKit reads it: false in a
          // cross-origin frame without allow="fullscreen", and false everywhere
          // if the preference is off, which makes this whole script inert.
          const allowed = () => {
            try { return !!(native.enabled && native.request && native.enabled.call(document)); } catch (e) { return false; }
          };

          let current = null;    // what this document shows full screen
          let forChild = false;  // `current` is an <iframe>, standing in for the document inside it
          let popover = false;   // `current` went into the top layer as a popover
          let nativeWasOn = false;
          let gesture = null;
          let watcher = null;

          const later = (fn) => setTimeout(fn, 0);

          // --- ⇧ on the gesture -------------------------------------------
          for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick', 'keydown', 'keyup']) {
            window.addEventListener(type, (e) => { gesture = { shift: !!e.shiftKey, at: Date.now() }; }, true);
          }
          const shiftHeld = () => {
            const e = window.event;
            if (e && typeof e.shiftKey === 'boolean') return e.shiftKey;
            return !!gesture && gesture.shift && Date.now() - gesture.at < 1000;
          };

          // --- style ---------------------------------------------------------
          let sheet = null;
          try {
            sheet = new CSSStyleSheet();
            sheet.replaceSync(`
              :not(html)[${PINNED}] {
                position: fixed !important; inset: 0 !important; margin: 0 !important;
                box-sizing: border-box !important; transform: none !important;
                min-width: 0 !important; max-width: none !important; width: 100% !important;
                min-height: 0 !important; max-height: none !important; height: 100% !important;
              }
              [${PINNED}="fixed"] { z-index: 2147483647 !important; }
              :where([${PINNED}][popover]) {
                border: 0; padding: 0; overflow: visible; color: inherit; background-color: transparent;
              }
              :where(video[${PINNED}]) { object-fit: contain; background-color: black; }
              [${PINNED}]::backdrop { background: black; }
            `);
          } catch (e) { sheet = null; }
          const adopt = (root) => {
            if (!sheet || !root || !('adoptedStyleSheets' in root)) return;
            try {
              if (!root.adoptedStyleSheets.includes(sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
            } catch (e) {}
          };
          const FULLSCREEN = /:(?:fullscreen|-webkit-full-screen)(?![-\w])/g;
          const walked = new WeakSet();
          const copyFrom = (rules, open, close) => {
            for (const rule of rules) {
              if (rule instanceof CSSStyleRule) {
                const selector = rule.selectorText || '';
                if (!selector.includes('full')) continue;
                const pinned = selector.replace(FULLSCREEN, `[${PINNED}]`);
                if (pinned === selector) continue;
                try { sheet.insertRule(`${open}${pinned}{${rule.style.cssText}}${close}`, sheet.cssRules.length); } catch (e) {}
              } else if (rule.cssRules && (rule instanceof CSSMediaRule || rule instanceof CSSSupportsRule)) {
                const head = rule.cssText.slice(0, rule.cssText.indexOf('{'));
                copyFrom(rule.cssRules, `${open}${head}{`, `}${close}`);
              } else if (rule.cssRules && window.CSSLayerBlockRule && rule instanceof CSSLayerBlockRule) {
                copyFrom(rule.cssRules, open, close);
              }
            }
          };
          const copyRules = (root) => {
            if (!sheet) return;
            for (const s of [...(root.styleSheets || []), ...(root.adoptedStyleSheets || [])]) {
              if (s === sheet || walked.has(s)) continue;
              walked.add(s);
              let rules;
              try { rules = s.cssRules; } catch (e) { continue; }  // another origin's sheet
              copyFrom(rules, '', '');
            }
          };

          // --- pinning -------------------------------------------------------
          const pin = (el) => {
            const root = el.getRootNode();
            adopt(document);
            copyRules(document);
            if (root !== document) { adopt(root); copyRules(root); }
            el.setAttribute(PINNED, '');
            // The root already is the viewport; filling it is the chrome going.
            if (el === document.documentElement) return;
            popover = false;
            if (typeof el.showPopover === 'function' && !el.hasAttribute('popover')) {
              try {
                el.setAttribute('popover', 'manual');
                el.showPopover();
                popover = true;
              } catch (e) {
                el.removeAttribute('popover');
              }
            }
            if (!popover) el.setAttribute(PINNED, 'fixed');
          };
          const unpin = (el) => {
            if (popover) {
              try { el.hidePopover(); } catch (e) {}
              el.removeAttribute('popover');
              popover = false;
            }
            el.removeAttribute(PINNED);
          };
          const watch = () => {
            if (watcher || typeof MutationObserver !== 'function') return;
            watcher = new MutationObserver(() => { if (current && !current.isConnected) leave('self', true); });
            watcher.observe(document, { childList: true, subtree: true });
          };
          const unwatch = () => { if (watcher) { watcher.disconnect(); watcher = null; } };

          // --- telling ---------------------------------------------------------
          const fire = (el, kind) => {
            const target = el && el.isConnected ? el : document;
            for (const type of ['fullscreen' + kind, 'webkitfullscreen' + kind]) {
              target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
            }
          };
          const tellShell = (active) => {
            try { window.webkit.messageHandlers[CHANNEL].postMessage({ active }); } catch (e) {}
          };
          const tellParent = (what) => {
            try { window.parent.postMessage({ [TAG]: what }, '*'); } catch (e) {}
          };
          const tellChild = (frame, what) => {
            try { if (frame.contentWindow) frame.contentWindow.postMessage({ [TAG]: what }, '*'); } catch (e) {}
          };

          // --- entering and leaving -------------------------------------------
          const enter = (el, child) => {
            if (current === el) return;
            if (current) {
              const old = current;
              if (forChild) tellChild(old, 'exit');
              unpin(old);
              later(() => fire(old, 'change'));
            }
            current = el;
            forChild = child;
            pin(el);
            watch();
            if (isTop) tellShell(true); else tellParent('enter');
            later(() => fire(el, 'change'));
          };
          // `origin` is who ended it: 'self', 'parent' or 'child'.
          const leave = (origin, events) => {
            const el = current;
            if (!el) return;
            const child = forChild;
            unpin(el);
            current = null;
            forChild = false;
            unwatch();
            if (child && origin !== 'child') tellChild(el, 'exit');
            if (isTop) tellShell(false); else if (origin !== 'parent') tellParent('exit');
            if (events) later(() => fire(el, 'change'));
          };

          const request = (el) => new Promise((resolve, reject) => {
            const refuse = (why) => later(() => {
              if (el instanceof Element) fire(el, 'error');
              reject(new TypeError(why));
            });
            if (!(el instanceof Element) || !el.isConnected) return refuse('The element is not in a document');
            if (!allowed()) return refuse('Full screen is not allowed in this frame');
            const activation = navigator.userActivation;
            if (activation && !activation.isActive) return refuse('Full screen needs a click or a key press');
            if (current || nativeElement() || shiftHeld()) {
              // One step further: WebKit's own full screen, across the display.
              try {
                const result = native.request.call(el);
                if (result && typeof result.then === 'function') result.then(resolve, reject); else resolve();
              } catch (e) {
                reject(e);
              }
              return;
            }
            enter(el, false);
            later(resolve);  // after the change event, which `enter` queued first
          });

          const exit = () => new Promise((resolve, reject) => {
            if (nativeElement()) {
              try {
                const result = native.exit.call(document);
                if (result && typeof result.then === 'function') result.then(resolve, reject); else resolve();
              } catch (e) {
                reject(e);
              }
              return;
            }
            if (!current) return reject(new TypeError('Not in full screen'));
            leave('self', true);
            later(resolve);
          });

          // --- frames ----------------------------------------------------------
          const frameFor = (source) => {
            if (!source) return null;
            for (const frame of document.querySelectorAll('iframe, frame')) {
              if (frame.contentWindow === source) return frame;
            }
            return null;
          };
          const frameMayFill = (frame) => {
            if (!allowed()) return false;
            try { if (frame.contentDocument) return true; } catch (e) {}
            return frame.allowFullscreen === true
              || /(^|;)\s*fullscreen(?=[\s;]|$)/i.test(frame.getAttribute('allow') || '');
          };
          window.addEventListener('message', (e) => {
            const what = e.data && typeof e.data === 'object' ? e.data[TAG] : undefined;
            if (typeof what !== 'string') return;
            // Ours, so no page handler has to cope with it.
            e.stopImmediatePropagation();
            if (e.source !== window && e.source === window.parent) {
              if (what === 'exit' && current) leave('parent', true);
              return;
            }
            const frame = frameFor(e.source);
            if (!frame) return;
            if (what === 'enter' && frameMayFill(frame)) enter(frame, true);
            else if (what === 'exit' && current === frame) leave('child', true);
          }, true);

          // --- Esc, and WebKit's own full screen ending -------------------------
          window.addEventListener('keydown', (e) => {
            if (e.key !== 'Escape' || !current || nativeElement()) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            leave('self', true);
          }, true);
          const nativeChanged = (e) => {
            if (!e.isTrusted) return;
            const on = !!nativeElement();
            // WebKit has told the page already; leaving the pane too is quiet.
            if (nativeWasOn && !on && current) leave('self', false);
            nativeWasOn = on;
          };
          window.addEventListener('fullscreenchange', nativeChanged, true);
          window.addEventListener('webkitfullscreenchange', nativeChanged, true);

          // --- the API -----------------------------------------------------------
          const define = (proto, name, descriptor) => {
            if (!proto) return;
            const old = Object.getOwnPropertyDescriptor(proto, name);
            Object.defineProperty(proto, name, Object.assign(
              { configurable: true, enumerable: old ? old.enumerable : true }, descriptor));
          };
          const method = (proto, name, fn) => define(proto, name, { value: fn, writable: true });
          const read = (proto, name, fn) => define(proto, name, { get: fn });
          const quietly = (promise) => { promise.catch(() => {}); };
          const retarget = (el) => {
            let node = el;
            while (node && node.getRootNode() !== document) {
              const root = node.getRootNode();
              if (!(root instanceof ShadowRoot)) return null;
              node = root.host;
            }
            return node;
          };
          const shown = function () {
            if (this !== document) return native.element ? native.element.call(this) : null;
            const el = nativeElement() || current;
            return el ? retarget(el) : null;
          };
          const enabled = function () { return this === document ? allowed() : false; };
          const isShown = function () { return !!shown.call(this); };

          method(E, 'requestFullscreen', function () { return request(this); });
          method(E, 'webkitRequestFullscreen', function () { quietly(request(this)); });
          method(E, 'webkitRequestFullScreen', function () { quietly(request(this)); });
          method(D, 'exitFullscreen', function () {
            return this === document ? exit() : Promise.reject(new TypeError('Not in full screen'));
          });
          method(D, 'webkitExitFullscreen', function () { if (this === document) quietly(exit()); });
          method(D, 'webkitCancelFullScreen', function () { if (this === document) quietly(exit()); });
          read(D, 'fullscreenElement', shown);
          read(D, 'webkitFullscreenElement', shown);
          read(D, 'webkitCurrentFullScreenElement', shown);
          read(D, 'fullscreenEnabled', enabled);
          read(D, 'webkitFullscreenEnabled', enabled);
          read(D, 'fullscreen', isShown);
          read(D, 'webkitIsFullScreen', isShown);
          read(D, 'webkitFullScreenKeyboardInputAllowed', isShown);
          if (V) {
            const showing = function () { return current === this || nativeElement() === this; };
            method(V, 'webkitEnterFullscreen', function () { quietly(request(this)); });
            method(V, 'webkitEnterFullScreen', function () { quietly(request(this)); });
            method(V, 'webkitExitFullscreen', function () { if (showing.call(this)) quietly(exit()); });
            method(V, 'webkitExitFullScreen', function () { if (showing.call(this)) quietly(exit()); });
            read(V, 'webkitDisplayingFullscreen', showing);
            read(V, 'webkitSupportsFullscreen', function () { return allowed(); });
          }
        })();
        """#

    /// Install the script and the handler on a web view.
    ///
    /// Idempotent for the same reason `LinkHoverProbe.install` is: a content
    /// controller that already holds a handler by this name raises an
    /// Objective-C exception on a second `add`, and that is a dead process.
    @MainActor
    static func install(on webView: WKWebView, handler: WKScriptMessageHandler) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: channel)
        content.add(handler, name: channel)
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        // Every frame: an embedded player is the common case, not the edge.
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    @MainActor
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
    }
}

/// `ScriptMessageRelay`, but handing over the whole message: the full screen
/// handler has to know which web view and which frame spoke, because a popup's
/// page shares its opener's content controller and only a top frame may hide a
/// chrome bar.
final class FullScreenMessageRelay: NSObject, WKScriptMessageHandler {
    private let body: @MainActor (WKScriptMessage) -> Void

    init(_ body: @escaping @MainActor (WKScriptMessage) -> Void) {
        self.body = body
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { body(message) }
    }
}
