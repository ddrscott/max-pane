import Foundation

/// Putting a saved password into the form the user is looking at — the half of
/// this feature that can actually hurt someone, and the rules that keep it from
/// doing so.
///
/// ## The danger, stated plainly
///
/// A credential put into a page's DOM is a credential given to whatever is
/// running on that page. Every script on it can read the field, and the page
/// chose those scripts. There is no way to fill a web form that does not end
/// this way — Safari's autofill ends this way too — so the safety is not in
/// the injection, which cannot be made safe, but in **when it is allowed to
/// happen**. Five rules, and each one is a thing that has gone wrong in a real
/// password manager:
///
/// 1. **Never automatically.** Nothing is injected on load, on navigation, on
///    a page's request, or on a timer. There is no script injected at document
///    start and no `WKScriptMessageHandler` a page can call. The only thing
///    that starts a fill is ⌥⌘L or a click on the chrome bar's key, both of
///    which mean a person is looking at the form. A manager that fills
///    invisible forms on load is a manager that donates credentials to any
///    page that puts a hidden login form on it.
///
/// 2. **The origin comes from WebKit, never from the page.** The match is
///    against `WKWebView.url` — the URL of the load WebKit actually committed —
///    and it is exact in scheme, host and port (`PasswordOrigin`). The page is
///    never asked who it is.
///
/// 3. **A cross-origin frame cannot be reached, by construction.** This script
///    walks into a subframe only through `frame.contentDocument`, which the
///    same-origin policy makes `null` for a frame from another site. That is
///    WebKit's check, running inside WebKit, and it is not a condition this
///    code can get wrong — the refusal happens before any of our logic does.
///    The origin is then checked *again* against `document.location.origin`
///    for every document reached, so a frame that somehow got here without
///    being same-origin still gets nothing.
///
/// 4. **The password is an argument, never source.** `callAsyncJavaScript`
///    takes an arguments dictionary, so the secret is bound as a JavaScript
///    value and never concatenated into a program. String-building the script
///    would put a quote-escaping bug between a password and arbitrary code
///    execution in the page, and would put the password itself in any string
///    that ever got logged.
///
/// 5. **An ambiguous form is refused, not guessed.** Exactly one visible
///    password field, or nothing happens. Two is a change-password or a
///    sign-up form, and a manager that guesses which box the old password goes
///    in is one that types a password into a field the site is about to
///    display.
///
/// ## The isolated world, and what it is worth
///
/// The script runs in `WKContentWorld.defaultClient`, not in the page's world.
/// The DOM is shared — that is what makes filling work at all — but the
/// JavaScript globals are not, so a page that has replaced
/// `HTMLInputElement.prototype`'s `value` setter, or `Event`, or
/// `Object.getOwnPropertyDescriptor`, has replaced its own copies and not
/// ours. A plain `el.value = v` from here *is* the native setter, and the page
/// cannot see the assignment happen — only its result, which it was always
/// going to see.
enum PasswordFill {
    /// What happened, in the shape the chrome bar reports.
    enum Outcome: Equatable {
        /// The password went in. `user` says whether a user-name field was
        /// found and filled alongside it.
        case filled(user: Bool)
        /// Nothing on this page takes a password.
        case noPasswordField
        /// More than one visible password field: a sign-up or a change-password
        /// form. Refused on purpose — see rule 5.
        case severalPasswordFields
        /// No password field we can see, and there is at least one frame from
        /// another site that we cannot look inside. Worth its own sentence
        /// because the user can see a login box and we cannot.
        case hiddenInAnotherSitesFrame
        case failed(String)

        /// One line for the chrome bar. Never names the account or the site's
        /// field names — it is a status, not a report about a credential.
        var message: String {
            switch self {
            case .filled(let user):
                return user ? "Signed in — user and password filled" : "Password filled"
            case .noPasswordField:
                return "No password field on this page"
            case .severalPasswordFields:
                return "Several password fields here — fill it by hand"
            case .hiddenInAnotherSitesFrame:
                return "The sign-in form belongs to another site — fill it there"
            case .failed(let why):
                return why
            }
        }

        var didFill: Bool { if case .filled = self { return true }; return false }

        /// What `MAXPANE_DEBUG` is allowed to see: the case, and nothing
        /// carried inside it. `message` is for the person at the keyboard and
        /// `failed`'s string is the only field in this enum that did not
        /// originate here — so the log gets this instead, the way `WebAuth`
        /// logs the kind of challenge and never its words.
        var tag: String {
            switch self {
            case .filled(let user): return user ? "filled+user" : "filled"
            case .noPasswordField: return "no-field"
            case .severalPasswordFields: return "ambiguous"
            case .hiddenInAnotherSitesFrame: return "foreign-frame"
            case .failed: return "refused"
            }
        }
    }

