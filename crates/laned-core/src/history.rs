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

/// How much of a row the query explains.
///
/// # Why a tier and not just a score
///
/// [`fuzzy_score`] is a subsequence scorer, and a subsequence scorer over
/// thousands of rows is a machine for surfacing coincidences. Measured against
/// the owner's real corpus: `hop` returned sixty "matches" led by *Checker
/// notes* and *Launchd notes* — h, o and p scattered across a sentence — while
/// the page whose URL literally contains `hop` did not make the visible list at
/// all. `TITLE_BIAS` made it worse rather than better: a flat bonus on a
/// subsequence score means *any* title coincidence outranks *any* real URL
/// match.
///
/// The bar is Vivaldi, whose history search is a substring search: type `hop`,
/// get rows containing `hop`. So the tier is decided first and the score only
/// orders rows inside it. `TITLE_BIAS` keeps its job — which of two equally
/// literal matches to lead with — and loses the one it should never have had.
///
/// Subsequence survives as the last tier rather than being deleted: it is what
/// makes `mxp` find `max-pane`, and over ten sessions (where `Fuzzy` lives) it
/// is exactly right. It is only wrong when it is allowed to outrank a literal
/// hit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchTier {
    /// The field starts with what was typed.
    Prefix,
    /// A word inside it starts with what was typed.
    WordPrefix,
    /// It contains what was typed, mid-word.
    Substring,
    /// The letters are in there, in order, apart.
    Scattered,
}

impl MatchTier {
    /// Far enough apart that nothing inside a tier can climb out of it:
    /// [`fuzzy_score`] tops out in the low thousands for a query long enough to
    /// type, and `TITLE_BIAS` is 200.
    fn base(self) -> i32 {
        match self {
            MatchTier::Prefix => 30_000,
            MatchTier::WordPrefix => 20_000,
            MatchTier::Substring => 10_000,
            MatchTier::Scattered => 0,
        }
    }
}

/// Characters after which the next one reads as the start of a word. The same
/// set [`fuzzy_score`] uses, plus the punctuation that separates the parts of a
/// URL — `?`, `&`, `=` and `#` are word boundaries in an address and nowhere
/// else, and an address is half of what this corpus is.
fn is_boundary(c: char) -> bool {
    matches!(c, ' ' | '/' | '-' | '_' | '.' | ':' | '~' | '@' | '?' | '&' | '=' | '#')
}

/// The best tier `needle` reaches in `hay`. Both must already be lowercase.
///
/// Every occurrence is considered, not just the first: `oo` in `google` is
/// mid-word at offset 1 and nothing else, but `com` in `example.com/compare` is
/// a word start on its second occurrence and mid-word on its first, and taking
/// the first would rank it as the worse of the two matches it actually has.
pub fn tier(needle: &str, hay: &str) -> Option<MatchTier> {
    if needle.is_empty() {
        return Some(MatchTier::Prefix);
    }
    let mut best: Option<MatchTier> = None;
    for (at, _) in hay.match_indices(needle) {
        let here = if at == 0 {
            MatchTier::Prefix
        } else if hay[..at].chars().next_back().is_some_and(is_boundary) {
            MatchTier::WordPrefix
        } else {
            MatchTier::Substring
        };
        if best.map_or(true, |b| here < b) {
            best = Some(here);
        }
        if best == Some(MatchTier::Prefix) {
            break;
        }
    }
    best.or_else(|| fuzzy_score(needle, hay).map(|_| MatchTier::Scattered))
}

