import AppKit
import Foundation
import Testing
@testable import MaxPaneKit

/// The address bar's two jobs, both of which are string problems.
///
/// Tested rather than screenshotted because the failures are invisible: an
/// address bar that emphasises the wrong half of a hostname still *looks*
/// right, and it is the one piece of chrome whose job is to be trusted.
@Suite("address bar")
struct BrowserAddressTests {
    // MARK: - what it shows

    @Test("https is dropped and the registrable domain is the emphasised run")
    func httpsIsDropped() {
        let display = BrowserAddress.display("https://www.evenrealities.com/products/g2-b")
        #expect(display.dimLead == "www.")
        #expect(display.strong == "evenrealities.com")
        #expect(display.dimTail == "/products/g2-b")
    }

    /// The asymmetry is the point: https is every page and carries no
    /// information, http is the one scheme worth noticing.
    @Test("http is kept")
    func httpIsKept() {
        let display = BrowserAddress.display("http://example.com/x")
        #expect(display.dimLead == "http://")
        #expect(display.strong == "example.com")
    }

    /// The whole reason the emphasis is on the registrable domain rather than
    /// the host: the left-hand labels are the attacker's to choose.
    @Test("a lookalike subdomain does not steal the emphasis")
    func lookalikeSubdomain() {
        let display = BrowserAddress.display("https://login.google.com.evil.example/oauth")
        #expect(display.strong == "evil.example")
        #expect(display.dimLead == "login.google.com.")
    }

    @Test("a two-label registry suffix keeps three labels")
    func twoLabelSuffix() {
        #expect(BrowserAddress.display("https://www.bbc.co.uk/news").strong == "bbc.co.uk")
        #expect(BrowserAddress.display("https://bbc.co.uk/news").strong == "bbc.co.uk")
    }

    @Test("a port survives into the tail")
    func portInTail() {
        let display = BrowserAddress.display("http://localhost:3000/app")
        #expect(display.strong == "localhost")
        #expect(display.dimTail == ":3000/app")
    }

    /// `URL.path` normalises a trailing slash in both directions, so the tail is
    /// taken off the raw string — the address bar has to show the address.
    @Test("a trailing slash is shown exactly as the page has it")
    func trailingSlash() {
        #expect(BrowserAddress.display("https://example.com/").dimTail == "/")
        #expect(BrowserAddress.display("https://example.com").dimTail == "")
    }

    @Test("something with no host is left whole and unemphasised")
    func opaqueURL() {
        let display = BrowserAddress.display("about:blank")
        #expect(display.strong.isEmpty)
        #expect(display.plain == "about:blank")
    }

    // MARK: - the padlock's job

    @Test("https says nothing, http warns, loopback does not")
    func security() {
        #expect(BrowserAddress.security(of: "https://example.com") == .secure)
        #expect(BrowserAddress.security(of: "http://example.com") == .insecure)
        // Warning about a dev server twenty times a day is how a warning stops
        // being read.
        #expect(BrowserAddress.security(of: "http://localhost:3000") == .none)
        #expect(BrowserAddress.security(of: "http://127.0.0.1:8080/x") == .none)
        #expect(BrowserAddress.security(of: "file:///tmp/x.html") == .local)
        #expect(BrowserAddress.security(of: "about:blank") == .none)
    }

    // MARK: - what Return does

    @Test("a bare host is an address and gets https")
    func bareHost() {
        #expect(BrowserAddress.destination(for: "example.com") == .url("https://example.com"))
        #expect(BrowserAddress.destination(for: "  example.com/a  ") == .url("https://example.com/a"))
    }

    /// A dev server almost never has a certificate, and https://localhost:3000
    /// fails in a way that reads as "the server is down".
    @Test("the loopback gets http, not https")
    func loopbackGetsHttp() {
        #expect(BrowserAddress.destination(for: "localhost:3000") == .url("http://localhost:3000"))
        #expect(BrowserAddress.destination(for: "127.0.0.1/health") == .url("http://127.0.0.1/health"))
    }

    @Test("an explicit scheme is passed through untouched")
    func explicitScheme() {
        #expect(BrowserAddress.destination(for: "https://a.example/b") == .url("https://a.example/b"))
        #expect(BrowserAddress.destination(for: "file:///tmp/x") == .url("file:///tmp/x"))
        #expect(BrowserAddress.destination(for: "about:blank") == .url("about:blank"))
    }

