import Testing
import WebKit
@testable import MaxPaneKit

/// Telling an OAuth popup apart from a `target=_blank` link.
///
/// Both arrive at the same `WKUIDelegate` callback, and the cost of confusing
/// them is asymmetric: a link mistaken for a popup opens a dialog that closes
/// itself, while a popup mistaken for a link is a sign-in that completes in a
/// window with no way to hand the result back — the bug this piece exists for.
@Suite("popup policy")
struct PopupPolicyTests {
    /// `window.open(url, name, "width=480,height=620")` — every OAuth provider.
    @Test("a window.open with geometry is a popup")
    func geometryIsAPopup() {
        let intent = PopupIntent(
            opensNewView: true, isScripted: true, specifiesGeometry: true, suppressesChrome: false)
        #expect(PopupPolicy.disposition(for: intent) == .popup)
    }

    /// `window.open(url, name, "popup=yes")` passes no size at all.
    @Test("asking for a window without chrome is a popup even with no size")
    func chromelessIsAPopup() {
        let intent = PopupIntent(
            opensNewView: true, isScripted: false, specifiesGeometry: false, suppressesChrome: true)
        #expect(PopupPolicy.disposition(for: intent) == .popup)
    }

    /// The page holds the handle either way, so it expects an opener either way.
    @Test("a bare window.open is still a popup")
    func bareScriptOpenIsAPopup() {
        let intent = PopupIntent(
            opensNewView: true, isScripted: true, specifiesGeometry: false, suppressesChrome: false)
        #expect(PopupPolicy.disposition(for: intent) == .popup)
    }

    /// The behaviour that must not change: half the web opens a second page for
    /// reading this way, and those belong in lanes. A `target=_blank` form
    /// arrives as the same intent — unscripted, no geometry, no chrome request
    /// — so this is the form case too, and a second test of it was a copy.
    @Test("a target=_blank link or form is a lane")
    func linkIsALane() {
        let intent = PopupIntent(
            opensNewView: true, isScripted: false, specifiesGeometry: false, suppressesChrome: false)
        #expect(PopupPolicy.disposition(for: intent) == .lane)
    }

    /// Nothing needs creating if an existing frame is going to handle it.
    @Test("a navigation with a target frame never creates anything")
    func targetedNavigationIsNeverAPopup() {
        for scripted in [true, false] {
            let intent = PopupIntent(
                opensNewView: false, isScripted: scripted,
                specifiesGeometry: true, suppressesChrome: true)
            #expect(PopupPolicy.disposition(for: intent) == .lane)
        }
    }
}

/// How big a popup's dialog is, from what `window.open` asked for.
@Suite("popup geometry")
@MainActor
struct PopupGeometryTests {
    @Test("the page gets the size it asked for, and the bar goes on top of it")
    func asked() {
        let page = PopupGeometry.pageSize(width: 500, height: 600)
        #expect(page == NSSize(width: 500, height: 600))
        #expect(PopupGeometry.dialogSize(page: page, bar: 28) == NSSize(width: 500, height: 628))
    }

    @Test("no size is a portrait default, and one side missing keeps the other")
    func defaults() {
        #expect(PopupGeometry.pageSize(width: nil, height: nil) == PopupGeometry.defaultPage)
        #expect(PopupGeometry.pageSize(width: 700, height: nil)
            == NSSize(width: 700, height: PopupGeometry.defaultPage.height))
    }

    /// `width=1` is a pop-under, not a form.
    @Test("a slit is not a form, and a number that is not one is no size at all")
    func floor() {
        #expect(PopupGeometry.pageSize(width: 1, height: -5) == PopupGeometry.minimumPage)
        #expect(PopupGeometry.pageSize(width: .nan, height: .infinity) == PopupGeometry.defaultPage)
    }

    @Test("a popup bigger than the window keeps every dialog's margin")
    func clamped() {
        let area = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = PopupGeometry.dialogSize(page: PopupGeometry.pageSize(width: 1200, height: 900), bar: 28)
        #expect(Popup.frame(size: size, in: area) == NSRect(x: 40, y: 40, width: 720, height: 520))
    }
}