/// A URL with the parts nobody types stripped off, for matching only.
///
/// `http` as a query used to be a prefix of every row in the table, which is
/// how `http://git` came back with *SQLite — Wikipedia*. The scheme and `www.`
/// are noise the user is not distinguishing pages by, so neither side of the
/// comparison carries them.
pub fn search_handle(url: &str) -> &str {
    let rest = url.find("://").map_or(url, |i| &url[i + 3..]);
    rest.strip_prefix("www.").unwrap_or(rest)
}

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
    let raw = query.trim().to_lowercase();
    // The query is stripped the same way the URLs are, so that pasting an
    // address back in finds the page it came from rather than nothing.
    let needle = search_handle(&raw);

    // Paired with its place in the recency order, which is the tie-break and
    // nothing the shell needs — so it is a local, not a field on the record
    // that crosses the FFI.
    let mut out: Vec<(HistoryEntry, usize, MatchTier)> = Vec::new();
    for (recency, c) in candidates.iter().enumerate() {
        let (score, field, matched) = if needle.is_empty() {
            (0, SearchField::Url, MatchTier::Prefix)
        } else {
            let mut best: Option<(i32, SearchField, MatchTier)> = None;
            let mut offer = |tier: MatchTier, s: i32, f: SearchField| {
                let total = tier.base() + s;
                if best.map_or(true, |(b, _, _)| total > b) {
                    best = Some((total, f, tier));
                }
            };
            if let Some(t) = &c.title {
                let lower = t.to_lowercase();
                if let Some(tier) = tier(needle, &lower) {
                    let s = fuzzy_score(needle, &lower).unwrap_or(0);
                    offer(tier, s + TITLE_BIAS, SearchField::Title);
                }
            }
            let url = c.url.to_lowercase();
            let handle = search_handle(&url);
            if let Some(tier) = tier(needle, handle) {
                offer(tier, fuzzy_score(needle, handle).unwrap_or(0), SearchField::Url);
            }
            for alias in &c.aliases {
                let lower = alias.to_lowercase();
                let handle = search_handle(&lower);
                if let Some(t) = tier(needle, handle) {
                    // Folded into `Url` rather than given a `SearchField` case
                    // of its own: the enum crosses the FFI into exhaustive
                    // Swift switches that other palettes own, and a redirect
                    // source is a URL in every sense the reader cares about.
                    let s = fuzzy_score(needle, handle).unwrap_or(0);
                    offer(t, s - ALIAS_PENALTY, SearchField::Url);
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
            matched,
        ));
    }
    // A guess is only worth showing when there is nothing better.
    //
    // `git` is a subsequence of *SQLite — Wikipedia* (the g of `org`, the i of
    // `wiki`, the t of `sqlite`) and always will be; over two thousand rows
    // there are dozens like it, and they are what made the old list read as
    // noise even once the real hit was on top. So the two kinds of match never
    // share a list: if anything matched literally, the coincidences go. If
    // nothing did, they are all there is — which is what keeps `mxp` finding
    // `max-pane`.
    if out.iter().any(|(_, _, t)| *t < MatchTier::Scattered) {
        out.retain(|(_, _, t)| *t < MatchTier::Scattered);
    }
    out.sort_by(|a, b| b.0.score.cmp(&a.0.score).then_with(|| a.1.cmp(&b.1)));
    out.truncate(limit);
    out.into_iter().map(|(entry, _, _)| entry).collect()
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
    fn a_title_match_outranks_a_url_match_of_the_same_kind() {
        // `TITLE_BIAS` decides between two matches that are equally literal —
        // both of these are a word start — and no longer reaches across tiers.
        // It used to: a flat bonus on a subsequence score meant a title
        // coincidence beat a real URL hit, which is the failure
        // `a_literal_hit_outranks_a_title_coincidence` pins.
        let c = vec![
            candidate("https://x.example/docs/rust", None),
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

    // ---- tiers: a literal hit always beats a scattered one -------------------

    #[test]
    fn a_literal_hit_outranks_a_title_coincidence() {
        // The measured failure: `hop` led with titles whose h, o and p are
        // three unrelated letters, and the page whose URL says `hop` was not
        // on screen at all.
        let hits = rank(
            &[
                candidate("https://developer.mozilla.org/x", Some("Checker notes 4805")),
                candidate("https://launchd.info/y", Some("Launchd notes 4520")),
                candidate("https://shop.example.com/hoppers", None),
            ],
            "hop",
            10,
        );
        assert_eq!(hits[0].url, "https://shop.example.com/hoppers");
    }

    #[test]
    fn a_scheme_is_not_a_prefix_of_the_whole_table() {
        // `http://git` used to return SQLite — Wikipedia, because every URL is
        // a subsequence match for a scheme plus three letters.
        let hits = rank(
            &[
                candidate("https://en.wikipedia.org/wiki/SQLite", Some("SQLite - Wikipedia")),
                candidate("https://github.com/anthropics", Some("GitHub")),
            ],
            "http://git",
            10,
        );
        assert_eq!(hits.len(), 1, "the scheme matched rows it has nothing to do with");
        assert_eq!(hits[0].url, "https://github.com/anthropics");
    }

    #[test]
    fn a_word_start_beats_the_middle_of_a_word() {
        let hits = rank(
            &[
                candidate("https://example.com/deployment-notes", None),
                candidate("https://example.com/deploy", None),
            ],
            "deploy",
            10,
        );
        // Both contain it; both are word starts, so the tie-break is recency —
        // and the ordering that matters here is that neither lost to a
        // scattered match, tested above. What this pins is the tier itself.
        assert_eq!(tier("ploy", "deployment"), Some(MatchTier::Substring));
        assert_eq!(tier("deploy", "deployment"), Some(MatchTier::Prefix));
        assert_eq!(tier("notes", "deployment-notes"), Some(MatchTier::WordPrefix));
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn the_best_occurrence_decides_the_tier() {
        // `com` is mid-word in `example.com` and a word start in `/compare`.
        assert_eq!(tier("com", "example.com/compare"), Some(MatchTier::WordPrefix));
    }

    #[test]
    fn a_subsequence_still_matches_when_nothing_literal_does() {
        // `mxp` finding `max-pane` is the reason the last tier exists.
        assert_eq!(tier("mxp", "max-pane"), Some(MatchTier::Scattered));
        assert_eq!(tier("zzq", "max-pane"), None);
    }

    #[test]
    fn www_is_not_something_anyone_types() {
        assert_eq!(search_handle("https://www.example.com/en"), "example.com/en");
        assert_eq!(search_handle("example.com"), "example.com");
        let hits = rank(&[candidate("https://www.example.com/en", None)], "example.com", 10);
        assert_eq!(hits.len(), 1);
    }
}
