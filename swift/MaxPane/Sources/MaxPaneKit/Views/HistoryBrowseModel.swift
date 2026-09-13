import Foundation
import LanedCore

/// The History window's state, and every sentence it says before it deletes
/// something. No AppKit in it.
///
/// # Why there is a window at all
///
/// Round 2 left four complaints that were all the same complaint. You could
/// browse exactly 60 rows; a truncated URL ate the `stream-a`/`stream-b` that
/// was the only difference between two CloudWatch rows; ⌘⌫ deleted one of them
/// instantly with no confirmation and no way to tell which; and there was no
/// way to clear anything. Every one of them is a request for room, and none of
/// them can be answered inside a palette row 26 points tall that sits over the
/// strip and dies when you look away.
///
/// So the palette keeps the job it is good at — type three characters, hit
/// Return, the page opens — and the window takes the jobs that need space:
/// reading a whole address, knowing what day you are looking at, going past the
/// first screen, and destroying things on purpose.
///
/// Separated from the window the way `ImportWizardModel` and `SidebarModel` are,
/// and for the same reason: what has to be right here is the *wording* and the
/// *arithmetic* — which day a row belongs to, how many pages a header claims,
/// what the dialog says is about to be deleted. All of that is assertable in a
/// test and none of it is assertable through a window.
struct HistoryBrowseModel {
    /// How many rows one page asks for.
    ///
    /// 120 rather than the palette's 60: a window this size shows about 20 rows,
    /// so a page is six screens of scrolling and the reader reaches the end of
    /// one while the next is already there. Larger costs nothing measurable —
    /// the rows are point lookups on the primary key — but it does cost the
    /// moment where the list stops, which is the thing being fixed.
    static let pageSize: UInt32 = 120

    /// What the table draws, in order.
    enum Row: Equatable {
        case day(Day)
        case page(HistoryEntry)
    }

    /// A day header. Not a decoration: the count is what makes paging honest.
    struct Day: Equatable {
        let start: Date
        /// "Today", "Tue 9 Sep" — see `HistoryClock.day`.
        let title: String
        /// Pages recorded on this day **in the whole record**, not the number of
        /// them that happen to be loaded.
        ///
        /// This distinction is the entire reason the count is asked of the
        /// ledger rather than counted off the rows above it. A header reading
        /// "41 pages" over the 12 rows a page happened to include is the same
        /// lie as round 1's `0 OF 5013 PAGES` — a label that is wrong about the
        /// thing it labels — and this codebase has now been bitten by it twice.
        let count: UInt32
    }

    /// The rows the window has asked for so far, in the order they came back.
    private(set) var entries: [HistoryEntry] = []

    /// True once a page came back shorter than it was asked for: the end of the
    /// list, said by the list rather than guessed from a total.
    private(set) var exhausted = false

    /// What is typed. Empty means browse; anything else means search, and the
    /// two are different shapes — see `rows(now:calendar:pagesOn:)`.
    private(set) var query: String = ""

    var isEmpty: Bool { entries.isEmpty }

    /// How many rows have been read so far — the footer's second number, and
    /// the honest half of "240 of 112,840".
    var loadedCount: Int { entries.count }

    /// Where the next page starts. Deliberately derived from what is held
    /// rather than kept as its own counter, so a delete cannot leave the two
    /// disagreeing and skip a row.
    var nextOffset: UInt32 { UInt32(entries.count) }

    /// Throw away the list and start a new one. Every keystroke in the search
    /// field does this: a query is a different list, not a filter over this one.
    mutating func restart(query: String) {
        self.query = query
        entries = []
        exhausted = false
    }

    /// Take a page that was asked for with `limit`.
    mutating func append(_ page: [HistoryEntry], limit: UInt32) {
        entries.append(contentsOf: page)
        if page.count < Int(limit) { exhausted = true }
    }

    /// Drop a row the user forgot, without re-reading the list.
    ///
    /// Re-reading would be simpler and is wrong: the reader is 400 rows down a
    /// list they scrolled by hand, and a reload puts them back at the top as the
    /// reward for deleting one thing.
    mutating func forget(url: String) {
        entries.removeAll { $0.url == url }
    }