/// When a popup has outlived the page that opened it.
@Suite("popup opener")
struct PopupOpenerTests {
    /// A single-page app moving between routes is still the page waiting for
    /// the sign-in to report back.
    @Test("the same origin is still the page that asked")
    func sameOrigin() {
        #expect(!PopupOpener.hasLeft(
            openedFrom: "https://www.linkedin.com/login", now: "https://www.linkedin.com/feed/?trk=x"))
        #expect(!PopupOpener.hasLeft(
            openedFrom: "https://app.example.com/", now: "https://app.example.com:443/next"))
    }

    @Test("another scheme, host or port is a stranger")
    func otherOrigin() {
        #expect(PopupOpener.hasLeft(openedFrom: "https://www.linkedin.com/login", now: "https://evil.example/"))
        #expect(PopupOpener.hasLeft(openedFrom: "https://example.com/", now: "http://example.com/"))
        #expect(PopupOpener.hasLeft(openedFrom: "http://127.0.0.1:8080/", now: "http://127.0.0.1:8081/"))
    }

    @Test("an address with no origin decides nothing")
    func noOrigin() {
        #expect(!PopupOpener.hasLeft(openedFrom: nil, now: "https://example.com/"))
        #expect(!PopupOpener.hasLeft(openedFrom: "about:blank", now: "https://example.com/"))
    }
}

/// The popup's origin bar: the one row a page cannot draw.
@Suite("popup origin bar")
@MainActor
struct PopupBarTests {
    /// The path is the page's to choose, and a long one would push the host
    /// out of sight — the only part of the row that matters.
    @Test("https is the host alone")
    func secure() {
        #expect(WebPopupBar.originText(for: "https://accounts.google.com/v3/signin?continue=x").string
            == "accounts.google.com")
    }

    @Test("http keeps its scheme, and a port stays")
    func insecureAndPorts() {
        #expect(WebPopupBar.originText(for: "http://login.example.net/oauth").string == "http://login.example.net")
        #expect(WebPopupBar.originText(for: "https://sso.corp.example:8443/adfs").string == "sso.corp.example:8443")
    }

    @Test("a page with no host says what it is, not what a data URL holds")
    func hostless() {
        #expect(WebPopupBar.originText(for: "about:blank").string == "about:blank")
        #expect(WebPopupBar.originText(for: "data:text/html,hello").string == "data:")
        #expect(WebPopupBar.originText(for: "").string == "")
    }
}

/// App shortcuts while a popup has the keyboard. The menu would aim most of
/// them at "the focused page", which is the opener behind the dialog.
@Suite("popup keys")
@MainActor
struct PopupKeyTests {
    @Test("⌘W closes the dialog, ⌥⌘L fills it, ⌘R reloads it")
    func dialogKeys() {
        #expect(WebPopupDialog.keyAction(for: .closePane) == .close)
        #expect(WebPopupDialog.keyAction(for: .fillPassword) == .fill)
        #expect(WebPopupDialog.keyAction(for: .reload) == .reload)
        #expect(WebPopupDialog.keyAction(for: .hardReload) == .reload)
    }

    @Test("nothing reaches through the dialog to the page behind it")
    func openerIsLeftAlone() {
        for command in [Command.closeLane, .savePassword, .editAddress, .zoomIn, .zoomReset, .bookmarkPage] {
            #expect(WebPopupDialog.keyAction(for: command) == .ignore, "\(command)")
        }
    }

    @Test("keys about the strip still go to the menu")
    func stripKeys() {
        for command in [Command.openAnything, .toggleGallery, .focusRight, .showSettings] {
            #expect(WebPopupDialog.keyAction(for: command) == .app, "\(command)")
        }
    }
}

/// What a pane says it is.
@Suite("user agent")
struct BrowserUserAgentTests {
    /// The tokens Google's "is this a real browser" checks look for. The
    /// default `WKWebView` string has neither, which is the whole bug.
    @Test("the application name carries a Version and a Safari token")
    func carriesBrowserTokens() {
        let token = BrowserUserAgent.token(safariVersion: "26.6.2", appVersion: "0.1.0")
        #expect(token == "Version/26.6.2 Safari/605.1.15 MaxPane/0.1.0")
    }

