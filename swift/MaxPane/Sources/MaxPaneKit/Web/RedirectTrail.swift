import Foundation
import WebKit

/// Every address a pane passed through on the way to the one it is showing.
///
/// # What was wrong with asking the web view
///
/// `didFinish` used to read the redirect source out of
/// `backForwardList.currentItem?.initialURL`. That is right for a server
/// redirect and wrong for everything else, because a client-side redirect or a
/// `replaceState` has already overwritten it by the time the load finishes.
/// Measured against the owner's corpus:
///
/// | typed | kind | recorded |
/// |---|---|---|
/// | `…/js` | `location.replace` | its own row titled "bouncing", no alias |
/// | `…/meta` | `<meta refresh>` | its own row, no title at all, no alias |
/// | `youtu.be/dQw4w9WgXcQ` | 303 + `replaceState` | three rows, none of them `youtu.be` |
///
/// A two-hop server chain lost its middle URL the same way: one `initialURL` is
/// one address, and a chain is a list.
///
/// So the trail is kept here instead, from the events that actually describe a
/// navigation — where it was asked to go, every server hop it was told about,
/// and whether the load that just started was one the user asked for.
///
/// # Telling a bounce from a page
///
/// A client-side redirect has no event of its own: the interstitial finishes
/// loading like any other document and *then* navigates. The only signal is
/// that the next navigation begins moments later and nobody asked for it. So:
/// a main-frame navigation of type `.other`, starting within
/// ``clientRedirectWindow`` of the last load finishing, that this pane did not
/// start itself, is the page redirecting.
///
/// `.other` is doing real work there — a link, a form, a back-forward move and
/// a reload all carry their own navigation type — and "this pane did not start
/// it" is tracked rather than guessed, because an address typed into the chrome
/// bar is also `.other` and is the opposite of a redirect. WebKit has no public
/// "was there a user gesture" on `WKNavigationAction`; the private
/// `_isUserInitiated` would answer directly and is not worth an app being
/// rejected over.
///
/// The window is two seconds, the same number as `VISIT_COALESCE_MS` in
/// `history.rs`. Both are answering "did these two events come from one thing
/// the user did", and two answers to that question would drift apart.
struct RedirectTrail {
    /// How soon after a page loads a navigation nobody asked for reads as that
    /// page redirecting.
    static let clientRedirectWindow: TimeInterval = 2.0

    /// The addresses passed through on the way to where this navigation is
    /// heading, oldest first. Never includes the destination.
    private(set) var chain: [String] = []

    /// Where the navigation in flight is currently pointed. A server redirect
    /// moves it on and pushes what it left behind onto ``chain``.
    private var heading: String?

    /// What the pane last settled on, when, and what led to it — the candidate
    /// interstitial if the next navigation turns out to be a redirect.
    ///
    /// `led` rides along because a bounce can be bounced to: land on a
    /// shortener, follow its 303 to a consent page, and have *that* redirect
    /// itself. The consent page's own hops belong to the article in the end,
    /// and dropping them at each settle lost the address the user actually
    /// typed — which is the one hop of a chain anyone ever searches for.
    private var settled: (url: String, at: TimeInterval, led: [String])?

    /// Set when this pane starts a load itself. Consumed by the next
    /// navigation, because a load the pane asked for is never a redirect — and
    /// exactly one navigation follows one `load`.
    private var paneAsked = false

    /// The pane is about to call `load`. Not a redirect, whatever the timing.
    mutating func paneWillLoad() {
        paneAsked = true
    }

    /// A main-frame navigation is being decided.
    ///
    /// `now` is passed in rather than read, so the tests can put two events two
    /// seconds apart without waiting two seconds.
    mutating func willNavigate(to url: String?, type: WKNavigationType, now: TimeInterval) {
        let deliberate = paneAsked || type != .other
        paneAsked = false
        let bounced = !deliberate
            && settled.map { now - $0.at < Self.clientRedirectWindow } == true
        // A client redirect continues the chain it interrupted: land on a
        // shortener, which bounces to a consent page, which bounces to the
        // article, and all three addresses belong to the one entry.
        chain = bounced ? settled!.led + [settled!.url] : []
        heading = url
        settled = nil
    }

    /// The server answered a 3xx and WebKit is following it.
    mutating func serverRedirect(to url: String?) {
        if let heading, heading != url {
            chain.append(heading)
        }
        heading = url
    }

    /// The document finished. Gives back the addresses that led here, which is
    /// what `Core.recordVisit` demotes to aliases of this one.
    mutating func didFinish(at url: String?, now: TimeInterval) -> [String] {
        // `heading` is only *not* the destination when the page moved without a
        // navigation — a `replaceState` during load. That address was asked for
        // and is worth keeping findable, so it joins the chain rather than
        // being dropped.
        if let heading, heading != url {
            chain.append(heading)
        }
        heading = nil
        let led = chain.filter { $0 != url }
        chain = []
        if let url {
            settled = (url, now, led)
        }
        return led
    }

    /// The load came apart. Nothing settled, so nothing that starts next can be
    /// a redirect from it — a failed page never redirected anywhere.
    mutating func didFail() {
        heading = nil
        chain = []
        settled = nil
    }
}
