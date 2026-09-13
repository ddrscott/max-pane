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
//! # There is no cap, and that is what the index is for
//!
//! Round 1 kept 5 000 rows and searched the newest 2 000 of them. The owner's
//! answer to that was "i don't think we need any limits on history", and the
//! arithmetic agrees: one row per normalised URL at roughly 250 bytes makes his
//! measured 112 840 URLs about 28 MB, and a decade at his rate about 155 MB.
//! Vivaldi spends 642 MB on the same browsing.
//!
//! What the cap was buying was a linear scan nobody had to think about. Scoring
//! 2 000 rows costs 2 ms; scoring 112 840 costs about a hundred times that,
//! per keystroke, on the main thread. So removing the cap is not free — it is
//! paid for by the trigram index in migration 0009, which narrows the table
//! before anything is scored, and by the shoulder entries of 0011 ([`edges`]),
//! which narrow it for the first two characters that a trigram cannot reach.
//! The measured cost at his real corpus size is in `cost_of_a_keystroke` in
//! `tests/history.rs`, which builds one.
//!
//! It reuses [`crate::search::fuzzy_score`] rather than growing a scorer of its
//! own, because ⌘P and this palette would otherwise disagree about which of two
//! URLs is the better match for the same typing, and there is no way for the
//! user to know which rules they are currently under. Swift still runs `Fuzzy`
//! over what comes back — on ≤50 rows, purely to find the offsets to paint
//! orange. Ranking in one place, highlighting where the pixels are.

use crate::model::SearchField;
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

/// The floor the trigram index works above.
///
/// FTS5's trigram tokenizer indexes three-character windows, so it has nothing
/// to say about a one- or two-character needle *of the haystack*. Below this
/// the shoulder entries of [`edges`] are asked instead, and the table is
/// scanned only when they cannot give a complete answer; see
/// [`crate::ledger::Ledger::history_search`].
pub const TRIGRAM_MIN_CHARS: usize = 3;

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

/// The searchable text of one row, as migration 0009 stores it: the URL, the
/// title and every alias, newline-separated and already lowercase.
///
/// A view, not an owner. This is the whole reason the index keeps a copy of the
/// text rather than only a posting list: a query that matches a common
/// substring — `com`, `git`, `log` — matches most of the corpus, and at 112 840
/// rows the cost of *fetching* those rows dominated everything else. Measured
/// before this shape: 97 ms of SQLite and 55 ms of scoring for `rust` against a
/// corpus where every title contained it. Borrowing the row out of the
/// statement and scoring it in place is what took that to single digits —
/// nothing is allocated per candidate, not even the lowercase copy, because
/// the index was written lowercase.
pub struct Haystack<'a>(&'a str);

impl<'a> Haystack<'a> {
    pub fn new(raw: &'a str) -> Self {
        Haystack(raw)
    }

    /// URL first, title second, aliases after. Split rather than stored as
    /// three columns because FTS5 would then have three indexes to consult and
    /// this code three reads to do, for text that is always read together.
    fn parts(&self) -> impl Iterator<Item = &'a str> {
        self.0.split('\n')
    }
}

