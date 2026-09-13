import Foundation

/// When a page was last open, said in a way you can answer a question with.
///
/// # Why history does not get "22d ago"
///
/// `SessionTelemetry.age` is right for a session: a terminal's last output was
/// "6s ago" and the number changes while you watch it, so a clock time would be
/// a worse answer to a question about *now*. History is the opposite kind of
/// record. Every row read "22d ago" — no dates, no clock time, nothing to group
/// by — and "what did I have open on Tuesday afternoon" was unanswerable, while
/// Vivaldi answers it with a date column and day headers.
///
/// So the stamp says as much as it has to and no more, which in a mono column
/// eleven points wide is the whole design:
///
/// ```text
/// 14:32          today — the day is the one thing you already know
/// Tue 09:15      this week — the weekday is how anyone refers to it
/// 12 Sep 14:32   this year
/// 12 Sep 2025    older — the time of day stopped meaning anything
/// ```
///
/// The calendar is passed in, not read from the environment, because a test
/// that has to be run in September to pass is a test that fails in October.
enum HistoryClock {
    static func stamp(_ when: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        // A page recorded "in the future" is a clock that moved, not a page
        // from the future. Saying so beats a negative interval rendered as a
        // date nobody has reached.
        if when > now.addingTimeInterval(60) {
            return "—"
        }
        let clock = parts(when, calendar)
        if calendar.isDate(when, inSameDayAs: now) {
            return clock.time
        }
        // Seven days, by day rather than by 24-hour blocks: "Tue" has to mean
        // the Tuesday just gone, and a page from 26 hours ago is yesterday
        // whatever o'clock it was.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: when),
            to: calendar.startOfDay(for: now)).day ?? 0
        if days >= 1, days < 7 {
            return "\(clock.weekday) \(clock.time)"
        }
        if calendar.component(.year, from: when) == calendar.component(.year, from: now) {
            return "\(clock.day) \(clock.month) \(clock.time)"
        }
        return "\(clock.day) \(clock.month) \(clock.year)"
    }

    /// 24-hour and English month abbreviations, deliberately: the column is
    /// JetBrains Mono and a 12-hour clock costs two characters and an am/pm
    /// that reads as noise beside a URL. Fixed rather than localised because
    /// every other string on this row — `PAGES`, `⇥ scope` — is.
    /// A full date, always — `22 Feb 2024`.
    ///
    /// [`stamp`] deliberately drops whatever the reader already knows, which is
    /// right in a column of rows that are mostly from today and wrong for the
    /// two ends of a range. "This import covers 09:27 to 14:32" is not a
    /// sentence about two and a half years.
    static func date(_ when: Date, calendar: Calendar = .current) -> String {
        let p = parts(when, calendar)
        return "\(p.day) \(p.month) \(p.year)"
    }

    private static func parts(
        _ when: Date, _ calendar: Calendar
    ) -> (time: String, weekday: String, day: String, month: String, year: String) {
        let c = calendar.dateComponents([.hour, .minute, .weekday, .day, .month, .year], from: when)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return (
            time: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
            weekday: weekdays[((c.weekday ?? 1) - 1) % 7],
            day: String(c.day ?? 1),
            month: months[((c.month ?? 1) - 1) % 12],
            year: String(c.year ?? 0)
        )
    }
}