    /// `localhost:3000` is a legal scheme by RFC 3986's grammar and is not one.
    @Test("a port is not mistaken for a scheme")
    func portIsNotAScheme() {
        #expect(BrowserAddress.explicitScheme("localhost:3000") == nil)
        #expect(BrowserAddress.explicitScheme("192.168.0.4:8080/health") == nil)
        #expect(BrowserAddress.explicitScheme("https://x") == "https")
    }

    /// The whole reason the address bar can also be the search box.
    @Test("anything that is not an address is a search")
    func searches() {
        #expect(BrowserAddress.destination(for: "swift strict concurrency")
            == .search("swift strict concurrency"))
        #expect(BrowserAddress.destination(for: "kubectl") == .search("kubectl"))
        #expect(BrowserAddress.destination(for: "") == nil)
        #expect(BrowserAddress.destination(for: "   ") == nil)
    }

    /// One rule for both fields. ⌘T's picker and the address bar disagreeing
    /// about what `make` means is an app that has to be learned twice.
    @Test("the URL rule is the picker's rule")
    func sameRuleAsThePicker() {
        for text in ["example.com", "make", "localhost:3000", "main.rs", "docs.rs/tokio", "git status"] {
            let isURL = OmniText.looksLikeURL(text)
            let isSearch = BrowserAddress.destination(for: text).map {
                if case .search = $0 { return true } else { return false }
            } ?? false
            #expect(isURL != isSearch, "disagreement about \(text)")
        }
    }

    @Test("a query is escaped into the engine's template")
    func searchTemplate() {
        let url = BrowserAddress.searchURL(
            for: "a b&c", template: "https://www.google.com/search?q=%s")
        #expect(url == "https://www.google.com/search?q=a%20b%26c")
    }

    @Test("resolve takes a typed line all the way")
    func resolve() {
        let template = "https://duckduckgo.com/?q=%s"
        #expect(BrowserAddress.resolve("example.com", searchTemplate: template)
            == "https://example.com")
        #expect(BrowserAddress.resolve("hello there", searchTemplate: template)
            == "https://duckduckgo.com/?q=hello%20there")
        #expect(BrowserAddress.resolve("  ", searchTemplate: template) == nil)
    }
}

/// Zoom that survives a restart.
///
/// The acceptance criterion for this round is literally "zoom survives a
/// restart", and the only way to test that without relaunching an app is to
/// prove the second reader sees what the first writer wrote.
@Suite("pane zoom persistence")
@MainActor
struct PaneZoomStoreTests {
    private func scratch() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-zoom-\(UUID().uuidString)")
            .appendingPathComponent("ledger.db").path
    }

    /// Zoom lives in the ledger, like everything else durable.
    ///
    /// It arrived as a JSON file beside the ledger because the crate was busy,
    /// and the file said so itself. A ratio is eight bytes; the rule that the
    /// app owns no durable state is not suspended for small ones.
    @Test("a pane's zoom survives a relaunch")
    func zoomIsInTheLedger() throws {
        let path = scratch()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let paneId: String
        do {
            let store = try StripStore(ledgerPath: path)
            try store.newWebLane(url: "https://example.com", near: nil)
            paneId = store.state.lanes[0].panes[0].id
            #expect(store.state.lanes[0].panes[0].zoom == 1, "a new pane is actual size")
            store.setPaneZoom(paneId, 1.5)
        }

        let reopened = try StripStore(ledgerPath: path)
        #expect(reopened.state.lanes[0].panes[0].id == paneId)
        #expect(reopened.state.lanes[0].panes[0].zoom == 1.5)
    }

    @Test("a zoom that is not a usable ratio is refused, not stored")
    func nonsenseZoomIsRefused() throws {
        // One NaN and the pane comes back at a size nothing can render.
        let path = scratch()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let store = try StripStore(ledgerPath: path)
        try store.newWebLane(url: "https://example.com", near: nil)
        let paneId = store.state.lanes[0].panes[0].id
        store.setPaneZoom(paneId, 1.25)
        store.setPaneZoom(paneId, .nan)
        store.setPaneZoom(paneId, 0)

        let reopened = try StripStore(ledgerPath: path)
        #expect(reopened.state.lanes[0].panes[0].zoom == 1.25, "the last good value stands")
    }

    /// Closing a pane takes its zoom with it, without anyone sweeping.
    ///
    /// The sidecar this replaced needed a sweep on launch, because a `kill -9`
    /// left levels behind for panes that no longer existed. A column on `pane`
    /// cannot: the row goes, the zoom goes with it.
    @Test("a closed pane leaves no zoom behind")
    func closingTakesTheZoom() throws {
        let path = scratch()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }

        let store = try StripStore(ledgerPath: path)
        try store.newWebLane(url: "https://gone.example", near: nil)
        try store.newWebLane(url: "https://here.example", near: nil)
        let gone = store.state.lanes[0].panes[0].id
        let here = store.state.lanes[1].panes[0].id
        store.setPaneZoom(gone, 1.5)
        store.setPaneZoom(here, 0.8)
        try store.closePane(gone)

        let reopened = try StripStore(ledgerPath: path)
        #expect(reopened.state.lanes.count == 1)
        #expect(reopened.state.lanes[0].panes[0].zoom == 0.8)
    }

    /// `MAXPANE_LEDGER` isolation has to cover this too, or a throwaway instance
    /// rewrites the zoom levels in the strip someone is working in.
    @Test("two ledgers keep separate levels")
    func isolatedPerLedger() throws {
        let a = scratch(), b = scratch()
        for path in [a, b] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        defer {
            for path in [a, b] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
        }
        let first = try StripStore(ledgerPath: a)
        try first.newWebLane(url: "https://example.com", near: nil)
        first.setPaneZoom(first.state.lanes[0].panes[0].id, 2.0)

        let second = try StripStore(ledgerPath: b)
        try second.newWebLane(url: "https://example.com", near: nil)
        #expect(second.state.lanes[0].panes[0].zoom == 1)
    }
}