/// What one row scored, and why.
#[derive(Debug, Clone, Copy)]
pub struct Hit {
    /// `visit.rowid`, which is what the index is keyed by. The row itself is
    /// fetched only for the handful that survive.
    pub rowid: i64,
    pub seq: i64,
    pub score: i32,
    pub field: SearchField,
    pub tier: MatchTier,
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

/// The best literal match `needle` has in `hay`, as a tier and a score inside
/// it. Both must already be lowercase. `None` means the characters are not in
/// there in that order, which leaves only [`MatchTier::Scattered`].
///
/// Every occurrence is considered, not just the first: `oo` in `google` is
/// mid-word at offset 1 and nothing else, but `com` in `example.com/compare` is
/// a word start on its second occurrence and mid-word on its first, and taking
/// the first would rank it as the worse of the two matches it actually has.
///
/// # Why the score is not [`fuzzy_score`] here
///
/// It used to be, and it cost more than everything else in a keystroke put
/// together: a second full pass over the field, per field, per row, to order
/// rows *inside* a tier that the same scan had already decided. Measured over
/// 112 840 rows it was about half of the 100 ms.
///
/// And it was answering the wrong question. `fuzzy_score` rates a subsequence,
/// which is a real question about `mxp` and `max-pane` and a meaningless one
/// about two rows that both literally contain `deploy`. What separates those is
/// how much of the field the match accounts for — how early it starts and how
/// little is left over — and the scan that found the tier already knows both.
/// Subsequence scoring survives where it means something: the scattered tier.
fn literal(needle: &str, hay: &str) -> Option<(MatchTier, i32)> {
    let mut best: Option<(MatchTier, i32)> = None;
    for (at, _) in hay.match_indices(needle) {
        let tier = if at == 0 {
            MatchTier::Prefix
        } else if hay[..at].chars().next_back().is_some_and(is_boundary) {
            MatchTier::WordPrefix
        } else {
            MatchTier::Substring
        };
        // Early beats late, and a match that is most of a short field beats the
        // same match lost in a long one. Bounded well under the 10 000 between
        // tiers, so this orders rows and never promotes one.
        let covers = (needle.len() * 256 / hay.len().max(1)) as i32;
        let score = 512 - (at as i32).min(255) + covers;
        if best.map_or(true, |(b, s)| tier < b || (tier == b && score > s)) {
            best = Some((tier, score));
        }
        if tier == MatchTier::Prefix {
            break;
        }
    }
    best
}

/// The two shoulders an edge entry can be built against: the start of a field,
/// and the start of a word inside one. See [`edges`].
///
/// Control characters because they are the only thing a page title cannot
/// contain by accident — the haystack is already newline-separated, so this
/// string was never plain text. A needle carrying one is refused rather than
/// escaped ([`edge_query`]): nobody types `\u{1}` and a query that could forge
/// an entry would match rows that do not contain it.
pub const EDGE_FIELD: char = '\u{2}';
/// The shoulder for a word start — the position after a [`is_boundary`] char.
pub const EDGE_WORD: char = '\u{1}';

/// The boundary-anchored shoulders of one row, as migration 0011 stores them.
///
/// # What this is for
///
/// FTS5's trigram tokenizer indexes three-character windows, so it has nothing
/// to say about a one- or two-character needle: below [`TRIGRAM_MIN_CHARS`] the
/// index cannot narrow and every row in the table is scored. Measured over the
/// owner's real 108 854 imported pages, every letter of the alphabet cost
/// between 62 and 87 ms as a first keystroke, against 17 ms from the third
/// character on. With the entries below, the worst letter is 48 ms and the
/// median one 10 ms.
///
/// The fix is to give the short needle three characters to find. Each place a
/// match could *start* — the front of a field, and every position after a word
/// boundary — contributes one entry: a doubled shoulder character and the two
/// characters that follow. `deploy` at a word start becomes `\u{1}\u{1}de`,
/// whose trigrams are `\u{1}\u{1}d` and `\u{1}de` — the first indexable form
/// of a one-character needle and of a two-character one.
///
/// Entries are run together with no separator, which is safe because a trigram
/// can only begin with a shoulder character at the start of a real entry: the
/// windows that straddle two entries all begin with ordinary text.
///
/// # Why this does not change any answer
///
/// It narrows, exactly like the trigram index it sits beside, and the caller
/// stops using it the moment it could be lossy. The entries are a *superset* of
/// the positions [`literal`] can call [`MatchTier::Prefix`] or
/// [`MatchTier::WordPrefix`]: the ranker matches URL fields through
/// [`search_handle`], which only ever strips a leading `www.` — so the entries
/// begin where the ranker begins reading, and every word start inside what is
/// left is a word start here too. The few entries that are not matches are
/// false positives, which cost a row's scoring and nothing else.
///
/// What makes the narrowing *complete* rather than merely likely is that the
/// tiers are 10 000 apart and a score inside one spans under 1 000
/// ([`MatchTier::base`]): every prefix match outranks every word-prefix match,
/// which outranks every mid-word one. So if the shoulder query returns enough
/// rows at a tier, the rows it did not return could not have reached the page —
/// and if it does not, [`crate::ledger::Ledger::history_search`] falls back to
/// the whole table. Round 1's silent truncation is the thing this round exists
/// not to repeat.
pub fn edges(hay: &str) -> String {
    let mut out = String::with_capacity(hay.len() / 2);
    let mut seen = SeenEdges::new();
    for (i, part) in hay.split('\n').enumerate() {
        // Where the ranker starts reading this field. The haystack is stored
        // raw and `search_handle` is applied at scoring time, so a row stored
        // as `www.example.com/en` is *matched* as `example.com/en` — while the
        // title, the one field `search_handle` must not touch, starts where it
        // starts. Offset 0 of a URL is deliberately not a field start and the
        // `www.` is not word starts: `w` cannot be a prefix match on a field
        // whose `www.` the ranker never sees, and indexing it anyway put 34 456
        // candidates in front of the 4 408 real ones the one time the owner is
        // most likely to type a single `w`.
        let from = if i == 1 { 0 } else { part.len() - search_handle(part).len() };
        let mut after_boundary = true;
        for (at, c) in part.char_indices() {
            if after_boundary && at >= from {
                push_edge(&mut out, &mut seen, EDGE_WORD, &part[at..]);
                if at == from {
                    push_edge(&mut out, &mut seen, EDGE_FIELD, &part[at..]);
                }
            }
            after_boundary = is_boundary(c);
        }
    }
    out
}

/// One entry, unless this row already has it. Deduplicated because a corpus of
/// URLs repeats its word starts — `com`, `www`, `github` — and an entry that is
/// already in the column narrows nothing a second time.
type SeenEdges = std::collections::HashSet<(char, char, Option<char>)>;

fn push_edge(out: &mut String, seen: &mut SeenEdges, kind: char, rest: &str) {
    let mut it = rest.chars();
    let Some(a) = it.next() else { return };
    // Whatever the next character is, including a boundary: `a-` really does
    // match at the word start of `a-b`, and the ranker would call it a word
    // prefix, so the index has to agree.
    let b = it.next();
    if !seen.insert((kind, a, b)) {
        return;
    }
    out.push(kind);
    out.push(kind);
    out.push(a);
    if let Some(b) = b {
        out.push(b);
    }
}

/// The trigram a one- or two-character `needle` has to find in [`edges`], or
/// `None` when there is no such thing — an empty needle, one already long
/// enough for the haystack index, or one carrying a shoulder character.
pub fn edge_query(needle: &str, kind: char) -> Option<String> {
    let mut it = needle.chars();
    let a = it.next()?;
    let b = it.next();
    if it.next().is_some() {
        return None;
    }
    if [Some(a), b].iter().flatten().any(|c| *c == EDGE_FIELD || *c == EDGE_WORD) {
        return None;
    }
    Some(match b {
        // `\u{1}\u{1}d`: the first trigram of every entry, whatever follows.
        None => format!("{kind}{kind}{a}"),
        // `\u{1}de`: the second, which only an entry can produce.
        Some(b) => format!("{kind}{a}{b}"),
    })
}

/// The best tier `needle` reaches in `hay`, subsequence included. The shape the
/// tier rules are stated in, and what the tests pin.
pub fn tier(needle: &str, hay: &str) -> Option<MatchTier> {
    if needle.is_empty() {
        return Some(MatchTier::Prefix);
    }
    literal(needle, hay)
        .map(|(t, _)| t)
        .or_else(|| fuzzy_score(needle, hay).map(|_| MatchTier::Scattered))
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

/// What a typed query actually matches against.
///
/// One function so the index and the ranker cannot disagree about it. The
/// ledger narrows the table with this string and [`rank`] scores with the same
/// one; if they ever diverged, the index would hide rows the ranker would have
/// matched and the failure would look exactly like the row cap did — a page
/// that is in the table and cannot be found.
pub fn needle(query: &str) -> String {
    search_handle(&query.trim().to_lowercase()).to_string()
}

/// Score and rank, one indexed row at a time.
///
/// # Why this streams instead of taking a list
///
/// Round 1 handed `rank` a `Vec<Candidate>` because the list was 2 000 rows by
/// construction. With the cap gone a query like `com` matches most of 112 840
/// rows, and materialising them cost more than scoring them did. So the rows
/// are offered one at a time straight out of the SQLite statement and only the
/// winners are ever built into anything.
///
/// Recency is a tie-break and not a term in the score, deliberately. A frecency
/// blend — the thing every browser's omnibox does — makes "why is this first"
/// unanswerable, and `Recent`'s doc comment already made this call once for the
/// new-pane picker. Two rows that match your typing equally well are separated
/// by which you saw last; a row that matches it better wins outright. `seq`
/// rather than `last_visit_at` is the tie-break for the reason migration 0004
/// gives: a wall clock has ties and a counter does not.
pub struct Ranking<'a> {
    needle: &'a str,
    /// A guess is only worth showing when there is nothing better.
    ///
    /// `git` is a subsequence of *SQLite — Wikipedia* (the g of `org`, the i of
    /// `wiki`, the t of `sqlite`) and always will be; over a hundred thousand
    /// rows there are thousands like it, and they are what made the old list
    /// read as noise even once the real hit was on top. So the two kinds of
    /// match never share a list: if anything matched literally, the
    /// coincidences go. If nothing did, they are all there is — which is what
    /// keeps `mxp` finding `max-pane`.
    literal: Vec<Hit>,
    scattered: Vec<Hit>,
}

impl<'a> Ranking<'a> {
    /// `needle` must have been through [`needle`].
    pub fn new(needle: &'a str) -> Self {
        Ranking { needle, literal: Vec::new(), scattered: Vec::new() }
    }

