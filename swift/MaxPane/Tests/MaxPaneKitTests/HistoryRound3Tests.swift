import AppKit
import Foundation
import LanedCore
import Testing

@testable import MaxPaneKit

/// History, round 3: the view with room in it.
///
/// Everything asserted here is what round 2's critic measured and could not fix
/// inside a palette row — where a day starts, how many pages a header may claim,
/// what the list does past row 60, and what the app says out loud before it
/// deletes something. `HistoryBrowseModel` takes its calendar and its per-day
/// counts as arguments for the reason `HistoryClock` takes a calendar: a test
/// that only passes in September is a test that fails in October.
@MainActor
struct HistoryBrowseModelTests {
    /// A fixed calendar, so a day boundary is a day boundary wherever this runs.
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static func entry(
        _ url: String, title: String? = nil, at: Date, visits: UInt32 = 1
    ) -> HistoryEntry {
        HistoryEntry(
            url: url, title: title,
            firstVisitAt: Int64(at.timeIntervalSince1970 * 1000),
            lastVisitAt: Int64(at.timeIntervalSince1970 * 1000),
            visitCount: visits, matchedField: .url, score: 0)
    }

    /// Noon UTC on 9 September 2025, and offsets from it.
    static let noon = Date(timeIntervalSince1970: 1_757_419_200)

    // MARK: - paging

    /// The measured failure: 75 presses of ↓ and the list ended at row 60 while
    /// the footer said 5,014.
    @Test func the_list_does_not_stop_until_the_ledger_does() {
        var model = HistoryBrowseModel()
        let page = HistoryBrowseModel.pageSize
        model.append((0..<Int(page)).map { Self.entry("https://e.example/\($0)", at: Self.noon) },
                     limit: page)
        #expect(!model.exhausted, "a full page is never the end of the list")
        #expect(model.nextOffset == page, "the next page would have re-read the first")

        model.append((0..<7).map { Self.entry("https://e.example/tail\($0)", at: Self.noon) },
                     limit: page)
        #expect(model.exhausted, "a short page is the end, said by the list rather than guessed")
        #expect(model.loadedCount == Int(page) + 7)
    }

    /// A page that comes back exactly empty is still the end, and asking again
    /// after that is what a scroll to the bottom would otherwise do forever.
    @Test func an_empty_page_ends_the_list() {
        var model = HistoryBrowseModel()
        model.append([], limit: HistoryBrowseModel.pageSize)
        #expect(model.exhausted)
        #expect(model.isEmpty)
    }

    /// Typing is a different list, not a filter over the one already loaded —
    /// otherwise page two of a search would be page two of the browse.
    @Test func a_query_starts_the_list_again() {
        var model = HistoryBrowseModel()
        model.append([Self.entry("https://e.example/a", at: Self.noon)], limit: 120)
        model.restart(query: "grafana")
        #expect(model.isEmpty)
        #expect(model.nextOffset == 0)
        #expect(!model.exhausted, "the new list inherited the old one's ending")
    }

    // MARK: - day grouping