/// The ladder the zoom readout prints.
@Suite("zoom ladder")
struct PaneZoomLadderTests {
    /// Every rung has to print as a whole number of percent, or the readout in
    /// the chrome bar says `67%` for 0.6666666 and `80%` for 0.8 and the two
    /// disagree about how many digits a zoom level has.
    @Test("every rung is a whole percent")
    func wholePercents() {
        for rung in PaneZoom.ladder {
            let percent = rung * 100
            #expect(abs(percent - percent.rounded()) < 0.001, "\(rung) is not a whole percent")
        }
    }

    @Test("the ladder stops at both ends")
    func stopsAtTheEnds() {
        #expect(PaneZoom.next(from: 3.0, up: true) == 3.0)
        #expect(PaneZoom.next(from: 0.5, up: false) == 0.5)
        #expect(PaneZoom.next(from: 1.0, up: true) == 1.1)
        #expect(PaneZoom.next(from: 1.0, up: false) == 0.9)
    }
}

/// What a lane calls a page that never named itself.
///
/// Tested rather than looked at because the failure is a *stale* header, not a
/// blank one: the lane goes on reading `Computer program – Wikipedia` while you
/// browse five untitled pages, and it looks completely normal the whole time.
@Suite("untitled lane label")
struct LaneLabelTests {
    @Test("host and path, without the scheme or www.")
    func hostAndPath() {
        #expect(BrowserAddress.laneLabel(for: "https://www.example.com/data.json")
            == "example.com/data.json")
    }

    /// The pair this exists for. Two dev servers and two endpoints are four
    /// lanes that the host alone would call the same thing.
    @Test("the port and the path are what tell dev servers apart")
    func portAndPathSurvive() {
        #expect(BrowserAddress.laneLabel(for: "http://localhost:3000/api/users")
            == "localhost:3000/api/users")
        #expect(BrowserAddress.laneLabel(for: "http://localhost:8080/api/users")
            == "localhost:8080/api/users")
    }

    @Test("a bare root is just the host")
    func rootIsJustTheHost() {
        #expect(BrowserAddress.laneLabel(for: "https://example.com/") == "example.com")
        #expect(BrowserAddress.laneLabel(for: "https://example.com") == "example.com")
    }

    /// A query is noise in a 28 pt header and is never the thing being scanned
    /// for; the path before it already is.
    @Test("the query is left off")
    func queryIsLeftOff() {
        #expect(BrowserAddress.laneLabel(for: "http://localhost:3000/search?q=actors&page=4")
            == "localhost:3000/search")
    }

    @Test("something with no host falls back to the whole string")
    func noHost() {
        #expect(BrowserAddress.laneLabel(for: "about:blank") == "about:blank")
    }
}