    /// True when not one row has matched, in any tier — the only case in which
    /// the caller has to go looking somewhere the index could not.
    pub fn is_empty(&self) -> bool {
        self.literal.is_empty() && self.scattered.is_empty()
    }

    /// How many rows have matched at `worst` or better.
    ///
    /// The question a narrowed search has to answer before it trusts itself: a
    /// shoulder query ([`edges`]) returns every row that can reach
    /// [`MatchTier::Prefix`], so once `limit` of them have, the rows it did not
    /// return are all a tier below and none of them could have made the page.
    /// Below `limit` the answer is honest only over the whole table, and
    /// [`crate::ledger::Ledger::history_search`] goes and reads it.
    pub fn hits_down_to(&self, worst: MatchTier) -> usize {
        self.literal.iter().filter(|h| h.tier <= worst).count()
    }

    /// Offer one row. Cheap to call and cheap to reject: the common answer is
    /// "no tier", which costs one substring search per field.
    pub fn offer(&mut self, rowid: i64, seq: i64, hay: Haystack<'_>) {
        let mut best: Option<(i32, SearchField, MatchTier)> = None;
        for (i, part) in hay.parts().enumerate() {
            // The title is the one field that is not an address, so it is the
            // one field `search_handle` must not touch.
            let (part, field, bias) = match i {
                // Titles outrank URLs by the same margin they do in
                // [`crate::search`]: what the user remembers about a page is
                // what it was called.
                1 => (part, SearchField::Title, TITLE_BIAS),
                // An alias is folded into `Url` rather than given a
                // `SearchField` case of its own — the enum crosses the FFI into
                // exhaustive Swift switches that other palettes own, and a
                // redirect source is a URL in every sense the reader cares
                // about. Minus a hair, so that when the address you typed and
                // the address you landed on both match, the row is explained by
                // the one that is actually on screen.
                0 => (search_handle(part), SearchField::Url, 0),
                _ => (search_handle(part), SearchField::Url, -ALIAS_PENALTY),
            };
            let Some((tier, score)) = literal(self.needle, part) else { continue };
            let total = tier.base() + score + bias;
            if best.map_or(true, |(b, _, _)| total > b) {
                best = Some((total, field, tier));
            }
        }
        if best.is_none() {
            // Nothing literal anywhere in the row. The subsequence tier is the
            // only one left, and it is the only place `fuzzy_score` is still
            // asked anything — see `literal`.
            for (i, part) in hay.parts().enumerate() {
                let (part, field, bias) = match i {
                    1 => (part, SearchField::Title, TITLE_BIAS),
                    0 => (search_handle(part), SearchField::Url, 0),
                    _ => (search_handle(part), SearchField::Url, -ALIAS_PENALTY),
                };
                let Some(score) = fuzzy_score(self.needle, part) else { continue };
                let total = MatchTier::Scattered.base() + score + bias;
                if best.map_or(true, |(b, _, _)| total > b) {
                    best = Some((total, field, MatchTier::Scattered));
                }
            }
        }
        let Some((score, field, tier)) = best else { return };
        let hit = Hit { rowid, seq, score, field, tier };
        if tier < MatchTier::Scattered {
            self.literal.push(hit);
        } else {
            self.scattered.push(hit);
        }
    }