    @Test func each_day_gets_one_header_and_the_rows_that_belong_to_it() {
        var model = HistoryBrowseModel()
        let day: TimeInterval = 86_400
        model.append([
            Self.entry("https://e.example/1", at: Self.noon),
            Self.entry("https://e.example/2", at: Self.noon.addingTimeInterval(-3600)),
            Self.entry("https://e.example/3", at: Self.noon.addingTimeInterval(-day)),
        ], limit: 120)

        let rows = model.rows(now: Self.noon, calendar: Self.utc) { _, _ in 9 }
        guard rows.count == 5 else { return #expect(Bool(false), "expected two headers, got \(rows)") }
        guard case .day(let today) = rows[0], case .day(let before) = rows[3] else {
            return #expect(Bool(false), "the headers are not where the days change")
        }
        #expect(today.title == "Today")
        #expect(before.title == "Yesterday")
        if case .page = rows[1], case .page = rows[2] {} else {
            #expect(Bool(false), "the first day lost a row")
        }
    }

    /// The header's number comes from the ledger, not from the rows above it.
    ///
    /// This is the whole reason the count exists. A reader who has loaded 2 of a
    /// day's 41 pages and is told "2" concludes the day had 2 — which is round
    /// 1's `0 OF 5013 PAGES` in a different place, and this project has now paid
    /// for that mistake twice.
    @Test func a_day_header_counts_the_record_and_not_the_rows_loaded() {
        var model = HistoryBrowseModel()
        model.append([
            Self.entry("https://e.example/1", at: Self.noon),
            Self.entry("https://e.example/2", at: Self.noon),
        ], limit: 120)

        var asked: [(Date, Date)] = []
        let rows = model.rows(now: Self.noon, calendar: Self.utc) { start, end in
            asked.append((start, end))
            return 41
        }
        guard case .day(let header) = rows[0] else {
            return #expect(Bool(false), "no header over the day")
        }
        #expect(header.count == 41)
        #expect(asked.count == 1, "the ledger was asked once per day, not once per row")
        // Half-open and exactly one day wide, so two adjacent headers cannot
        // both claim the same page.
        #expect(asked[0].1.timeIntervalSince(asked[0].0) == 86_400)
        #expect(asked[0].0 == Self.utc.startOfDay(for: Self.noon))
    }

    /// A search is ranked by how well it matches, so its rows are not in date
    /// order and a day header over them would be a header over rows that are not
    /// all from that day.
    @Test func a_search_is_not_filed_by_day() {
        var model = HistoryBrowseModel()
        model.restart(query: "example")
        model.append([
            Self.entry("https://e.example/1", at: Self.noon),
            Self.entry("https://e.example/2", at: Self.noon.addingTimeInterval(-86_400 * 30)),
        ], limit: 120)

        let rows = model.rows(now: Self.noon, calendar: Self.utc) { _, _ in
            #expect(Bool(false), "a search asked for a day count it has no header to put it on")
            return 0
        }
        #expect(rows.count == 2)
        for row in rows {
            if case .day = row { #expect(Bool(false), "a ranked list was grouped by day") }
        }
    }

    /// Forgetting one row takes that row out, and leaves the four hundred the
    /// reader scrolled past where they were.
    @Test func forgetting_a_row_does_not_rebuild_the_list() {
        var model = HistoryBrowseModel()
        model.append((0..<5).map { Self.entry("https://e.example/\($0)", at: Self.noon) },
                     limit: 120)
        model.forget(url: "https://e.example/2")
        #expect(model.loadedCount == 4)
        #expect(model.entries.map(\.url) == [
            "https://e.example/0", "https://e.example/1",
            "https://e.example/3", "https://e.example/4",
        ])
        // The offset follows what is held, so the next page picks up after the
        // rows on screen rather than skipping one to make up for the delete.
        #expect(model.nextOffset == 4)
    }

    // MARK: - the two destructive sentences

    /// The measured failure, exactly: two CloudWatch URLs with the same title
    /// and the same truncation, one of them deleted with no way to tell which.
    @Test func the_forget_dialog_prints_the_tail_the_list_could_not() {
        let base = "https://console.aws.amazon.com/cloudwatch/home#logsV2:log-group/aws$252Flambda$252Fingest/log-events/"
        let a = Self.entry(base + "stream-a", title: "CloudWatch", at: Self.noon)
        let b = Self.entry(base + "stream-b", title: "CloudWatch", at: Self.noon)
        let promptA = HistoryBrowseModel.forgetPrompt(a)
        let promptB = HistoryBrowseModel.forgetPrompt(b)

        #expect(promptA.message == promptB.message, "the title is not what tells them apart")
        #expect(promptA.detail != promptB.detail, "the dialog could not tell the two rows apart")
        #expect(promptA.detail.contains(base + "stream-a"))
        #expect(!promptA.detail.contains("…"), "the dialog abbreviated the one thing it is for")
        #expect(promptA.detail.contains("cannot be undone"))
    }

    /// A page with no title is named by nothing else, so the dialog does not
    /// print an empty pair of quotes at the reader.
    @Test func an_untitled_page_is_still_a_question_that_reads() {
        let prompt = HistoryBrowseModel.forgetPrompt(
            Self.entry("https://e.example/x", title: nil, at: Self.noon))
        #expect(prompt.message == "Forget this page?")
        #expect(prompt.detail.hasPrefix("https://e.example/x"))
    }