/// The line a failed navigation puts in the address slot.
///
/// The interesting half is the silences. Before any of this, a failed load said
/// nothing at all — but a version that says *everything* is worse, because the
/// ✕ button and every `<a download>` would print an amber error for doing
/// exactly what was asked.
@Suite("navigation failure")
struct NavigationFailureTests {
    @Test("a host that does not resolve names itself")
    func hostNotFound() {
        #expect(BrowserAddress.failure(
            domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
            failingURL: "https://no-such-host-zzz9911.example.com/page")
            == "server not found — no-such-host-zzz9911.example.com")
    }

    /// Pressing ✕, and every navigation that superseded another. Silence is the
    /// only correct answer: the user asked for it.
    @Test("a cancelled load says nothing")
    func cancelIsSilent() {
        #expect(BrowserAddress.failure(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled,
            failingURL: "https://example.com/") == nil)
    }

    /// What a download looks like from the navigation delegate.
    @Test("an interrupted frame load says nothing")
    func frameLoadInterruptedIsSilent() {
        #expect(BrowserAddress.failure(
            domain: "WebKitErrorDomain", code: 102, failingURL: "https://example.com/x.zip") == nil)
    }

    @Test("an unrecognised code still says something rather than nothing")
    func unknownCodeStillSpeaks() {
        let text = BrowserAddress.failure(
            domain: NSURLErrorDomain, code: -4242, failingURL: "https://example.com/")
        #expect(text == "could not load — example.com")
    }

    @Test("a failure with no URL is still a sentence")
    func noFailingURL() {
        #expect(BrowserAddress.failure(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, failingURL: nil)
            == "no internet connection")
    }

    /// Short and lowercase on purpose: this shares a 300 pt field with the
    /// address, and Apple's own strings are sentences.
    @Test("every phrase fits the slot")
    func phrasesAreShort() {
        let codes = [
            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
            NSURLErrorUnsupportedURL, NSURLErrorBadURL,
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorAppTransportSecurityRequiresSecureConnection,
        ]
        for code in codes {
            let text = BrowserAddress.failure(domain: NSURLErrorDomain, code: code, failingURL: nil)
            #expect(text != nil, "code \(code) says nothing")
            #expect((text ?? "").count <= 32, "code \(code): \(text ?? "")")
            #expect(text?.first?.isUppercase != true, "code \(code) is capitalised")
        }
    }
}


/// Two settings whose failure mode is silence.
@Suite("chrome that fails quietly")
struct QuietChromeTests {
    /// An `NSTextField` takes its line breaking from the attributed string's
    /// paragraph style and ignores the cell's `lineBreakMode` — which is set,
    /// and was doing nothing. The address is drawn as three coloured runs, so
    /// it goes through that path every time, and a 60-character GitHub URL
    /// stopped mid-character with no ellipsis.
    @Test("the address carries its own truncation")
    func addressTruncates() {
        let plain = NSAttributedString(string: "github.com/rust-lang/rust/pull/135000/files")
        let clipped = AddressField.clipped(plain)
        var range = NSRange()
        let style = clipped.attribute(.paragraphStyle, at: 0, effectiveRange: &range)
        #expect((style as? NSParagraphStyle)?.lineBreakMode == .byTruncatingTail)
        #expect(range.length == clipped.length, "truncation has to cover every run")
        #expect(clipped.string == plain.string)
    }

    /// `NSAllowsArbitraryLoads=false` alone meant plain http to anything off the
    /// loopback did not load and said nothing — `http://example.com/`, which
    /// curl fetches with 200 from this machine, simply did not happen. The
    /// narrow key lifts ATS for WKWebView only; the app's own connections stay
    /// under the strict one, which is why both are asserted here.
    @Test("web content is exempt from ATS and the app is not")
    func webContentIsExemptFromATS() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaxPaneKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MaxPane
            .appendingPathComponent("Resources/Info.plist")
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any]
        let ats = try #require(parsed?["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == false)
    }
}