    /// The token the script returns, turned into an outcome.
    ///
    /// Separate from the script so the mapping is testable: the script itself
    /// needs a live page and a WebKit content world, and the thing most likely
    /// to rot is the agreement about these five strings.
    static func outcome(from value: Any?) -> Outcome {
        switch value as? String {
        case "filled-with-user": return .filled(user: true)
        case "filled": return .filled(user: false)
        case "none": return .noPasswordField
        case "several": return .severalPasswordFields
        case "opaque-frame": return .hiddenInAnotherSitesFrame
        // A token this build does not know. The string is not echoed: it is
        // the one value in this file that did not come from `javaScript`
        // above, and a status line is not a place to print something a page
        // might one day have had a hand in.
        case .some: return .failed("The page refused the fill")
        case nil: return .failed("The page did not answer")
        }
    }

    /// The script. Three arguments — `user`, `secret`, `expect` — bound by
    /// `callAsyncJavaScript` and never interpolated into this string.
    ///
    /// `expect` is the origin WebKit committed, in `location.origin` spelling.
    /// Every document this walks into is checked against it, which is rule 3's
    /// second half.
    static let javaScript = """
    const forms = [];
    let opaque = false;

    const reachable = () => {
        const docs = [];
        // The top document is the load WebKit committed, and it must *be* the
        // origin we were asked for — no exception and no inheritance. A
        // `data:` or `about:blank` page has no origin to have saved a password
        // under and never gets this far anyway, because `PasswordOrigin`
        // refuses to build one for it.
        let top = null;
        try { top = document.location.origin; } catch (e) { top = null; }
        if (top !== expect) { opaque = true; return docs; }
        docs.push(document);

        const queue = [document];
        while (queue.length && docs.length < 32) {
            for (const frame of queue.shift().querySelectorAll('iframe, frame')) {
                let inner = null;
                try { inner = frame.contentDocument; } catch (e) { inner = null; }
                // Cross-origin: WebKit returns null and there is no way past it
                // from here. That is the refusal, and it is not ours — it is the
                // same-origin policy, enforced inside WebKit, before any line of
                // this script runs. A `sandbox` without `allow-same-origin`
                // lands here too; measured.
                if (!inner) { opaque = true; continue; }
                let here = null;
                try { here = inner.location.origin; } catch (e) { here = null; }
                // Measured in WebKit, because guessing here would have been
                // wrong: a `srcdoc` or `about:blank` frame inherits its
                // parent's origin and is fully scriptable, and still reports
                // `location.origin === "null"`. It is accepted, because
                // reachability through `contentDocument` is already the proof
                // that it is us — a frame that were not us would not be
                // reachable at all. Without this the *only* password field on
                // such a page is unfillable and reported as belonging to
                // another site, which is not true.
                const inherited = here === 'null'
                    && String(inner.location.href).indexOf('about:') === 0;
                if (here !== expect && !inherited) { opaque = true; continue; }
                docs.push(inner);
                queue.push(inner);
            }
        }
        return docs;
    };

    const visible = (el) => {
        if (el.disabled || el.readOnly) return false;
        const box = el.getBoundingClientRect();
        if (box.width < 2 || box.height < 2) return false;
        const style = el.ownerDocument.defaultView.getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') return false;
        return parseFloat(style.opacity || '1') > 0.05;
    };

    for (const doc of reachable()) {
        for (const field of doc.querySelectorAll('input[type=password]')) {
            if (visible(field)) forms.push(field);
        }
    }

    if (forms.length === 0) return opaque ? 'opaque-frame' : 'none';
    if (forms.length > 1) return 'several';

    const field = forms[0];
    const doc = field.ownerDocument;

    // The user name: the nearest visible text-ish input *before* the password
    // box, inside the same form when there is one. Before, because that is the
    // order every sign-in form on the web is laid out in; a box after the
    // password is a search field or a second factor, and typing a user name
    // into a second-factor box is worse than leaving it empty.
    const scope = field.form || doc;
    const candidates = Array.prototype.slice.call(
        scope.querySelectorAll('input:not([type=password]):not([type=hidden])'));
    const kinds = ['text', 'email', 'tel', 'url', ''];
    const usable = candidates.filter((el) =>
        kinds.indexOf((el.getAttribute('type') || '').toLowerCase()) >= 0 && visible(el));
    const before = usable.filter((el) =>
        field.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_PRECEDING);
    const target = before.length ? before[before.length - 1] : null;

    // A plain assignment, from a world whose prototypes the page has not
    // touched. Then the two events a framework listens for, bubbling, so a
    // controlled input updates its own state rather than snapping back on the
    // next render.
    const put = (el, value) => {
        el.focus();
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
    };

    if (target && user) put(target, user);
    put(field, secret);
    // Focus is left in the password box, where ↩ submits. The fill is the
    // assistance; pressing the button stays the person's job.
    field.focus();
    return target && user ? 'filled-with-user' : 'filled';
    """
}