    /// Pages, never visits. One row is one URL however many times it was opened,
    /// and a dialog counting visits would be describing a record this app does
    /// not keep.
    @Test func the_clear_dialog_counts_pages() {
        let one = HistoryBrowseModel.clearPrompt(.lastHour, pages: 1)
        #expect(one.message.contains("1 page"))
        #expect(!one.message.contains("1 pages"))
        #expect(one.message.contains("the last hour"))

        let many = HistoryBrowseModel.clearPrompt(.everything, pages: 112_840)
        #expect(many.message.contains("112840 pages") || many.message.contains("112,840 pages"))
        #expect(many.detail.contains("cannot be undone"))
    }

    /// "Today" is midnight here, not twenty-four hours ago. Someone clearing
    /// today at 00:30 means the half hour they have been awake for, and the two
    /// answers differ by a whole day's browsing at exactly the hour someone is
    /// most likely to be asking.
    @Test func today_is_midnight_and_not_a_rolling_day() {
        let halfPastMidnight = Self.utc.startOfDay(for: Self.noon).addingTimeInterval(1_800)
        let cutoff = HistoryClearRange.today.cutoff(now: halfPastMidnight, calendar: Self.utc)
        #expect(cutoff == Self.utc.startOfDay(for: halfPastMidnight))
        #expect(halfPastMidnight.timeIntervalSince(cutoff) == 1_800)
    }

    @Test func the_other_ranges_are_the_spans_they_are_named_for() {
        #expect(HistoryClearRange.lastHour.cutoff(now: Self.noon, calendar: Self.utc)
            == Self.noon.addingTimeInterval(-3600))
        #expect(HistoryClearRange.lastWeek.cutoff(now: Self.noon, calendar: Self.utc)
            == Self.utc.startOfDay(for: Self.noon).addingTimeInterval(-7 * 86_400))
        // Everything is the same statement with a cutoff nothing can be before,
        // rather than a second code path that deletes by other means.
        #expect(HistoryClearRange.everything.cutoff(now: Self.noon, calendar: Self.utc)
            == Date(timeIntervalSince1970: 0))
    }
}

/// The day a header names — `HistoryClock.stamp`'s sibling, for a row that has
/// rows under it rather than a row in a column.
@MainActor
struct HistoryDayNameTests {
    static let utc = HistoryBrowseModelTests.utc
    static let noon = HistoryBrowseModelTests.noon

    @Test func the_two_days_everyone_has_a_word_for_get_the_word() {
        #expect(HistoryClock.day(Self.noon, now: Self.noon, calendar: Self.utc) == "Today")
        #expect(HistoryClock.day(
            Self.noon.addingTimeInterval(-86_400), now: Self.noon, calendar: Self.utc)
            == "Yesterday")
    }

    /// Counted in days, not in 24-hour blocks: 23:00 last night is yesterday at
    /// 01:00 this morning, however few hours ago that was.
    @Test func the_boundary_is_midnight_and_not_a_stopwatch() {
        let oneAM = Self.utc.startOfDay(for: Self.noon).addingTimeInterval(3_600)
        let elevenPMYesterday = oneAM.addingTimeInterval(-2 * 3_600)
        #expect(HistoryClock.day(elevenPMYesterday, now: oneAM, calendar: Self.utc) == "Yesterday")
    }

    @Test func this_week_is_a_weekday_and_a_date() {
        // 9 Sep 2025 is a Tuesday; four days earlier is the Friday before.
        let friday = Self.noon.addingTimeInterval(-4 * 86_400)
        #expect(HistoryClock.day(friday, now: Self.noon, calendar: Self.utc) == "Fri 5 Sep")
    }

    @Test func this_year_drops_the_weekday_and_older_keeps_the_year() {
        let march = Self.noon.addingTimeInterval(-180 * 86_400)
        #expect(HistoryClock.day(march, now: Self.noon, calendar: Self.utc) == "13 Mar")
        let lastYear = Self.noon.addingTimeInterval(-400 * 86_400)
        #expect(HistoryClock.day(lastYear, now: Self.noon, calendar: Self.utc) == "5 Aug 2024")
    }

    /// A header is read at a glance beside a column of stamps, so it must not be
    /// wider than the stamps it sits over.
    @Test func no_day_name_outgrows_the_column() {
        for days in [0, 1, 3, 6, 40, 400] {
            let name = HistoryClock.day(
                Self.noon.addingTimeInterval(-Double(days) * 86_400),
                now: Self.noon, calendar: Self.utc)
            #expect(name.count <= 12, "\(name) is wider than the stamp column")
        }
    }
}

