import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// What ⌘Y shows, given what the core ranked and what you typed.
///
/// The ranking itself is tested in Rust, where it happens
/// (`crates/laned-core/tests/history.rs`). What is left here is the part a
/// screenshot cannot check: whether a page with no `<title>` still has a name,
/// whether an empty result says why it is empty, and whether the highlighted
/// characters are the ones the core actually matched on.
@Suite("history palette")
struct HistoryPaletteTests {
    private func entry(
        _ url: String,
        title: String? = nil,
        count: UInt32 = 1,
        field: SearchField = .url
    ) -> HistoryEntry {
        HistoryEntry(
            url: url, title: title, firstVisitAt: 0, lastVisitAt: 0,
            visitCount: count, matchedField: field, score: 0)
    }

    // MARK: - what is shown

    @Test("an empty query lists what the core handed over, newest first")
    func emptyQueryListsEverything() {
        let entries = [entry("https://b.example", title: "B"), entry("https://a.example", title: "A")]
        let rows = HistoryRows.build(query: "", entries: entries, total: 2)
        #expect(rows.first == .section("RECENTLY VISITED"))
        // The palette never re-sorts: the core's order is the answer.
        #expect(rows.compactMap(\.url) == ["https://b.example", "https://a.example"])
    }

    @Test("typing says so, so you can tell a filtered list from the whole one")
    func typingChangesTheHeader() {
        let rows = HistoryRows.build(query: "b", entries: [entry("https://b.example")], total: 9)
        #expect(rows.first == .section("MATCHES"))
    }

    @Test("a fresh ledger says it is empty rather than showing an empty box")
    func nothingVisitedYet() {
        let rows = HistoryRows.build(query: "", entries: [], total: 0)
        #expect(rows == [.note(title: "history", detail: "nothing visited yet")])
        #expect(!rows.contains { $0.isSelectable })
    }

    @Test("a query that matches nothing names the query")
    func noMatchNamesTheQuery() {
        let rows = HistoryRows.build(query: " zzqq ", entries: [], total: 40)
        #expect(rows == [.note(title: "history", detail: "no page matches “zzqq”")])
    }

    // MARK: - naming

    @Test("a page with no title is named by its host, not by its whole URL")
    func untitledPagesAreNamedByHost() {
        // The URL is already on the row's second line; repeating it costs the
        // one line where the name would go.
        #expect(HistoryRows.name(entry("https://example.com/a/b?c=d")) == "example.com")
    }

    @Test("a page with an empty title is treated as having none")
    func emptyTitleIsNoTitle() {
        #expect(HistoryRows.name(entry("https://example.com/x", title: "")) == "example.com")
    }

    @Test("something that is not parseable as a URL still has a name")
    func unparseableUrlsStillRender() {
        let name = HistoryRows.name(entry("not a url at all"))
        #expect(!name.isEmpty)
    }

    @Test("a page seen once has no count; a page you live in does")
    func countsOnlyShowWhenTheyMeanSomething() {
        #expect(HistoryRows.countText(entry("https://a.example")) == "")
        #expect(HistoryRows.countText(entry("https://a.example", count: 7)) == "×7")
    }

    // MARK: - highlighting

    @Test("the matched characters are lit in both the title and the URL")
    func bothLinesAreHighlighted() {
        let rows = HistoryRows.build(
            query: "rust",
            entries: [entry("https://doc.rust-lang.org/", title: "Rust docs", field: .title)],
            total: 1)
        guard case .entry(_, let titleMatches, let urlMatches) = rows[1] else {
            Issue.record("expected an entry row")
            return
        }
        #expect(titleMatches == [0, 1, 2, 3])
        #expect(!urlMatches.isEmpty)
    }

    @Test("a multi-word query still highlights something")
    func spacesDoNotKillTheHighlight() {
        // The core's scorer treats a space as a gap between terms — `max pane`
        // matches `maxpane` there — so asking Swift's matcher for the literal
        // string would return nothing for exactly the queries that did match.
        let rows = HistoryRows.build(
            query: "max pane",
            entries: [entry("https://maxpane.example", title: "maxpane")],
            total: 1)
        guard case .entry(_, let titleMatches, _) = rows[1] else {
            Issue.record("expected an entry row")
            return
        }
        #expect(titleMatches == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("an untitled page never paints URL offsets onto its host")
    func hostNamesAreNotHighlightedWithUrlOffsets() {
        // The headline is a slice of the URL, so the URL's offsets would land
        // on the wrong characters.
        let rows = HistoryRows.build(
            query: "example", entries: [entry("https://example.com/deep/path")], total: 1)
        guard case .entry(let e, let titleMatches, _) = rows[1] else {
            Issue.record("expected an entry row")
            return
        }
        #expect(e.title == nil)
        #expect(titleMatches.isEmpty)
    }

    // MARK: - what a row hands back

    @Test("only pages can be chosen; headers and notes cannot")
    func onlyEntriesAreSelectable() {
        let rows = HistoryRows.build(query: "", entries: [entry("https://a.example")], total: 1)
        #expect(rows.filter(\.isSelectable).count == 1)
        #expect(rows.first?.isSelectable == false)
    }

    @Test("choosing a page hands back its URL and nothing else")
    func chosenRowIsAUrl() {
        let rows = HistoryRows.build(
            query: "", entries: [entry("https://a.example/x", title: "A")], total: 1)
        #expect(rows.compactMap(\.url) == ["https://a.example/x"])
    }
}

/// The seam itself: Swift calls the core, the core writes SQLite, and the
/// palette builds real views out of what comes back.
///
/// The Rust tests prove the record is right. This proves the app can reach it —
/// a wrapper that marshals the wrong way, or a row that crashes on a page with
/// no title, is invisible to both the Rust suite and a screenshot.
@Suite("history through the store")
@MainActor
struct HistoryStoreTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    @Test("a visit recorded through the store is found by title and by URL")
    func roundTrip() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id

