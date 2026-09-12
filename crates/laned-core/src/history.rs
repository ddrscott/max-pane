//! Browsing history: what a web pane settled on, what it was called, and what
//! is allowed to stay.
//!
//! # Why the search is here and not in Swift
//!
//! The app already has two matchers: `Fuzzy` in `Views/PaletteFiltering.swift`,
//! and [`crate::search::fuzzy_score`] here. Both are good; the question is only
//! which corpus each is for.
//!
//! `Fuzzy` filters lists the app is *already holding* — ten Relay sessions, the
//! forty `Recent` rows the new-pane picker reads once when it opens. Nothing
//! crosses the FFI per keystroke because nothing has to.
//!
//! History is the first corpus that is not like that. It is thousands of rows
//! that live in SQLite and are never otherwise in memory, and filtering it in
//! Swift means marshalling all of them across uniffi on every character typed —
//! the cost `Ledger::update_pane_interaction_state` exists to avoid, paid per
//! keystroke instead of per layout change. So the query goes down and at most
//! `limit` rows come back.
//!
//! It reuses [`crate::search::fuzzy_score`] rather than growing a scorer of its
//! own, because ⌘P and this palette would otherwise disagree about which of two
//! URLs is the better match for the same typing, and there is no way for the
//! user to know which rules they are currently under. Swift still runs `Fuzzy`
//! over what comes back — on ≤50 rows, purely to find the offsets to paint
//! orange. Ranking in one place, highlighting where the pixels are.

use crate::model::{HistoryEntry, SearchField};
use crate::search::fuzzy_score;
use std::collections::HashMap;

/// Schemes that are a place you went.
///
/// `about:blank` is what every pane shows before it shows anything, and
/// `data:`/`blob:` are page-generated and unreachable later — recorded, they
/// fill the record with rows that cannot be reopened and cannot be recognised.
const RECORDABLE_SCHEMES: [&str; 3] = ["http", "https", "file"];

/// How long after a settle another settle of the same URL, in the same pane, is
/// still the same visit. See [`VisitMemo`].
pub const VISIT_COALESCE_MS: i64 = 2_000;

/// How many entries the ledger keeps.
///
/// History is layout memory, not an archive. The ledger is on the hot path of
/// every layout mutation, and an unbounded table in it grows forever for rows
/// nobody will ever type three letters of. 5 000 is roughly a year of the way
/// this app is used and still scans in well under a frame.
pub const HISTORY_MAX_ROWS: u32 = 5_000;

/// How old an entry may be. 90 days.
///
/// The row cap alone is not enough: a light month followed by a heavy one would
/// otherwise leave two-year-old rows sitting above this year's, because the cap
/// only fires when the table is full.
pub const HISTORY_MAX_AGE_MS: i64 = 90 * 24 * 60 * 60 * 1_000;

/// How many of the newest entries one query scores.
///
/// Below [`HISTORY_MAX_ROWS`] on purpose: a page you have not seen in two
/// thousand visits is not what a palette is for, and the cap is what keeps the
/// per-keystroke cost flat no matter how long the ledger has been running.
pub const HISTORY_SCAN_ROWS: u32 = 2_000;

/// One visit in every this many triggers a prune.
///
/// Not every visit: pruning is two `DELETE`s with a subquery, and paying that
/// on every settle would put a table scan in the middle of a navigation to save
/// bytes nobody is short of.
pub const HISTORY_PRUNE_EVERY: u32 = 64;

/// The canonical form of a URL, or `None` if it is not history.
///
/// Deliberately shallow. Only the parts that are *defined* to be
/// case-insensitive or redundant are touched — scheme, host, a default port, a
/// trailing empty fragment, the bare `/` after a host. Query strings and
/// fragments are left exactly as they came: half the web routes on `?id=` and a
/// great deal of it routes on `#/`, and a normalizer that "helpfully" drops
/// them merges pages the user experienced as different pages, which is a hole
/// in the record that looks like a feature.
pub fn normalize_url(raw: &str) -> Option<String> {
    let s = raw.trim();
    let sep = s.find("://")?;
    let scheme = s[..sep].to_ascii_lowercase();
    if !RECORDABLE_SCHEMES.contains(&scheme.as_str()) {
        return None;
    }
    let rest = &s[sep + 3..];
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let mut authority = rest[..end].to_ascii_lowercase();
    let mut tail = rest[end..].to_string();

    // `file://` has no authority by design; everything else without one is a
    // malformed URL that would collide with every other malformed URL.
    if authority.is_empty() && scheme != "file" {
        return None;
    }
    let default_port = match scheme.as_str() {
        "http" => ":80",
        "https" => ":443",
        _ => "",
    };
    if !default_port.is_empty() {
        if let Some(stripped) = authority.strip_suffix(default_port) {
            authority = stripped.to_string();
        }
    }
    // A click on `href="#"` leaves the address with a fragment that is not one.
    if tail.ends_with('#') {
        tail.pop();
    }
    // `https://example.com/` and `https://example.com` are the same page, and
    // WebKit reports whichever the server felt like.
    if tail == "/" {
        tail.clear();
    }
    Some(format!("{scheme}://{authority}{tail}"))
}

