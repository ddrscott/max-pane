import Foundation

/// Everything a page can stop and ask a person for, and the machinery that
/// guarantees the page gets exactly one answer.
///
/// ## Why these live in a lane and not on the window
///
/// The strip is **one window holding many lanes**. Every obvious implementation
/// of `alert()` is `NSAlert.beginSheetModal(for: window)`, and a sheet on this
/// window is modal to the *whole strip*: a background lane running a
/// `setTimeout` that fires an `alert()` would freeze the terminal you are
/// working in, three lanes away, for a question you never asked. That is
/// strictly worse than the silent `false` this piece replaces — a silent wrong
/// answer costs one page, a frozen window costs the session.
///
/// So an ask is drawn **inside the pane that raised it**, over the page and
/// under the address bar, and it is modal to nothing. The consequences are the
/// design, not side effects of it:
///
/// - **Two lanes at once**: two sheets, neither waiting on the other, and the
///   terminals keep typing. There is no app-wide queue because there is no
///   app-wide resource being contended.
/// - **The same lane twice**: a real queue, `AskQueue` — an iframe and its
///   parent can both be mid-`confirm()`, and WebKit will call the delegate
///   again before the first handler has run. The second question waits its turn
///   in the pane rather than replacing the first on screen.
/// - **The lane is off screen**: nothing scrolls. A page you cannot see does
///   not get to move the viewport — that is the freeze bug wearing a different
///   hat. It raises the signal this app already has for *this one needs you*:
///   the status bar's Signal Orange count, which is clickable and scrolls to
///   the first lane that is asking (`WebAskCenter`).
/// - **Dismissing something you did not ask for**: Esc, or the sheet's ✕, and
///   both mean exactly what Cancel means. Nothing is remembered from a dismissal
///   — an Esc is "not now", never "never".
///
/// It also solves the recycling hazard for free. The sheet is a subview of the
/// pane's own container, and the strip recycles *lane views* while pane
/// controllers outlive them (ADR-0004). A sheet in the pane therefore survives
/// its lane scrolling out of the materialisation window and comes back with it,
/// with the completion handler untouched.
enum WebAsk {}

// MARK: - exactly once

/// A completion handler that can be called exactly once, from anywhere.
///
/// **The trap this exists for.** Every `WKUIDelegate` and `WKNavigationDelegate`
/// callback in this piece hands over a completion handler with two rules and no
/// enforcement: call it twice and WebKit traps in
/// `-[WKWebView _didExitFullscreen]`-style internal state with a message about
/// a completion handler being called more than once; never call it and that web
/// view hangs — no error, no timeout, the page simply never runs another line
/// of JavaScript.
///
/// Both are live risks here rather than theoretical ones, because an ask can
/// outlive the thing that raised it: the pane is closed (⌘W, or the ledger
/// dropping the lane), the page is evicted under memory pressure, or the user
/// dismisses the sheet at the same moment the page navigates away. Each of
/// those wants to answer, and more than one can happen in the same run loop
/// turn.
///
/// So the invariant is held in one place. `fire` is idempotent, `fallback` is
/// the answer an abandoned ask gets, and the pane drains every outstanding one
/// in `tearDown` and on eviction.
///
/// Deliberately **not** relying on `deinit` as the last resort. A `@MainActor`
/// class's deinit is non-isolated under Swift 6 strict concurrency and cannot
/// touch main-actor state, so an answer from there is unimplementable — which
/// makes draining explicitly the only honest design rather than the belt to a
/// missing brace. Every path that can drop an ask is therefore enumerated at
/// the call sites rather than trusted to ARC.
///
/// Main-actor isolated rather than lock-guarded: every producer of these is a
/// WebKit delegate callback and every consumer is a button, both already on the
/// main actor, so a lock would be a second mechanism guaranteeing something the
/// actor already guarantees — and would let the class be *called* off the main
/// actor, which the completion handlers it wraps do not allow.
@MainActor
final class OneShotReply<Value> {
    private var reply: ((Value) -> Void)?
    private let fallback: Value

    init(fallback: Value, reply: @escaping (Value) -> Void) {
        self.fallback = fallback
        self.reply = reply
    }

