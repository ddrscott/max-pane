import Foundation
import Testing
import WebKit

@testable import MaxPaneKit

/// History, round 2: the chain a redirect leaves and the clock it happened on.
///
/// Both pieces are deliberately free of WebKit state — `RedirectTrail` takes
/// the events as arguments and `HistoryClock` takes the calendar — because the
/// failures being fixed are about *sequences* of events two seconds apart, and
/// a test that has to drive a real web view to reach one is a test nobody runs.
@MainActor
struct RedirectTrailTests {
    /// Every hop, not just the first. `backForwardList.currentItem?.initialURL`
    /// holds one address, so a two-hop chain used to lose its middle.
    @Test func a_server_chain_keeps_its_middle() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://a.example", type: .other, now: 0)
        trail.serverRedirect(to: "https://b.example")
        trail.serverRedirect(to: "https://c.example")
        #expect(trail.didFinish(at: "https://c.example", now: 0.4)
            == ["https://a.example", "https://b.example"])
    }

    /// The measured failure: `location.replace` and `<meta refresh>` each left
    /// a row of their own — untitled, unreopenable — and no alias.
    @Test func a_client_redirect_is_a_hop_and_not_a_page() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://bounce.example/js", type: .other, now: 0)
        #expect(trail.didFinish(at: "https://bounce.example/js", now: 0.2).isEmpty)
        // The page redirects itself a beat later. Nobody asked for this one.
        trail.willNavigate(to: "https://real.example/page", type: .other, now: 0.5)
        #expect(trail.didFinish(at: "https://real.example/page", now: 0.9)
            == ["https://bounce.example/js"])
    }

    /// A shortener that bounces to a consent page that bounces to the article:
    /// one entry, and all three addresses still findable.
    @Test func a_chain_of_bounces_collapses_to_one_entry() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://youtu.be/dQw4w9WgXcQ", type: .other, now: 0)
        trail.serverRedirect(to: "https://consent.example/ask")
        _ = trail.didFinish(at: "https://consent.example/ask", now: 0.3)
        trail.willNavigate(to: "https://youtube.com/watch?v=dQw4w9WgXcQ", type: .other, now: 0.6)
        #expect(trail.didFinish(at: "https://youtube.com/watch?v=dQw4w9WgXcQ", now: 1.0)
            == ["https://youtu.be/dQw4w9WgXcQ", "https://consent.example/ask"])
    }

    /// An address typed into the chrome bar is `.other` too, and is the exact
    /// opposite of a redirect. The pane saying so is what tells them apart —
    /// WebKit has no public "was there a gesture".
    @Test func a_page_the_pane_asked_for_is_not_a_redirect_from_the_last_one() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://first.example", type: .other, now: 0)
        _ = trail.didFinish(at: "https://first.example", now: 0.2)
        trail.paneWillLoad()
        trail.willNavigate(to: "https://typed.example", type: .other, now: 0.4)
        #expect(trail.didFinish(at: "https://typed.example", now: 0.6).isEmpty)
    }

    @Test func a_link_a_form_and_a_reload_are_not_redirects() {
        for type in [WKNavigationType.linkActivated, .formSubmitted, .backForward, .reload] {
            var trail = RedirectTrail()
            trail.paneWillLoad()
            trail.willNavigate(to: "https://first.example", type: .other, now: 0)
            _ = trail.didFinish(at: "https://first.example", now: 0.2)
            trail.willNavigate(to: "https://next.example", type: type, now: 0.3)
            #expect(
                trail.didFinish(at: "https://next.example", now: 0.5).isEmpty,
                "navigation type \(type.rawValue) was read as a redirect")
        }
    }

    /// Reading a page for a minute and then clicking nothing is not the page
    /// redirecting; something opened it from outside. Past the window it is a
    /// page of its own.
    @Test func a_navigation_long_after_the_page_settled_stands_alone() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://first.example", type: .other, now: 0)
        _ = trail.didFinish(at: "https://first.example", now: 0.2)
        trail.willNavigate(
            to: "https://later.example", type: .other,
            now: 0.2 + RedirectTrail.clientRedirectWindow + 0.1)
        #expect(trail.didFinish(at: "https://later.example", now: 60).isEmpty)
    }

    /// A load that failed never settled, so nothing after it can be a bounce
    /// off it — and the half-built chain does not leak into the next page.
    @Test func a_failed_load_leaves_no_trail() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://broken.example", type: .other, now: 0)
        trail.serverRedirect(to: "https://broken.example/2")
        trail.didFail()
        trail.willNavigate(to: "https://next.example", type: .other, now: 0.1)
        #expect(trail.didFinish(at: "https://next.example", now: 0.3).isEmpty)
    }

    /// The destination never describes itself as a hop to itself.
    @Test func the_page_you_landed_on_is_not_its_own_alias() {
        var trail = RedirectTrail()
        trail.paneWillLoad()
        trail.willNavigate(to: "https://same.example", type: .other, now: 0)
        trail.serverRedirect(to: "https://same.example")
        #expect(trail.didFinish(at: "https://same.example", now: 0.2).isEmpty)
    }
}

