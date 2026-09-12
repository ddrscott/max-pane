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
            let isURL = NewPaneEntries.looksLikeURL(text)
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