        store.recordVisit(
            paneId: pane, url: "https://www.example.com/en", title: "Example Domain",
            requestedUrl: "https://example.com")

        #expect(store.historyCount == 1)
        #expect(store.history("domain").first?.url == "https://www.example.com/en")
        #expect(store.history("www.example").first?.title == "Example Domain")
        // The address that was typed, which a redirect would otherwise lose.
        #expect(store.history("example.com").count == 1)
    }

    @Test("a late title reaches the record without counting a second visit")
    func lateTitle() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id

        store.recordVisit(paneId: pane, url: "https://example.com/a", title: nil)
        store.noteVisitTitle(url: "https://example.com/a", title: "Arrived Late")
        #expect(store.history("").first?.title == "Arrived Late")
        #expect(store.history("").first?.visitCount == 1)
        // A nil URL is what a pane that has not loaded anything hands over.
        store.noteVisitTitle(url: nil, title: "Nowhere")
        #expect(store.historyCount == 1)
    }

    @Test("forgetting a page removes it from what the palette would show")
    func forget() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        store.recordVisit(paneId: pane, url: "https://a.example", title: "A")
        store.recordVisit(paneId: pane, url: "https://b.example", title: "B")

        store.forgetVisit("https://a.example")
        #expect(store.history("").map(\.url) == ["https://b.example"])
        store.clearHistory()
        #expect(store.historyCount == 0)
    }

    @Test("every row the palette can produce builds a real view")
    func rowsRender() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        store.recordVisit(paneId: pane, url: "https://titled.example/x", title: "A Titled Page")
        // No title, and a long URL — the row that has the least to work with.
        store.recordVisit(paneId: pane, url: "https://untitled.example/" + String(repeating: "a/", count: 60), title: nil)

        for query in ["", "titled", "zzqq"] {
            let rows = HistoryRows.build(
                query: query, entries: store.history(query), total: store.historyCount)
            #expect(!rows.isEmpty, "“\(query)” produced no rows at all")
            for row in rows {
                let view: NSView
                switch row {
                case .section(let t):
                    view = PaletteSectionRow(title: t, note: "")
                case .note(let t, let detail):
                    view = PaletteSectionRow(title: t, note: detail)
                case .entry(let e, let titleMatches, let urlMatches):
                    view = HistoryPaletteRow(
                        entry: e, titleMatches: titleMatches, urlMatches: urlMatches)
                }
                view.frame = NSRect(x: 0, y: 0, width: 760, height: 44)
                view.layoutSubtreeIfNeeded()
                #expect(!view.subviews.isEmpty)
            }
        }
    }
}

/// A picture of the palette, for the same reason `LaneHeaderRenderTests` takes
/// one: the rules about what a row says are testable, and whether the result is
/// legible is not. Gated on an environment variable so it costs nothing in a
/// normal run.
///
///     MAXPANE_HISTORY_SHOTS=/tmp/shots ./scripts/test.sh
@Suite("history palette rendering")
@MainActor
struct HistoryPaletteRenderTests {
    @Test("renders the rows that have the least to work with")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_HISTORY_SHOTS"] else { return }

        // Ordered worst-case first: the two rows that have to stay legible are
        // an untitled page with a long URL, and a page whose name is longer
        // than the column.
        let entries: [HistoryEntry] = [
            HistoryEntry(url: "https://doc.rust-lang.org/std/collections/struct.HashMap.html",
                         title: "HashMap in std::collections - Rust",
                         firstVisitAt: 0, lastVisitAt: nowMs(-42), visitCount: 12,
                         matchedField: .title, score: 300),
            HistoryEntry(url: "https://github.com/anthropics/claude-code/pull/4821/files#diff-9f2a",
                         title: nil, firstVisitAt: 0, lastVisitAt: nowMs(-3600 * 5),
                         visitCount: 1, matchedField: .url, score: 60),
            HistoryEntry(url: "http://localhost:3000/dashboard",
                         title: "Trifecta — Discovery dashboard, staging, do not use in anger",
                         firstVisitAt: 0, lastVisitAt: nowMs(-86_400 * 3), visitCount: 148,
                         matchedField: .title, score: 240),
        ]

        for width in [560.0, 760.0] as [CGFloat] {
            let rows = HistoryRows.build(query: "ha", entries: entries, total: 1_204)
            let heights = rows.map { row -> CGFloat in
                if case .entry = row { return 44 }
                return 26
            }
            let sheet = NSView(frame: NSRect(
                x: 0, y: 0, width: width, height: heights.reduce(0, +) + 12))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.laneBackground.cgColor

            var y = sheet.bounds.height - 6
            for (row, height) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .section(let t): view = PaletteSectionRow(title: t, note: "")
                case .note(let t, let detail): view = PaletteSectionRow(title: t, note: detail)
                case .entry(let e, let titleMatches, let urlMatches):
                    view = HistoryPaletteRow(
                        entry: e, titleMatches: titleMatches, urlMatches: urlMatches)
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("history-\(Int(width)).png"))
        }
    }

    private func nowMs(_ secondsAgo: Double) -> Int64 {
        Int64((Date().timeIntervalSince1970 + secondsAgo) * 1000)
    }
}
