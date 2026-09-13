import AppKit
import WebKit

/// The right-click menu's nouns, corrected to name what this app actually does.
///
/// ## Why this was reported as blocked, and why it is not
///
/// Round 2 left this open on the grounds that *"the one web view this app does
/// not construct is the adopted popup, which WebKit instantiates as a plain
/// `WKWebView` from its own configuration"* — so a subclass would fix the menu
/// on ordinary panes and leave it stock on OAuth popups, and a menu that is
/// right in most panes and wrong in some is worse than one that is stock
/// everywhere.
///
/// That premise is wrong. There are exactly two `WKWebView(frame:configuration:)`
/// calls in this target and **both are ours**: the pane's own view, and the
/// popup in `openPopup(with:url:near:)`. `WKUIDelegate` does not hand over a
/// finished view — it hands over a *configuration* and demands a view built from
/// it, which is the whole reason `PopupHandoff` exists. Building that view as a
/// subclass keeps `window.opener` intact exactly as before, because the opener
/// relationship lives in the configuration and not in the class. So the menu can
/// be right everywhere, and the objection that blocked this dissolves.
///
/// ## Why titles are rewritten rather than items replaced
///
/// The gesture this menu item existed to reach — "keep my place, open a sibling"
/// — is now ⌘-click (`LinkClick`), which took the pressure off building a menu
/// of our own. What is left is a lie in a word: the item says **window** and the
/// thing it produces is a **lane**, and this app has no windows to open a link
/// in. WebKit's item already does the right thing; it is named after a UI model
/// this app does not have.
///
/// Renaming is also the only change here that cannot regress anything. The
/// actions, the order, the separators and the keyboard loop stay WebKit's, so
/// "Download Linked File" still runs the download path `WebDownloads` handles
/// and an item we have never seen keeps whatever WebKit called it.
enum WebContextMenu {
    /// WebKit's own name for a menu item, as it appears in
    /// `NSMenuItem.identifier` on macOS.
    ///
    /// These are not in the macOS SDK. `WKMenuItemIdentifier` exists as a Swift
    /// type on iOS 16+ only — `swiftc -typecheck` against the macOS SDK reports
    /// *"cannot find 'WKMenuItemIdentifier' in scope"* — while the macOS
    /// implementation sets the same strings on the items it builds and exposes
    /// no constant for them. Verified rather than assumed: the strings below
    /// were read out of this machine's WebKit with
    /// `strings dyld_shared_cache_arm64e | grep WKMenuItemIdentifier`, which
    /// lists `OpenLinkInNewWindow`, `OpenImageInNewWindow`,
    /// `OpenMediaInNewWindow` and `OpenFrameInNewWindow` among thirty-odd
    /// others.
    ///
    /// Matching an undocumented string is the reason `rename` is written to do
    /// nothing when it recognises nothing: see there.
    enum Identifier {
        static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
        static let openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
        static let openMediaInNewWindow = "WKMenuItemIdentifierOpenMediaInNewWindow"
        static let openFrameInNewWindow = "WKMenuItemIdentifierOpenFrameInNewWindow"
    }

    /// What each of those should be called here.
    ///
    /// "to the Right" is in the title because it is the part the reader cannot
    /// otherwise find out. A lane is created by `newWebLane(near:)`, which
    /// places it by ordinal immediately after the opener — the same placement
    /// ⌘-click produces — and on a fifteen-lane strip "a new lane" without a
    /// direction is a thing you then have to go looking for.
    static let titles: [String: String] = [
        Identifier.openLinkInNewWindow: "Open Link in a Lane to the Right",
        Identifier.openImageInNewWindow: "Open Image in a Lane to the Right",
        Identifier.openMediaInNewWindow: "Open Video in a Lane to the Right",
        Identifier.openFrameInNewWindow: "Open Frame in a Lane to the Right",
    ]

    /// Rewrite the titles we have a better name for, and leave everything else
    /// exactly as WebKit built it.
    ///
    /// **Silence is the designed behaviour when nothing matches.** The match is
    /// on an identifier WebKit does not promise, so the failure this has to
    /// survive is a future WebKit that stops setting it — and the result of that
    /// failure is the stock menu, which is what every build before this one
    /// shipped. The alternative, matching on the visible title, would break on
    /// the first non-English system instead of degrading on some future one, and
    /// would rename by coincidence rather than by identity.
    ///
    /// Returns how many items it renamed, which is what a test can assert on
    /// without a live right-click.
    @discardableResult
    static func rename(in menu: NSMenu) -> Int {
        var renamed = 0
        for item in menu.items {
            // Submenus too: WebKit nests the spelling and substitution items,
            // and while none of those are ours today, a menu walked one level
            // deep is a rule that stays true when WebKit moves something.
            if let submenu = item.submenu { renamed += rename(in: submenu) }
            guard let identifier = item.identifier?.rawValue,
                  let title = titles[identifier],
                  item.title != title
            else { continue }
            item.title = title
            renamed += 1
        }
        return renamed
    }
}

/// A `WKWebView` whose context menu says "lane" where WebKit says "window".
///
/// `willOpenMenu(_:with:)` is `NSView`'s, not WebKit's, and that is the point:
/// macOS `WKWebView` has no context-menu delegate at all —
/// `contextMenuConfigurationForElement` is the iOS API — so the menu is only
/// reachable in the window between WebKit finishing it and AppKit showing it.
/// Anything done here must therefore be cheap and must not fail, because there
/// is no way to answer "later" from inside it.
///
/// Used for **both** web views this app builds, the adopted popup included. A
/// popup built from WebKit's configuration keeps `window.opener` whatever class
/// it is; see `WebContextMenu`.
final class ChromeWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        WebContextMenu.rename(in: menu)
    }
}