/// What each pane last settled on, so a burst of settles is one visit.
///
/// # Does every `didFinish` become a visit?
///
/// No, and the reason is not single-page apps. A pushState to a genuinely
/// different URL *is* a page the user went to and reads as one line in the
/// palette; because the ledger aggregates on URL, an app that pushes fifty
/// states is fifty rows only if the user actually saw fifty addresses, and a
/// tab you return to a hundred times is always exactly one row. That half takes
/// care of itself.
///
/// What does pollute is the *same* address settling several times in a second:
/// a redirect landing and then the destination finishing, a title arriving late
/// and the delegate firing again, a page that reloads itself once on load. Each
/// of those is one visit that the shell reports two or three times, and each
/// would inflate `visit_count` and re-stamp `seq` for something the user did
/// once. So a settle of the same URL in the same pane inside
/// [`VISIT_COALESCE_MS`] is dropped.
///
/// Per-pane, because two panes settling on the same URL at the same moment is
/// two visits; and in memory rather than in the ledger, because a burst cannot
/// straddle a launch — after a relaunch every pane is loading for the first
/// time, which is exactly what the memo would say anyway.
#[derive(Default)]
pub struct VisitMemo {
    last: HashMap<String, (String, i64)>,
}

impl VisitMemo {
    /// True when this settle should be recorded as a visit.
    ///
    /// Mutating on purpose: asking is the same act as noting, and a caller that
    /// could ask without noting would be able to double-record by asking twice.
    pub fn accept(&mut self, pane_id: &str, url: &str, at_ms: i64) -> bool {
        if let Some((last_url, at)) = self.last.get(pane_id) {
            if last_url == url && at_ms.saturating_sub(*at) < VISIT_COALESCE_MS {
                return false;
            }
        }
        self.last.insert(pane_id.to_string(), (url.to_string(), at_ms));
        true
    }

    /// A pane that no longer exists cannot be in the middle of a burst.
    pub fn forget(&mut self, pane_id: &str) {
        self.last.remove(pane_id);
    }
}

/// One candidate row, as the ledger hands it over before scoring.
pub struct Candidate {
    pub url: String,
    pub title: Option<String>,
    pub first_visit_at: i64,
    pub last_visit_at: i64,
    pub visit_count: u32,
    /// The addresses that redirected here. Searchable, never listed.
    pub aliases: Vec<String>,
}

/// Titles outrank URLs by the same margin they do in [`crate::search`]: what
/// the user remembers about a page is what it was called.
const TITLE_BIAS: i32 = 200;
/// An alias is a URL, so it scores as one — minus a hair, so that when the
/// address you typed and the address you landed on both match, the row is
/// explained by the one that is actually on screen.
const ALIAS_PENALTY: i32 = 5;

