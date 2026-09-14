import WebKit

/// Why a page asked for a second web view, reduced to the four facts that
/// decide what it becomes here.
///
/// `WKUIDelegate` gets one callback for two unrelated things — a `target=_blank`
/// link and an OAuth popup — and they want opposite treatment. A link is a
/// destination: it belongs in a lane of its own, with no memory of where it came
/// from. A popup is a conversation: the page that opened it holds the handle,
/// talks to it through `window.opener`, and is waiting for a `postMessage` that
/// only ever arrives if WebKit built the two views as a pair.
struct PopupIntent: Equatable {
    /// `navigationAction.targetFrame == nil` — nothing in this web view is
    /// going to handle the navigation, so something has to be created.
    var opensNewView: Bool
    /// Script called `window.open`, rather than the user clicking a link or
    /// submitting a form.
    var isScripted: Bool
    /// The call passed a size or a position, which only `window.open`'s third
    /// argument can do.
    var specifiesGeometry: Bool
    /// The call asked for a window without browser chrome — `popup=yes`, or any
    /// of the toolbar flags turned off.
    var suppressesChrome: Bool
}

/// What to build for it.
enum NewViewDisposition: Equatable {
    /// A real `WKWebView` from the configuration WebKit passed, keeping
    /// `window.opener` intact, shown in a `WebPopupDialog` over the window.
    case popup
    /// A new web lane loading the URL, with no relationship to the opener —
    /// what every new page in this app did before popups were distinguished.
    case lane
}

enum PopupPolicy {
    /// The honest reading of one `createWebViewWith` callback.
    ///
    /// Geometry or missing chrome is proof: only `window.open`'s features string
    /// produces either, and that is how OAuth providers open their sign-in
    /// window. A bare `window.open(url)` passes neither, so scripted-ness has to
    /// carry it — the page still holds the returned handle and still expects
    /// `window.opener` at the far end, and there is nothing else in the callback
    /// to tell it apart from a link.
    ///
    /// A link or a form keeps the old behaviour on purpose. `target=_blank` is
    /// how half the web opens a second page for reading, and those should be
    /// lanes: a lane is durable, ordinal-ordered and restored on the next
    /// launch, where a popup is transient by nature and closes itself.
    static func disposition(for intent: PopupIntent) -> NewViewDisposition {
        guard intent.opensNewView else { return .lane }
        if intent.specifiesGeometry || intent.suppressesChrome { return .popup }
        return intent.isScripted ? .popup : .lane
    }
}

extension PopupIntent {
    init(_ action: WKNavigationAction, _ features: WKWindowFeatures) {
        opensNewView = action.targetFrame == nil
        // WebKit reports `.other` for `window.open`; a click on a link is
        // `.linkActivated` and a form target is `.formSubmitted`. Anything it
        // cannot attribute to the user is scripted, which is the safe direction:
        // the cost of guessing "popup" is a dialog that closes itself, and the
        // cost of guessing "lane" is a sign-in that can never report back.
        isScripted = action.navigationType == .other
        specifiesGeometry =
            features.width != nil || features.height != nil
            || features.x != nil || features.y != nil
        suppressesChrome = [
            features.menuBarVisibility, features.statusBarVisibility, features.toolbarsVisibility,
        ].contains { $0?.boolValue == false }
    }
}

/// What a click on a link means, once the modifiers are read.
///
/// The gesture this exists for is "keep my place, open a sibling". Before it,
/// ⌘-click and middle-click both navigated the lane you were reading — the
/// expensive failure, because you reach for it precisely when you do not want
/// to lose the page. The destination it produces is the one
/// `createWebViewWith` already produces for `target=_blank`: a lane of its own,
/// right of this one.
enum LinkClick {
    enum Outcome: Equatable {
        /// The lane navigates, which is what a plain click has always meant.
        case inPlace
        /// A new web lane right of this one, revealed.
        case siblingLane
    }

    static func outcome(
        navigationType: WKNavigationType,
        modifiers: NSEvent.ModifierFlags,
        buttonNumber: Int
    ) -> Outcome {
        // A link, and only a link. A form submission carries state the server
        // is waiting for and a redirect is not a gesture at all; opening either
        // somewhere else would post the form twice or strand the redirect.
        guard navigationType == .linkActivated else { return .inPlace }
        // Middle-click, with no modifier required — the twenty-year-old gesture,
        // and the one a three-button mouse has instead of a chord.
        if buttonNumber == 2 { return .siblingLane }
        let held = modifiers.intersection(.deviceIndependentFlagsMask)
        guard held.contains(.command) else { return .inPlace }
        // ⌃⌘ and ⌥⌘ are left alone on purpose: ⌃-click is macOS's right-click
        // and ⌥-click is "download the linked file" everywhere on this system.
        // Claiming either would take a gesture away to add one.
        return held.isDisjoint(with: [.control, .option]) ? .siblingLane : .inPlace
    }
}

/// How big a popup's dialog is.
///
/// The page says, when it opens one: `window.open(url, name,
/// "width=500,height=600")` is how every OAuth provider sizes its sign-in form,
/// and that size is the size of the *page*. The dialog adds its origin bar on
/// top, so the form gets the room it asked for rather than 28 pt less.
/// `Popup.frame` then keeps the whole thing inside the window's margins.
enum PopupGeometry {
    /// For a page that gave no size — a bare `window.open(url)`, or
    /// `popup=yes`. Portrait, because a sign-in form is, and about what Google
    /// and GitHub ask for when they do say.
    static let defaultPage = NSSize(width: 520, height: 680)
    /// Below this a page is a slit, not a form. A features string can say
    /// `width=1`, and a tracker's pop-under does.
    static let minimumPage = NSSize(width: 320, height: 240)

    static func pageSize(width: Double?, height: Double?) -> NSSize {
        func side(_ asked: Double?, _ fallback: CGFloat, _ floor: CGFloat) -> CGFloat {
            guard let asked, asked.isFinite else { return fallback }
            return max(floor, CGFloat(asked).rounded())
        }
        return NSSize(
            width: side(width, defaultPage.width, minimumPage.width),
            height: side(height, defaultPage.height, minimumPage.height))
    }

    static func dialogSize(page: NSSize, bar: CGFloat) -> NSSize {
        NSSize(width: page.width, height: page.height + bar)
    }
}

/// When a popup has outlived the page that opened it.
///
/// A sign-in dialog is a conversation with one document. When the opener
/// commits a navigation to a *different origin*, `window.opener` at the far end
/// is now a stranger — the `postMessage` it is waiting to send goes to a page
/// that never asked — so the dialog closes. Same-origin moves keep it: a
/// single-page app's `pushState`, a route change, a redirect within the site
/// are all still the page that is waiting.
enum PopupOpener {
    static func hasLeft(openedFrom before: String?, now after: String?) -> Bool {
        guard let before = origin(before), let after = origin(after) else { return false }
        return before != after
    }

    /// Scheme, host and non-default port — the web's own idea of an origin, and
    /// the same key a remembered site permission is filed under.
    static func origin(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw) else { return nil }
        return AskOrigin.key(scheme: url.scheme, host: url.host, port: url.port)
    }
}