    /// The best `limit` rows, best first.
    pub fn finish(self, limit: usize) -> Vec<Hit> {
        let mut hits = if self.literal.is_empty() { self.scattered } else { self.literal };
        hits.sort_unstable_by(|a, b| b.score.cmp(&a.score).then_with(|| b.seq.cmp(&a.seq)));
        hits.truncate(limit);
        hits
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A row as the index stores it: newest first is *last* offered, because
    /// the tie-break is `seq` and the caller lists rows in the order they were
    /// visited. Written as the ledger writes it — lowercase, newline-joined.
    fn row(url: &str, title: Option<&str>, aliases: &[&str]) -> String {
        let mut hay = format!("{}\n{}", url.to_lowercase(), title.unwrap_or("").to_lowercase());
        for a in aliases {
            hay.push('\n');
            hay.push_str(&a.to_lowercase());
        }
        hay
    }

    /// Score `query` over `rows` — listed oldest first, so the last is newest —
    /// and give back the URLs that won, best first.
    fn ranked(rows: &[(&str, Option<&str>, &[&str])], query: &str, limit: usize) -> Vec<String> {
        let hays: Vec<String> = rows.iter().map(|(u, t, a)| row(u, *t, a)).collect();
        let needle = needle(query);
        let mut ranking = Ranking::new(&needle);
        for (i, hay) in hays.iter().enumerate() {
            ranking.offer(i as i64, i as i64, Haystack::new(hay));
        }
        ranking
            .finish(limit)
            .into_iter()
            .map(|h| rows[h.rowid as usize].0.to_string())
            .collect()
    }

    /// The same, when the test is about *why* a row won rather than which did.
    fn top(rows: &[(&str, Option<&str>, &[&str])], query: &str) -> Hit {
        let hays: Vec<String> = rows.iter().map(|(u, t, a)| row(u, *t, a)).collect();
        let needle = needle(query);
        let mut ranking = Ranking::new(&needle);
        for (i, hay) in hays.iter().enumerate() {
            ranking.offer(i as i64, i as i64, Haystack::new(hay));
        }
        ranking.finish(10).into_iter().next().expect("nothing matched")
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
    fn a_title_match_outranks_a_url_match_of_the_same_kind() {
        // `TITLE_BIAS` decides between two matches that are equally literal —
        // both of these are a word start — and no longer reaches across tiers.
        // It used to: a flat bonus on a subsequence score meant a title
        // coincidence beat a real URL hit, which is the failure
        // `a_literal_hit_outranks_a_title_coincidence` pins.
        let rows: &[(&str, Option<&str>, &[&str])] = &[
            ("https://x.example/docs/rust", None, &[]),
            ("https://b.example/q", Some("The Rust Programming Language"), &[]),
        ];
        assert_eq!(ranked(rows, "rust", 10)[0], "https://b.example/q");
        assert_eq!(top(rows, "rust").field, SearchField::Title);
    }

    #[test]
    fn a_better_match_beats_a_newer_one() {
        // Recency is the tie-break, not a thumb on the scale: the zebra row is
        // offered last and so is the newer of the two.
        let rows: &[(&str, Option<&str>, &[&str])] = &[
            ("https://docs.example/rust", None, &[]),
            ("https://n.example/zebra-quilt", None, &[]),
        ];
        assert_eq!(ranked(rows, "rust", 10)[0], "https://docs.example/rust");
    }

    #[test]
    fn recency_breaks_a_tie() {
        // Two identical matches, and the one visited later leads.
        let rows: &[(&str, Option<&str>, &[&str])] = &[
            ("https://old.example/rust", None, &[]),
            ("https://new.example/rust", None, &[]),
        ];
        assert_eq!(ranked(rows, "/rust", 10)[0], "https://new.example/rust");
    }

    #[test]
    fn the_address_you_typed_finds_the_page_you_landed_on() {
        let rows: &[(&str, Option<&str>, &[&str])] =
            &[("https://www.example.com/en", Some("Example"), &["https://example.com"])];
        let hits = ranked(rows, "example.com", 10);
        assert_eq!(hits.len(), 1, "the redirect source found nothing");
        assert_eq!(hits[0], "https://www.example.com/en", "the entry is where you ended up");
    }

    #[test]
    fn nothing_matching_returns_nothing() {
        assert!(ranked(&[("https://example.com", None, &[])], "zzqq", 10).is_empty());
    }

    // ---- tiers: a literal hit always beats a scattered one -------------------

    #[test]
    fn a_literal_hit_outranks_a_title_coincidence() {
        // The measured failure: `hop` led with titles whose h, o and p are
        // three unrelated letters, and the page whose URL says `hop` was not
        // on screen at all.
        let hits = ranked(
            &[
                ("https://developer.mozilla.org/x", Some("Checker notes 4805"), &[]),
                ("https://launchd.info/y", Some("Launchd notes 4520"), &[]),
                ("https://shop.example.com/hoppers", None, &[]),
            ],
            "hop",
            10,
        );
        assert_eq!(hits[0], "https://shop.example.com/hoppers");
    }

    #[test]
    fn a_scheme_is_not_a_prefix_of_the_whole_table() {
        // `http://git` used to return SQLite — Wikipedia, because every URL is
        // a subsequence match for a scheme plus three letters.
        let hits = ranked(
            &[
                ("https://en.wikipedia.org/wiki/SQLite", Some("SQLite - Wikipedia"), &[]),
                ("https://github.com/anthropics", Some("GitHub"), &[]),
            ],
            "http://git",
            10,
        );
        assert_eq!(hits.len(), 1, "the scheme matched rows it has nothing to do with");
        assert_eq!(hits[0], "https://github.com/anthropics");
    }

    #[test]
    fn a_word_start_beats_the_middle_of_a_word() {
        let hits = ranked(
            &[
                ("https://example.com/deployment-notes", None, &[]),
                ("https://example.com/deploy", None, &[]),
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

    // ---- the shoulder entries ----------------------------------------------

    /// True when a needle of one or two characters would find `hay` through the
    /// shoulder column — the question the ledger asks the index.
    fn shouldered(hay: &str, needle: &str, kind: char) -> bool {
        let column = edges(hay);
        let q = edge_query(needle, kind).expect("no query for this needle");
        column.contains(&q)
    }

    #[test]
    fn a_word_start_is_reachable_by_one_character_and_by_two() {
        let hay = row("https://github.com/anthropics/deploy", Some("Deploy"), &[]);
        assert!(shouldered(&hay, "d", EDGE_WORD));
        assert!(shouldered(&hay, "de", EDGE_WORD));
        assert!(shouldered(&hay, "g", EDGE_FIELD), "the front of the URL is a field start");
        assert!(shouldered(&hay, "d", EDGE_FIELD), "the front of the title is a field start");
        // `pl` is inside `deploy` and starts nothing.
        assert!(!shouldered(&hay, "pl", EDGE_WORD));
        assert!(!shouldered(&hay, "an", EDGE_FIELD), "a word start is not a field start");
    }

    #[test]
    fn a_word_prefix_that_ends_on_a_boundary_is_still_indexed() {
        // `a-` really is a word prefix of `a-b`, and `literal` says so. If the
        // entry stopped at the word's own characters the index would disagree
        // with the ranker, which is a row in the table that cannot be found.
        let hay = row("https://x.example/a-b", None, &[]);
        assert_eq!(tier("a-", "x.example/a-b"), Some(MatchTier::WordPrefix));
        assert!(shouldered(&hay, "a-", EDGE_WORD));
    }

    #[test]
    fn the_www_a_reader_never_sees_is_not_a_shoulder() {
        // `search_handle` strips it, so no field and no word of the matched
        // text begins there — and over the owner's corpus indexing it anyway
        // made `w` the one keystroke this round made slower.
        let hay = row("https://www.example.com/en", Some("Example"), &[]);
        assert!(!shouldered(&hay, "w", EDGE_FIELD));
        assert!(!shouldered(&hay, "w", EDGE_WORD));
        assert!(!shouldered(&hay, "ww", EDGE_WORD));
        assert!(shouldered(&hay, "ex", EDGE_FIELD), "the field starts after the www.");
        assert_eq!(tier("ex", search_handle("www.example.com/en")), Some(MatchTier::Prefix));
    }

    #[test]
    fn every_prefix_and_word_prefix_the_ranker_can_see_has_a_shoulder() {
        // The superset property the narrowing rests on, checked exhaustively
        // over one row rather than argued: if the ranker would call a one- or
        // two-character needle a prefix or a word prefix of a field, the
        // shoulder column has to contain the trigram that finds it.
        let raw = "www.example.com/a-b/Deploy?q=x#frag";
        let hay = row(raw, Some("Deploy notes — 2026"), &["https://ex.am/pl"]);
        let column = edges(&hay);
        let fields: Vec<String> = hay
            .split('\n')
            .enumerate()
            .map(|(i, p)| if i == 1 { p.to_string() } else { search_handle(p).to_string() })
            .collect();
        let alphabet: Vec<char> = "abcdefghijklmnopqrstuvwxyz0123456789-./?=# ".chars().collect();
        let mut needles: Vec<String> = alphabet.iter().map(|c| c.to_string()).collect();
        for a in &alphabet {
            for b in &alphabet {
                needles.push(format!("{a}{b}"));
            }
        }
        for needle in needles {
            for field in &fields {
                let Some((t, _)) = literal(&needle, field) else { continue };
                let kind = match t {
                    MatchTier::Prefix => EDGE_FIELD,
                    MatchTier::WordPrefix => EDGE_WORD,
                    _ => continue,
                };
                let q = edge_query(&needle, kind).unwrap();
                assert!(
                    column.contains(&q),
                    "{needle:?} is a {t:?} of {field:?} and the index cannot find it"
                );
            }
        }
    }

    #[test]
    fn a_shoulder_character_in_the_needle_is_refused_rather_than_indexed() {
        assert!(edge_query("\u{1}", EDGE_WORD).is_none());
        assert!(edge_query("a\u{2}", EDGE_FIELD).is_none());
        assert!(edge_query("", EDGE_WORD).is_none());
        assert!(edge_query("abc", EDGE_WORD).is_none(), "three characters have a trigram already");
    }

    #[test]
    fn www_is_not_something_anyone_types() {
        assert_eq!(search_handle("https://www.example.com/en"), "example.com/en");
        assert_eq!(search_handle("example.com"), "example.com");
        assert_eq!(ranked(&[("https://www.example.com/en", None, &[])], "example.com", 10).len(), 1);
    }
}
