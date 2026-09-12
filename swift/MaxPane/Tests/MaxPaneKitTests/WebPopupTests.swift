import Testing
import WebKit
@testable import MaxPaneKit

/// Telling an OAuth popup apart from a `target=_blank` link.
///
/// Both arrive at the same `WKUIDelegate` callback, and the cost of confusing
/// them is asymmetric: a link mistaken for a popup opens a pane that can close
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
    /// reading this way, and those belong in lanes.
    @Test("a target=_blank link is a lane")
    func linkIsALane() {
        let intent = PopupIntent(
            opensNewView: true, isScripted: false, specifiesGeometry: false, suppressesChrome: false)
        #expect(PopupPolicy.disposition(for: intent) == .lane)
    }

    @Test("a form with target=_blank is a lane")
    func formIsALane() {
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

/// The handoff between `window.open` returning and the pane that will hold it.
@Suite("popup handoff")
@MainActor
struct PopupHandoffTests {
    /// A view with no navigation: WebKit spawns nothing until something loads,
    /// so this costs an object and no process.
    private func view() -> WKWebView { WKWebView(frame: .zero, configuration: .init()) }

    /// The claim happens inside the ledger write that creates the pane, before
    /// anything knows the new pane's id — so the URL is all there is to match on.
    @Test("a pane built during the write claims the pending popup by URL")
    func claimsPendingByUrl() {
        let handoff = PopupHandoff.shared
        let popup = view()
        handoff.stage(.init(
            webView: popup, url: "https://example.com/auth", openerPaneId: "p1", dataStoreId: "shard-3"))

        #expect(handoff.claim(paneId: "other", url: "https://example.com/elsewhere") == nil)
        let claimed = handoff.claim(paneId: "p2", url: "https://example.com/auth")
        #expect(claimed?.webView === popup)
        #expect(claimed?.dataStoreId == "shard-3")
        // Exactly once: a second pane with the same URL is a different page.
        #expect(handoff.claim(paneId: "p3", url: "https://example.com/auth") == nil)
    }

    /// The other order: the new lane was outside the materialisation window, so
    /// its controller is built later and the id is the only handle left.
    @Test("an unclaimed popup waits under the pane id the write produced")
    func resolvesToPaneId() {
        let handoff = PopupHandoff.shared
        let popup = view()
        handoff.stage(.init(
            webView: popup, url: "https://example.com/late", openerPaneId: "p1", dataStoreId: "shard-0"))
        handoff.resolvePending(to: "p9")

        #expect(handoff.paneId(holding: popup) == "p9")
        #expect(handoff.claim(paneId: "p8", url: "https://example.com/late") == nil)
        #expect(handoff.claim(paneId: "p9", url: nil)?.webView === popup)
    }

    @Test("a pane that goes away takes its staged popup with it")
    func discardsOnTearDown() {
        let handoff = PopupHandoff.shared
        let popup = view()
        handoff.stage(.init(
            webView: popup, url: "https://example.com/gone", openerPaneId: "p1", dataStoreId: "shard-0"))
        handoff.resolvePending(to: "p7")
        handoff.discard(paneId: "p7")
        #expect(handoff.paneId(holding: popup) == nil)
        #expect(handoff.claim(paneId: "p7", url: "https://example.com/gone") == nil)
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