    var isPending: Bool { reply != nil }

    /// Answer the page. The second and every later call does nothing.
    @discardableResult
    func fire(_ value: Value) -> Bool {
        guard let handler = reply else { return false }
        reply = nil
        handler(value)
        return true
    }

    /// The answer for an ask nobody is left to answer: the page is told the
    /// user cancelled, which is the one reply that is never a lie.
    @discardableResult
    func abandon() -> Bool { fire(fallback) }
}

// MARK: - the queue

/// The asks outstanding in one pane, oldest first.
///
/// Pure and generic so the ordering is testable without WebKit. The rule it
/// encodes: the first ask is the one on screen, and a later ask never replaces
/// it. A page that calls `alert()` in a loop would otherwise repaint the sheet
/// under the pointer between the press and the release.
struct AskQueue<Item> {
    private(set) var items: [Item] = []

    var current: Item? { items.first }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// Adds `item` and reports whether it is now the one to draw.
    mutating func enqueue(_ item: Item) -> Bool {
        items.append(item)
        return items.count == 1
    }

    /// Drop the answered ask and hand back the one that takes its place.
    mutating func finish() -> Item? {
        guard !items.isEmpty else { return nil }
        items.removeFirst()
        return items.first
    }

    /// Everything, in order, leaving the queue empty. For a pane going away:
    /// each one still has a page waiting on it.
    mutating func drain() -> [Item] {
        defer { items = [] }
        return items
    }
}

// MARK: - who is asking

/// Who the sheet says is asking.
///
/// **A dialog that does not name its origin is a phishing surface**: a page can
/// put any text it likes in `alert()`, including "Max Pane — enter your
/// password". The only thing the page cannot choose is the origin WebKit
/// attributes the call to, so that is the line the sheet leads with and it is
/// drawn in chrome type, outside the message.
///
/// The conventions match `BrowserAddress` exactly, because the address bar is
/// 26 pt below the sheet and the two disagreeing about what site this is would
/// be worse than either being wrong alone: `https://` is dropped because it is
/// the state of every page, `http://` is kept because it is the one scheme
/// worth noticing, and a non-default port is part of the identity.
enum AskOrigin {
    /// `example.com`, `http://localhost:8071`, `a local file`.
    static func label(scheme: String?, host: String?, port: Int?) -> String {
        let scheme = (scheme ?? "").lowercased()
        guard let host, !host.isEmpty else {
            // `file://` and `about:blank` have no host to name. Saying "this
            // page" is honest; inventing one would not be.
            return scheme == "file" ? "a local file" : "this page"
        }
        var text = scheme == "https" || scheme.isEmpty ? "" : "\(scheme)://"
        text += host
        if let port, !isDefaultPort(port, for: scheme) { text += ":\(port)" }
        return text
    }

    static func label(for url: URL?) -> String {
        guard let url else { return "this page" }
        return label(scheme: url.scheme, host: url.host, port: url.port)
    }

    /// The key a remembered permission is stored under: a full origin, with the
    /// scheme kept and the default port dropped, so `http://example.com` and
    /// `https://example.com` are two different grants. They are two different
    /// origins to the web platform and treating them as one would let a plain
    /// http page inherit a grant made to the secure one.
    static func key(scheme: String?, host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty, let scheme = scheme?.lowercased(), !scheme.isEmpty
        else { return nil }
        var text = "\(scheme)://\(host)"
        if let port, !isDefaultPort(port, for: scheme) { text += ":\(port)" }
        return text
    }

    private static func isDefaultPort(_ port: Int, for scheme: String) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port <= 0
    }
}

// MARK: - bytes

/// Sizes, for the download bar.
///
/// Not `ByteCountFormatter`: it localises the separator and pads to a fixed
/// width, and in a 26 pt mono row whose whole point is that the number moves
/// smoothly, a string that changes width between frames reads as flicker.
enum ByteSize {
    static func short(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value < 1024 { return "\(Int(value)) B" }
        if value < 1024 * 1024 { return String(format: "%.0f KB", value / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / (1024 * 1024)) }
        return String(format: "%.2f GB", value / (1024 * 1024 * 1024))
    }
}