/// Score and rank. `query` empty means "most recent first", which is what the
/// palette shows before anything is typed.
///
/// `candidates` must already be in newest-first order: that order is the
/// answer for an empty query, and the tie-break for everything else.
///
/// Recency is a tie-break and not a term in the score, deliberately. A frecency
/// blend — the thing every browser's omnibox does — makes "why is this first"
/// unanswerable, and `Recent`'s doc comment already made this call once for the
/// new-pane picker. Two rows that match your typing equally well are separated
/// by which you saw last; a row that matches it better wins outright.
pub fn rank(candidates: &[Candidate], query: &str, limit: usize) -> Vec<HistoryEntry> {
    let needle = query.trim().to_lowercase();

    // Paired with its place in the recency order, which is the tie-break and
    // nothing the shell needs — so it is a local, not a field on the record
    // that crosses the FFI.
    let mut out: Vec<(HistoryEntry, usize)> = Vec::new();
    for (recency, c) in candidates.iter().enumerate() {
        let (score, field) = if needle.is_empty() {
            (0, SearchField::Url)
        } else {
            let mut best: Option<(i32, SearchField)> = None;
            let mut offer = |s: i32, f: SearchField| {
                if best.map_or(true, |(b, _)| s > b) {
                    best = Some((s, f));
                }
            };
            if let Some(t) = &c.title {
                if let Some(s) = fuzzy_score(&needle, &t.to_lowercase()) {
                    offer(s + TITLE_BIAS, SearchField::Title);
                }
            }
            if let Some(s) = fuzzy_score(&needle, &c.url.to_lowercase()) {
                offer(s, SearchField::Url);
            }
            for alias in &c.aliases {
                if let Some(s) = fuzzy_score(&needle, &alias.to_lowercase()) {
                    // Folded into `Url` rather than given a `SearchField` case
                    // of its own: the enum crosses the FFI into exhaustive
                    // Swift switches that other palettes own, and a redirect
                    // source is a URL in every sense the reader cares about.
                    offer(s - ALIAS_PENALTY, SearchField::Url);
                }
            }
            match best {
                Some(b) => b,
                None => continue,
            }
        };
        out.push((
            HistoryEntry {
                url: c.url.clone(),
                title: c.title.clone(),
                first_visit_at: c.first_visit_at,
                last_visit_at: c.last_visit_at,
                visit_count: c.visit_count,
                matched_field: field,
                score,
            },
            recency,
        ));
    }
    out.sort_by(|a, b| b.0.score.cmp(&a.0.score).then_with(|| a.1.cmp(&b.1)));
    out.truncate(limit);
    out.into_iter().map(|(entry, _)| entry).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(url: &str, title: Option<&str>) -> Candidate {
        Candidate {
            url: url.to_string(),
            title: title.map(str::to_string),
            first_visit_at: 0,
            last_visit_at: 0,
            visit_count: 1,
            aliases: Vec::new(),
        }
    }

    #[test]
    fn scheme_and_host_are_case_folded_but_the_path_is_not() {
        assert_eq!(
            normalize_url("HTTPS://Example.COM/Docs/Index").unwrap(),
            "https://example.com/Docs/Index"
        );
    }

    #[test]
    fn default_ports_and_the_bare_slash_collapse() {
        assert_eq!(normalize_url("https://example.com:443/").unwrap(), "https://example.com");
        assert_eq!(normalize_url("http://example.com:80").unwrap(), "http://example.com");
        assert_eq!(normalize_url("http://example.com/").unwrap(), "http://example.com");
    }

    #[test]
    fn a_nonstandard_port_is_part_of_the_address() {
        // `localhost:3000` and `localhost:3001` are two different dev servers.
        assert_eq!(normalize_url("http://localhost:3000/").unwrap(), "http://localhost:3000");
    }

    #[test]
    fn query_and_fragment_survive() {
        // Both route real pages. Dropping them merges things the user saw as
        // separate pages.
        assert_eq!(
            normalize_url("https://mail.example.com/#/inbox/42").unwrap(),
            "https://mail.example.com/#/inbox/42"
        );
        assert_eq!(
            normalize_url("https://example.com/s?q=rust").unwrap(),
            "https://example.com/s?q=rust"
        );
    }

    #[test]
    fn an_empty_fragment_is_not_a_fragment() {
        assert_eq!(normalize_url("https://example.com/a#").unwrap(), "https://example.com/a");
    }

    #[test]
    fn non_pages_are_not_history() {
        for raw in ["about:blank", "data:text/html,<p>hi", "blob:https://x/1", "", "example.com"] {
            assert!(normalize_url(raw).is_none(), "{raw} was recorded as a page");
        }
    }

    #[test]
    fn a_burst_of_settles_is_one_visit() {
        let mut memo = VisitMemo::default();
        assert!(memo.accept("p1", "https://example.com", 1_000));
        assert!(!memo.accept("p1", "https://example.com", 1_100));
        assert!(!memo.accept("p1", "https://example.com", 2_900));
        // Past the window it is the user opening the page again.
        assert!(memo.accept("p1", "https://example.com", 3_001));
    }

    #[test]
    fn two_panes_on_the_same_page_are_two_visits() {
        let mut memo = VisitMemo::default();
        assert!(memo.accept("p1", "https://example.com", 1_000));
        assert!(memo.accept("p2", "https://example.com", 1_000));
    }

    #[test]
    fn navigating_away_and_back_inside_the_window_still_counts() {
        // The window suppresses a repeat, not a round trip: the user really did
        // go somewhere and come back.
        let mut memo = VisitMemo::default();
        assert!(memo.accept("p1", "https://a.example", 0));
        assert!(memo.accept("p1", "https://b.example", 100));
        assert!(memo.accept("p1", "https://a.example", 200));
    }

    #[test]
    fn an_empty_query_is_recency_order() {
        let c = vec![candidate("https://c.example", None), candidate("https://a.example", None)];
        let hits = rank(&c, "  ", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].url, "https://c.example", "newest first, not alphabetical");
    }

    #[test]
    fn a_title_match_outranks_a_url_match() {
        let c = vec![
            candidate("https://rust-lang.example/x", None),
            candidate("https://b.example/q", Some("The Rust Programming Language")),
        ];
        let hits = rank(&c, "rust", 10);
        assert_eq!(hits[0].url, "https://b.example/q");
        assert_eq!(hits[0].matched_field, SearchField::Title);
    }

    #[test]
    fn a_better_match_beats_a_newer_one() {
        // Recency is the tie-break, not a thumb on the scale.
        let c = vec![
            candidate("https://n.example/zebra-quilt", None),
            candidate("https://docs.example/rust", None),
        ];
        let hits = rank(&c, "rust", 10);
        assert_eq!(hits[0].url, "https://docs.example/rust");
    }

    #[test]
    fn the_address_you_typed_finds_the_page_you_landed_on() {
        let mut c = candidate("https://www.example.com/en", Some("Example"));
        c.aliases = vec!["https://example.com".to_string()];
        let hits = rank(&[c], "example.com", 10);
        assert_eq!(hits.len(), 1, "the redirect source found nothing");
        assert_eq!(hits[0].url, "https://www.example.com/en", "the entry is where you ended up");
    }

    #[test]
    fn nothing_matching_returns_nothing() {
        assert!(rank(&[candidate("https://example.com", None)], "zzqq", 10).is_empty());
    }
}
