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
    /// `window.opener` intact.
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
    /// launch, where a popup pane is transient by nature and closes itself.
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
        // the cost of guessing "popup" is a pane that closes itself, and the
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

/// A popup web view between the moment WebKit hands it over and the moment its
/// pane exists to hold it.
///
/// The handoff has to exist because the two halves run in the wrong order.
/// `WKUIDelegate` demands the finished web view back **synchronously** — it must
/// be built from the configuration it passed, and returning `nil` (or a view
/// built from a fresh configuration) is what severs `window.opener` — but a pane
/// in this app is created by writing to the ledger and letting the strip
/// reconcile, which is what decides the pane's id and builds its controller.
///
/// So the view is staged first and claimed by whichever `WebPaneController` the
/// reconcile builds for it. That usually happens inside the ledger write itself,
/// before it returns, which is why the pending slot matches on URL: at that
/// point the new pane's id does not exist anywhere yet. Once the write returns,
/// the id is known and anything still pending is filed under it, for the case
/// where the new lane was outside the materialisation window and its controller
/// comes along later.
@MainActor
final class PopupHandoff {
    static let shared = PopupHandoff()

    struct Staged {
        let webView: WKWebView
        /// What the lane was created with, and so what the pane's URL will be.
        let url: String
        let openerPaneId: String
        /// The opener's cookie jar, carried across explicitly rather than
        /// re-derived, so the pane records the jar its page is actually in.
        let dataStoreId: String
    }

    /// At most one: staging and resolving happen in one main-actor run loop
    /// turn, with only the reconcile in between.
    private var pending: Staged?
    private var byPane: [String: Staged] = [:]

    func stage(_ staged: Staged) {
        if let orphan = pending {
            // Cannot happen while both halves stay synchronous; if it ever does,
            // the previous popup would be a web view nothing will ever show.
            Log.warn("popup handoff: \(orphan.url) was never claimed")
        }
        pending = staged
    }

    /// The staged view for a pane being built, if it is the popup's pane.
    func claim(paneId: String, url: String?) -> Staged? {
        if let staged = byPane.removeValue(forKey: paneId) { return staged }
        guard let staged = pending, staged.url == url else { return nil }
        pending = nil
        return staged
    }

    /// File anything still unclaimed under the pane the ledger just created.
    func resolvePending(to paneId: String?) {
        guard let staged = pending else { return }
        pending = nil
        guard let paneId else {
            Log.warn("popup handoff: no pane was created for \(staged.url)")
            return
        }
        byPane[paneId] = staged
    }

    /// Which pane a staged view belongs to — for a popup that closes itself
    /// before anything has shown it.
    func paneId(holding webView: WKWebView) -> String? {
        byPane.first { $0.value.webView === webView }?.key
    }

    func discard(paneId: String) { byPane.removeValue(forKey: paneId) }
}