    /// What the table draws.
    ///
    /// Day headers appear only while nothing is typed. A query is answered in
    /// score order by the same ranking the palette uses — so ⌘Y and this window
    /// never disagree about which of two pages matches better — and relevance
    /// order scatters the days, so grouping it would put a header over rows that
    /// are not all from that day. Each row still carries its own stamp, so a
    /// search result is never undated; it is simply not filed.
    ///
    /// `pagesOn` is passed in rather than read from a store because the count on
    /// a header is a ledger query and this type is the part with no I/O in it.
    func rows(
        now: Date = Date(),
        calendar: Calendar = .current,
        pagesOn: (_ start: Date, _ end: Date) -> UInt32
    ) -> [Row] {
        guard query.isEmpty else { return entries.map { .page($0) } }
        var out: [Row] = []
        var open: Date?
        for entry in entries {
            let when = Date(timeIntervalSince1970: Double(entry.lastVisitAt) / 1000)
            let start = calendar.startOfDay(for: when)
            if open != start {
                open = start
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                out.append(.day(Day(
                    start: start,
                    title: HistoryClock.day(when, now: now, calendar: calendar),
                    count: pagesOn(start, end))))
            }
            out.append(.page(entry))
        }
        return out
    }

    // MARK: - the two destructive sentences

    /// The confirmation for ⌘⌫, which used to be no confirmation at all.
    ///
    /// The measured failure was not that a page was deleted — it is the user's
    /// history and deleting from it is the point. It was that two CloudWatch
    /// rows truncated to the same `…log-group/aws$252Flam…` and one of them
    /// vanished with no way to tell which. So the dialog's whole job is to print
    /// the part the list could not: the **full** address, unabbreviated, on its
    /// own.
    static func forgetPrompt(_ entry: HistoryEntry) -> (message: String, detail: String) {
        forgetPrompt(
            url: entry.url,
            title: entry.title,
            visits: entry.visitCount,
            lastVisit: Date(timeIntervalSince1970: Double(entry.lastVisitAt) / 1000))
    }

    /// The same sentence from the palette, which is where the failure was
    /// actually measured and which holds candidates rather than ledger rows.
    /// One wording, so the two surfaces cannot drift into asking the question
    /// two different ways about the same act.
    static func forgetPrompt(
        url: String, title: String?, visits: UInt32, lastVisit: Date?
    ) -> (message: String, detail: String) {
        let name = title.flatMap { $0.isEmpty || $0 == url ? nil : $0 } ?? "this page"
        var tail = visits <= 1 ? "" : "\(visits) visits"
        if let lastVisit {
            let stamp = "last opened \(HistoryClock.stamp(lastVisit))"
            tail = tail.isEmpty ? stamp.prefix(1).uppercased() + stamp.dropFirst()
                : "\(tail), \(stamp)"
        }
        return (
            message: name == "this page" ? "Forget this page?" : "Forget “\(name)”?",
            detail: tail.isEmpty
                ? "\(url)\n\nThis cannot be undone."
                : "\(url)\n\n\(tail). This cannot be undone."
        )
    }

    /// The confirmation for Clear, which quotes a number it got from the ledger
    /// before anything is deleted.
    ///
    /// "Pages", never "visits". One row is one URL however many times it was
    /// opened, so a page first seen last year and reopened ten minutes ago is
    /// inside "the last hour" and goes with it — and a dialog that said "3
    /// visits" would be describing a record this app does not keep.
    static func clearPrompt(_ range: HistoryClearRange, pages: UInt32)
        -> (message: String, detail: String)
    {
        let count = pages == 1 ? "1 page" : "\(pages) pages"
        return (
            message: range == .everything
                ? "Forget all \(count)?"
                : "Forget \(count) from \(range.phrase)?",
            detail: """
            A page counts as recent if you last opened it in that window, however \
            long ago you first found it. Redirects that pointed at these pages go \
            with them. This cannot be undone.
            """
        )
    }
}

/// How much of it to forget.
///
/// Chrome's list, minus the ones that are the same question twice. The ranges
/// are named here rather than in the core because which spans a person thinks in
/// is a decision about people, and the core is handed an instant.
enum HistoryClearRange: CaseIterable {
    case lastHour
    case today
    case lastWeek
    case everything

    var title: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .today: return "Today"
        case .lastWeek: return "Last 7 Days"
        case .everything: return "Everything"
        }
    }

    /// How the confirmation refers to it mid-sentence.
    var phrase: String {
        switch self {
        case .lastHour: return "the last hour"
        case .today: return "today"
        case .lastWeek: return "the last 7 days"
        case .everything: return "the whole record"
        }
    }

    /// The instant the core is given: forget everything last visited at or
    /// after this. `.everything` is the epoch, which is the same statement
    /// rather than a second code path.
    ///
    /// `.today` is midnight *here* — `startOfDay`, not "now minus 24 hours".
    /// Someone clearing "today" at 00:30 means the half hour they have been
    /// awake for, not yesterday evening, and the two answers differ by a whole
    /// day's browsing at exactly the hour someone is most likely to be asking.
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(-7 * 86_400)
        case .everything: return Date(timeIntervalSince1970: 0)
        }
    }
}