/// The window against a real ledger: the two questions the model cannot answer
/// on its own, because both of them are about what SQLite hands back.
@MainActor
struct HistoryWindowStoreTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-history3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    /// Page two is the rest of page one. The whole complaint was a list that
    /// stopped, so a paging bug here is the bug coming back wearing a hat.
    @Test("paging past the first screen reaches rows the palette never could")
    func paging() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        for i in 0..<150 {
            store.recordVisit(paneId: pane, url: "https://example.com/p\(i)", title: "Page \(i)")
        }

        let first = store.historyPage("", offset: 0, limit: 60)
        let second = store.historyPage("", offset: 60, limit: 60)
        let third = store.historyPage("", offset: 120, limit: 60)
        #expect(first.count == 60)
        #expect(second.count == 60)
        #expect(third.count == 30, "the tail of the list was unreachable")
        let seen = Set((first + second + third).map(\.url))
        #expect(seen.count == 150, "paging repeated or skipped rows")
    }

    /// Clearing a range takes those pages and leaves the rest — and the day
    /// count it is quoted with comes from the same ledger it deletes from.
    @Test("clearing a range forgets the pages it counted and no others")
    func clearing() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        for i in 0..<4 {
            store.recordVisit(paneId: pane, url: "https://example.com/\(i)", title: nil)
        }
        // Everything was recorded just now, so an hour ago catches all of it and
        // a moment in the future catches none — which is the arithmetic the
        // dialog's count depends on.
        let anHourAgo = Date().addingTimeInterval(-3600)
        #expect(store.historyDayCount(from: anHourAgo, to: Date().addingTimeInterval(60)) == 4)
        #expect(store.historyDayCount(
            from: Date().addingTimeInterval(60), to: Date().addingTimeInterval(3600)) == 0)

        #expect(store.clearHistory(since: Date().addingTimeInterval(60)) == 0,
                "a range with nothing in it deleted something")
        #expect(store.historyCount == 4)
        #expect(store.clearHistory(since: anHourAgo) == 4)
        #expect(store.historyCount == 0)
        // The index went with them, or a cleared page stays findable — which is
        // worse than not clearing at all.
        #expect(store.history("example").isEmpty)
    }
}

/// The picture. Everything above asserts arithmetic and wording; the one thing
/// nobody can assert is whether a 200-character address actually reads in the
/// column it was given. Gated on `MAXPANE_SHOTS`, so it costs nothing normally.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("history window rendering")
@MainActor
struct HistoryWindowRenderTests {
    @Test("renders the browse list and a search, with an address long enough to hurt")
    func renderSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StripStore(ledgerPath: tmp.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id

        // The two rows that made this a bug: same title, same truncation, and
        // the only difference is the last eight characters.
        let cloudwatch = "https://eu-west-1.console.aws.amazon.com/cloudwatch/home?region=eu-west-1#logsV2:log-groups/log-group/aws$252Flambda$252Fingest-worker/log-events/2025$252F09$252F09$252F$255B$2524LATEST$255D"
        for stream in ["stream-a", "stream-b"] {
            store.recordVisit(
                paneId: pane, url: cloudwatch + stream, title: "CloudWatch Management Console")
        }
        for (url, title) in [
            ("https://github.com/anthropics/claude-code/pull/1284/files", "Add a history view by ddrscott · Pull Request #1284"),
            ("https://doc.rust-lang.org/std/collections/struct.HashMap.html", "HashMap in std::collections - Rust"),
            ("https://news.ycombinator.com", "Hacker News"),
            ("https://untitled.example/no-title-here", nil),
        ] {
            store.recordVisit(paneId: pane, url: url, title: title)
        }

        for (name, query) in [("history-browse", ""), ("history-search", "cloudwatch")] {
            let window = HistoryWindow(store: store) { _ in }
            let view = try #require(window.window?.contentView)
            if !query.isEmpty {
                // The field is the input; going through it is what makes the
                // sheet show the state a reader would actually have produced.
                (view.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString != nil })?.stringValue = query
            }
            window.restart()
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