@MainActor
struct HistoryClockTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
        return calendar.date(from: c)!
    }

    /// Saturday 12 September 2026, 18:00 — the day this was written.
    private var now: Date { date(2026, 9, 12, 18, 0) }

    @Test func today_is_a_clock_time() {
        #expect(HistoryClock.stamp(date(2026, 9, 12, 14, 32), now: now, calendar: calendar)
            == "14:32")
    }

    /// "What did I have open Tuesday afternoon" is the question the old
    /// "22d ago" could not answer, and the weekday is how anyone asks it.
    @Test func this_week_is_a_weekday_and_a_clock_time() {
        #expect(HistoryClock.stamp(date(2026, 9, 8, 9, 15), now: now, calendar: calendar)
            == "Tue 09:15")
        // Yesterday is a weekday too: "Fri 23:50" is more use than "18h ago".
        #expect(HistoryClock.stamp(date(2026, 9, 11, 23, 50), now: now, calendar: calendar)
            == "Fri 23:50")
    }

    /// By day, not by 24-hour blocks — twenty-six hours ago is yesterday.
    @Test func the_week_is_counted_in_days_not_in_hours() {
        #expect(HistoryClock.stamp(date(2026, 9, 11, 16, 0), now: now, calendar: calendar)
            == "Fri 16:00")
        // Seven days back is far enough that the weekday has stopped being
        // unambiguous — last Saturday and this one are both "Sat".
        #expect(HistoryClock.stamp(date(2026, 9, 5, 16, 0), now: now, calendar: calendar)
            == "5 Sep 16:00")
    }

    @Test func this_year_is_a_date_and_a_clock_time() {
        #expect(HistoryClock.stamp(date(2026, 2, 22, 7, 5), now: now, calendar: calendar)
            == "22 Feb 07:05")
    }

    /// The owner's record goes back to 2024-02-22. At that distance the time of
    /// day has stopped meaning anything and the year has started to.
    @Test func older_than_this_year_drops_the_clock_and_names_the_year() {
        #expect(HistoryClock.stamp(date(2024, 2, 22, 7, 5), now: now, calendar: calendar)
            == "22 Feb 2024")
    }

    @Test func a_clock_that_moved_backwards_says_nothing_rather_than_the_future() {
        #expect(HistoryClock.stamp(date(2027, 1, 1, 0, 0), now: now, calendar: calendar) == "—")
    }

    /// The column is 84 pt of JetBrains Mono at 11 pt, which is 12 characters.
    @Test func no_stamp_outgrows_its_column() {
        let samples = [
            date(2026, 9, 12, 14, 32), date(2026, 9, 8, 9, 15),
            date(2026, 12, 31, 23, 59), date(2024, 2, 22, 7, 5),
        ]
        for when in samples {
            #expect(HistoryClock.stamp(when, now: now, calendar: calendar).count <= 12)
        }
    }
}