    /// Read, not pinned: a hard-coded version is what goes stale and brings the
    /// "no longer supported" banner back.
    @Test("the Safari version comes from the installed Safari")
    func readsInstalledSafari() throws {
        let version = try #require(BrowserUserAgent.installedSafariVersion())
        #expect(version.first?.isNumber == true)
        #expect(version.contains("."))
        #expect(BrowserUserAgent.applicationName.contains("Version/\(version) Safari/605.1.15"))
    }

    /// A plist that is not a version string must not reach a request header.
    @Test("a missing or junk Info.plist falls back rather than improvising")
    func rejectsJunk() {
        #expect(BrowserUserAgent.installedSafariVersion(at: "/nowhere/Info.plist") == nil)
        #expect(BrowserUserAgent.installedSafariVersion(at: "/etc/hosts") == nil)
    }
}

/// The cookie jar a pane — and its popups — live in.
@Suite("data stores")
@MainActor
struct DataStoreIdentityTests {
    /// Two panes in the same shard must get the *same* store object, because
    /// that identity is what makes a popup's sign-in cookie readable by the page
    /// that opened it.
    @Test("a shard id always resolves to one store")
    func oneStorePerShard() {
        let pool = DataStorePool.shared
        #expect(pool.store("shard-1") === pool.store("shard-1"))
        #expect(pool.store("shard-1") !== pool.store("shard-2"))
        #expect(pool.store("shard-1").isPersistent)
    }

    /// A shard's UUID is what WebKit keys the on-disk jar by. If it moved
    /// between launches every login would be gone.
    @Test("a shard's UUID is derived, not generated")
    func uuidIsStable() {
        #expect(DataStorePool.uuid(for: "shard-0") == DataStorePool.uuid(for: "shard-0"))
        #expect(DataStorePool.uuid(for: "shard-0") != DataStorePool.uuid(for: "shard-1"))
    }
}

/// "Keep my place, open a sibling" — which is the gesture, and which is not.
///
/// The bug this replaces was the expensive kind: ⌘-click and middle-click both
/// navigated the lane you were reading, so the one gesture you reach for to
/// *avoid* losing a page was the one that lost it.
@Suite("link click")
struct LinkClickTests {
    @Test("⌘-click on a link opens a sibling lane")
    func commandClick() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [.command], buttonNumber: 0)
            == .siblingLane)
    }

    @Test("⇧⌘-click is the same gesture with a shift on it")
    func shiftCommandClick() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [.command, .shift], buttonNumber: 0)
            == .siblingLane)
    }

    /// The three-button mouse's version, and it needs no modifier.
    @Test("middle-click opens a sibling lane on its own")
    func middleClick() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [], buttonNumber: 2)
            == .siblingLane)
    }

    @Test("a plain click still navigates the lane")
    func plainClick() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [], buttonNumber: 0)
            == .inPlace)
    }

    /// ⌃-click is macOS's right-click and ⌥-click is "download the linked
    /// file". Claiming either would take a gesture away to add one.
    @Test("⌃⌘ and ⌥⌘ are left to the system")
    func systemModifiersAreLeftAlone() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [.command, .control], buttonNumber: 0)
            == .inPlace)
        #expect(LinkClick.outcome(
            navigationType: .linkActivated, modifiers: [.command, .option], buttonNumber: 0)
            == .inPlace)
    }

    /// The one that would be a data-loss bug rather than a layout one: a form
    /// carries state the server is waiting for, and opening it elsewhere would
    /// post it twice.
    @Test("only a link activation is ever a sibling lane")
    func onlyLinksQualify() {
        for type in [WKNavigationType.formSubmitted, .formResubmitted,
                     .backForward, .reload, .other] {
            #expect(LinkClick.outcome(
                navigationType: type, modifiers: [.command], buttonNumber: 2) == .inPlace,
                "\(type.rawValue) should never open a lane")
        }
    }

    /// Caps lock and the numeric-pad bit ride along in `modifierFlags` and are
    /// not modifiers anyone pressed. Masking them off is the difference between
    /// the gesture working and working most of the time.
    @Test("a stray device flag does not cancel the gesture")
    func deviceFlagsAreMaskedOff() {
        #expect(LinkClick.outcome(
            navigationType: .linkActivated,
            modifiers: [.command, .capsLock, .numericPad], buttonNumber: 0)
            == .siblingLane)
    }
}
