//! Browsing history: recorded on the first visit, found after a restart, and
//! with no hole where a redirect was.
//!
//! The kill criterion registered for this piece is "a page visited in a pane is
//! findable by title and by URL after a restart, and the record has no hole
//! where a redirect was", so most of what is below is that sentence taken
//! literally — including the restart, which is done the way `durability.rs`
//! does it: drop the `Core` with no shutdown path and reopen the file.

use laned_core::ledger::Ledger;
use laned_core::model::*;
use laned_core::Core;
use std::path::Path;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// One web lane, and the id of its pane.
fn web_pane(core: &Core, url: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some(url.to_string()), None)
        .unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

fn urls(entries: &[HistoryEntry]) -> Vec<String> {
    entries.iter().map(|e| e.url.clone()).collect()
}

// ---- the kill criterion -----------------------------------------------------

#[test]
fn a_page_is_findable_by_title_and_by_url_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    {
        let core = Core::open(db(&dir)).unwrap();
        let pane = web_pane(&core, "https://doc.rust-lang.org/std/");
        core.record_visit(
            pane,
            "https://doc.rust-lang.org/std/index.html".into(),
            Some("std - Rust".into()),
            Vec::new(),
        )
        .unwrap();
        // No flush, no close, no goodbye.
    }

    let core = Core::open(db(&dir)).unwrap();
    let by_title = core.history("std rust".into(), 10).unwrap();
    assert_eq!(by_title.len(), 1, "the title found nothing after a restart");
    assert_eq!(by_title[0].matched_field, SearchField::Title);

    let by_url = core.history("doc.rust-lang".into(), 10).unwrap();
    assert_eq!(urls(&by_url), vec!["https://doc.rust-lang.org/std/index.html"]);
    assert_eq!(by_url[0].matched_field, SearchField::Url);
}

#[test]
fn the_address_you_asked_for_finds_the_page_you_landed_on() {
    // The registered failure: you type `example.com`, land on
    // `https://www.example.com/en`, and history has never heard of what you
    // typed.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane,
        "https://www.example.com/en".into(),
        Some("Example Domain".into()),
        vec!["https://example.com/".into()],
    )
    .unwrap();

    let hits = core.history("example.com".into(), 10).unwrap();
    assert_eq!(urls(&hits), vec!["https://www.example.com/en"], "the redirect left a hole");
    assert_eq!(core.history_count().unwrap(), 1, "the redirect source was listed as a page of its own");
}

#[test]
fn a_redirect_source_is_never_a_row_of_its_own() {
    // Listing it would show two lines for one visit — and the second one
    // reopens to a bounce, not to a page.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane,
        "https://www.example.com/en".into(),
        Some("Example Domain".into()),
        vec!["https://example.com/".into()],
    )
    .unwrap();
    let all = core.history(String::new(), 50).unwrap();
    assert_eq!(urls(&all), vec!["https://www.example.com/en"]);
}

#[test]
fn every_hop_of_a_chain_is_searchable_and_none_of_them_is_a_row() {
    // A two-hop server chain used to lose its middle: `didFinish` read one
    // address out of `backForwardList.currentItem?.initialURL`, and a chain is
    // a list. All three addresses reopen the page they led to.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane,
        "https://docs.example/en/latest".into(),
        Some("Docs".into()),
        vec!["https://short.example/x".into(), "https://docs.example".into()],
    )
    .unwrap();
    assert_eq!(core.history_count().unwrap(), 1, "a hop became a page");
    for typed in ["short.example/x", "docs.example", "docs.example/en/latest"] {
        assert_eq!(
            urls(&core.history(typed.into(), 10).unwrap()),
            vec!["https://docs.example/en/latest"],
            "{typed} did not find the page it led to"
        );
    }
}

#[test]
fn a_page_that_turns_out_to_be_a_bounce_stops_being_a_page() {
    // The measured failure: `location.replace` and `<meta refresh>` each
    // finish loading — so each is recorded as a page, untitled, reopening to a
    // bounce — and only then redirect. The shell learns what it was a moment
    // later, and this is where that correction lands.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://bounce.example/js".into(), None, Vec::new()).unwrap();
    assert_eq!(core.history_count().unwrap(), 1);

    core.record_visit(
        pane,
        "https://real.example/page".into(),
        Some("The Real Page".into()),
        vec!["https://bounce.example/js".into()],
    )
    .unwrap();
    assert_eq!(core.history_count().unwrap(), 1, "the interstitial stayed a row of its own");
    assert_eq!(
        urls(&core.history("bounce.example".into(), 10).unwrap()),
        vec!["https://real.example/page"],
        "the address that bounced stopped being findable"
    );
}

#[test]
fn demoting_a_bounce_brings_its_own_aliases_with_it() {
    // Land on a shortener, follow its 303 to a consent page, and have that
    // redirect itself. The address the user typed is the one hop anyone ever
    // searches for, and it is the first to be lost if each settle starts over.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane.clone(),
        "https://consent.example/ask".into(),
        None,
        vec!["https://youtu.be/dQw4w9WgXcQ".into()],
    )
    .unwrap();
    core.record_visit(
        pane,
        "https://youtube.com/watch?v=dQw4w9WgXcQ".into(),
        Some("A Song".into()),
        vec!["https://youtu.be/dQw4w9WgXcQ".into(), "https://consent.example/ask".into()],
    )
    .unwrap();
    assert_eq!(core.history_count().unwrap(), 1, "three rows, which is what round 1 produced");
    for typed in ["youtu.be/dQw4w9WgXcQ", "consent.example", "watch?v=dQw4w9WgXcQ"] {
        assert_eq!(
            urls(&core.history(typed.into(), 10).unwrap()),
            vec!["https://youtube.com/watch?v=dQw4w9WgXcQ"],
            "{typed} found the wrong thing, or nothing"
        );
    }
}

#[test]
fn a_redirect_that_goes_nowhere_writes_no_alias() {
    // The shell passes the requested URL on every navigation, redirect or not;
    // the overwhelmingly common case is that it is the same address.
    let dir = tempfile::tempdir().unwrap();
    {
        let core = Core::open(db(&dir)).unwrap();
        let pane = web_pane(&core, "https://example.com");
        core.record_visit(
            pane,
            "https://example.com/".into(),
            Some("Example".into()),
            // Differs only by the trailing slash the normalizer folds away.
            vec!["https://example.com".into()],
        )
        .unwrap();
    }
    assert_eq!(alias_count(Path::new(&db(&dir))), 0);
}

// ---- what counts as a visit -------------------------------------------------

#[test]
fn the_same_page_twice_is_one_row_with_a_count_of_two() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://example.com/a".into(), Some("A".into()), Vec::new()).unwrap();
    // A different page in between, so the coalescing window is not what is
    // being measured here.
    core.record_visit(pane.clone(), "https://example.com/b".into(), Some("B".into()), Vec::new()).unwrap();
    core.record_visit(pane, "https://example.com/a".into(), Some("A".into()), Vec::new()).unwrap();

    let all = core.history(String::new(), 50).unwrap();
    assert_eq!(all.len(), 2, "a revisit made a second row");
    assert_eq!(all[0].url, "https://example.com/a", "a revisit did not come back to the front");
    assert_eq!(all[0].visit_count, 2);
    assert_eq!(all[1].visit_count, 1);
}

#[test]
fn one_navigation_reported_three_times_is_one_visit() {
    // What actually happens: a redirect lands, the destination finishes, and
    // the title arrives — three delegate callbacks for one thing the user did.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    for _ in 0..3 {
        core.record_visit(pane.clone(), "https://example.com/a".into(), Some("A".into()), Vec::new()).unwrap();
    }
    let all = core.history(String::new(), 50).unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].visit_count, 1, "one navigation counted {} times", all[0].visit_count);
}

#[test]
fn the_same_page_in_two_panes_is_two_visits() {
    let core = Core::open_in_memory().unwrap();
    let a = web_pane(&core, "https://example.com");
    let b = web_pane(&core, "https://example.com");
    core.record_visit(a, "https://example.com/a".into(), None, Vec::new()).unwrap();
    core.record_visit(b, "https://example.com/a".into(), None, Vec::new()).unwrap();
    assert_eq!(core.history(String::new(), 10).unwrap()[0].visit_count, 2);
}

#[test]
fn a_late_title_names_the_page_without_counting_a_visit() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    // `WKWebView.title` is usually still empty when the navigation finishes.
    core.record_visit(pane, "https://example.com/a".into(), None, Vec::new()).unwrap();
    core.name_visit("https://example.com/a".into(), "Arrived Late".into()).unwrap();

    let all = core.history(String::new(), 10).unwrap();
    assert_eq!(all[0].title.as_deref(), Some("Arrived Late"));
    assert_eq!(all[0].visit_count, 1);
    assert_eq!(core.history("arrived".into(), 10).unwrap().len(), 1);
}

#[test]
fn a_title_that_never_arrives_does_not_blank_the_one_that_did() {
    let core = Core::open_in_memory().unwrap();
    let a = web_pane(&core, "https://example.com");
    let b = web_pane(&core, "https://example.com");
    core.record_visit(a, "https://example.com/a".into(), Some("Named".into()), Vec::new()).unwrap();
    core.record_visit(b, "https://example.com/a".into(), None, Vec::new()).unwrap();
    assert_eq!(core.history(String::new(), 10).unwrap()[0].title.as_deref(), Some("Named"));
}

#[test]
fn naming_a_page_that_was_never_visited_invents_nothing() {
    let core = Core::open_in_memory().unwrap();
    core.name_visit("https://example.com/never".into(), "Phantom".into()).unwrap();
    assert_eq!(core.history_count().unwrap(), 0);
}

#[test]
fn a_blank_pane_is_not_a_page() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "about:blank");
    for url in ["about:blank", "data:text/html,<p>hi", "blob:https://x/1"] {
        core.record_visit(pane.clone(), url.into(), None, Vec::new()).unwrap();
    }
    assert_eq!(core.history_count().unwrap(), 0);
}

#[test]
fn a_single_page_app_pushing_fifty_states_is_fifty_pages_and_stays_fifty() {
    // Fifty addresses the user really did navigate to are fifty rows; going
    // round the same fifty again does not make a hundred. The record
    // aggregates on URL, so the palette never has to de-duplicate on read.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://app.example");
    for pass in 0..2 {
        for i in 0..50 {
            core.record_visit(
                pane.clone(),
                format!("https://app.example/#/thread/{i}"),
                Some(format!("Thread {i}")),
                Vec::new(),
            )
            .unwrap();
        }
        assert_eq!(core.history_count().unwrap(), 50, "after pass {pass}");
    }
}

// ---- ordering ---------------------------------------------------------------

#[test]
fn an_empty_query_is_newest_first() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    for i in 0..5 {
        core.record_visit(pane.clone(), format!("https://example.com/{i}"), None, Vec::new()).unwrap();
    }
    assert_eq!(
        urls(&core.history(String::new(), 10).unwrap()),
        (0..5).rev().map(|i| format!("https://example.com/{i}")).collect::<Vec<_>>()
    );
}

#[test]
fn ordering_does_not_depend_on_the_clock() {
    // 0003's trap, and history walks into the same one: several visits inside
    // one millisecond — a restored strip rehydrating eight panes at once —
    // must still come back in the order they happened.
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    for i in 0..8 {
        // Every one of them claims the same instant.
        ledger.record_visit(&format!("https://example.com/{i}"), None, 1_700_000_000_000).unwrap();
    }
    let got: Vec<String> =
        ledger.history_newest(50).unwrap().into_iter().map(|c| c.url).collect();
    assert_eq!(
        got,
        (0..8).rev().map(|i| format!("https://example.com/{i}")).collect::<Vec<_>>(),
        "a tied clock scrambled the order"
    );
}

#[test]
fn a_better_match_wins_and_recency_only_breaks_ties() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://docs.example/rust".into(), None, Vec::new()).unwrap();
    // Visited later, and it does contain r…u…s…t as a subsequence.
    core.record_visit(pane, "https://n.example/rough-untidy-storage-thing".into(), None, Vec::new())
        .unwrap();
    assert_eq!(core.history("rust".into(), 10).unwrap()[0].url, "https://docs.example/rust");
}

// ---- no caps ----------------------------------------------------------------

#[test]
fn nothing_is_evicted_by_age_or_by_count() {
    // Round 1 kept 5 000 rows and 90 days. The owner's answer was "i don't
    // think we need any limits on history", so the only thing that removes a
    // row now is the user removing it.
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let now = 1_700_000_000_000i64;
    let ancient = now - 5 * 365 * 24 * 60 * 60 * 1_000;
    ledger.record_visit("https://ancient.example", Some("Five years ago"), ancient).unwrap();
    for i in 0..6_000 {
        ledger.record_visit(&format!("https://example.com/{i}"), None, now).unwrap();
    }
    assert_eq!(ledger.history_count().unwrap(), 6_001);
    let found = ledger.history_search("ancient.example", 0, 50).unwrap();
    assert_eq!(found.len(), 1, "a five-year-old page under 6 000 newer ones was evicted");
}

#[test]
fn a_row_far_below_the_old_scan_depth_is_findable() {
    // The single biggest gap the critic found: a planted needle at depth 2 499
    // sat in the table and could not be found, while the footer counted it.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane.clone(),
        "https://needle.example/buried".into(),
        Some("Planted".into()),
        Vec::new(),
    )
    .unwrap();
    for i in 0..5_000 {
        core.record_visit(pane.clone(), format!("https://example.com/{i}"), None, Vec::new())
            .unwrap();
    }
    assert_eq!(core.history_count().unwrap(), 5_001);
    assert_eq!(core.history_searchable_count().unwrap(), 5_001, "the footer lied about its reach");
    let hits = core.history("needle.example".into(), 50).unwrap();
    assert_eq!(urls(&hits), vec!["https://needle.example/buried"], "depth 5 000 was unreachable");
    // And by title, which lives in the same index.
    assert_eq!(core.history("planted".into(), 50).unwrap().len(), 1);
}

#[test]
fn the_index_and_the_ranker_agree_about_what_matches() {
    // The index narrows and `rank` scores, so a row the index drops is a row
    // the user cannot find however well it would have scored. Every tier has to
    // survive the narrowing — including the scattered one, which the trigram
    // index cannot see at all and which falls back to the whole table.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    for (url, title) in [
        ("https://shop.example.com/hoppers", None),
        ("https://developer.mozilla.org/x", Some("Checker notes 4805")),
        ("https://example.com/max-pane", Some("Max Pane")),
        ("https://console.aws.amazon.com/cloudwatch/home#logsV2:log-group", Some("CloudWatch")),
    ] {
        core.record_visit(pane.clone(), url.into(), title.map(str::to_string), Vec::new()).unwrap();
    }
    // Prefix, word-start and mid-word all reach the ranker.
    assert_eq!(urls(&core.history("hop".into(), 10).unwrap()), vec!["https://shop.example.com/hoppers"]);
    assert_eq!(urls(&core.history("logsv2".into(), 10).unwrap()).len(), 1, "a match after a # was lost");
    assert_eq!(urls(&core.history("ppers".into(), 10).unwrap()).len(), 1, "a mid-word match was lost");
    // And the subsequence tier, which only applies when nothing matched
    // literally — exactly when the index has nothing to say.
    assert_eq!(urls(&core.history("mxp".into(), 10).unwrap()), vec!["https://example.com/max-pane"]);
    // One and two characters are below the trigram floor and take the scan.
    assert!(!core.history("h".into(), 10).unwrap().is_empty());
    assert!(!core.history("cl".into(), 10).unwrap().is_empty());
}

#[test]
fn the_index_survives_a_restart_and_a_rename() {
    // It is a second copy of the text, so every write that changes what a row
    // says has to change what it matches. A title that lands late is the one
    // that used to be missed.
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    {
        let core = Core::open(path.clone()).unwrap();
        let pane = web_pane(&core, "https://example.com");
        core.record_visit(pane, "https://late.example/x".into(), None, Vec::new()).unwrap();
        core.name_visit("https://late.example/x".into(), "Arrived Late".into()).unwrap();
    }
    let core = Core::open(path).unwrap();
    assert_eq!(core.history("arrived late".into(), 10).unwrap().len(), 1, "a late title was lost");
}

#[test]
fn a_ledger_written_before_the_index_is_backfilled() {
    // Existing ledgers arrive with a `visit` table and no `visit_search`. The
    // migration has to index what is already there or every page anyone has
    // ever visited becomes unfindable at the moment of the upgrade.
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    {
        let core = Core::open(path.clone()).unwrap();
        let pane = web_pane(&core, "https://example.com");
        core.record_visit(
            pane,
            "https://backfill.example/page".into(),
            Some("Backfilled".into()),
            vec!["https://short.example".into()],
        )
        .unwrap();
    }
    {
        // Pretend 0009 never ran.
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute("DROP TABLE visit_search", []).unwrap();
        conn.execute("DELETE FROM schema_migration WHERE name = '0009_history_index'", [])
            .unwrap();
    }
    let core = Core::open(path).unwrap();
    assert_eq!(core.history("backfill".into(), 10).unwrap().len(), 1, "the URL was not indexed");
    assert_eq!(core.history("backfilled".into(), 10).unwrap().len(), 1, "the title was not indexed");
    assert_eq!(core.history("short.example".into(), 10).unwrap().len(), 1, "aliases were not indexed");
}

#[test]
fn forgetting_a_page_takes_it_out_of_the_index_too() {
    // Otherwise the index is a second table that grows forever and matches rows
    // that are gone — which, joined back to `visit`, quietly returns nothing
    // and looks like the search being broken.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://gone.example/x".into(), Some("Gone".into()), Vec::new())
        .unwrap();
    core.forget_visit("https://gone.example/x".into()).unwrap();
    assert!(core.history("gone.example".into(), 10).unwrap().is_empty());

    core.record_visit(pane, "https://back.example/x".into(), Some("Back".into()), Vec::new())
        .unwrap();
    core.clear_history().unwrap();
    assert!(core.history("back.example".into(), 10).unwrap().is_empty());
    assert_eq!(core.history_count().unwrap(), 0);
}

#[test]
fn forgetting_one_page_takes_its_aliases_and_leaves_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let core = Core::open(path.clone()).unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(
        pane.clone(),
        "https://www.example.com/en".into(),
        Some("Example".into()),
        vec!["https://example.com".into()],
    )
    .unwrap();
    core.record_visit(pane, "https://keep.example".into(), Some("Keep".into()), Vec::new()).unwrap();

    core.forget_visit("https://www.example.com/en".into()).unwrap();
    assert_eq!(urls(&core.history(String::new(), 10).unwrap()), vec!["https://keep.example"]);
    assert_eq!(alias_count(Path::new(&path)), 0);
    assert!(
        core.history("example.com".into(), 10).unwrap().is_empty(),
        "a forgotten page is still reachable through the address that redirected to it"
    );
}

#[test]
fn clearing_leaves_nothing() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane, "https://example.com/a".into(), Some("A".into()), Vec::new()).unwrap();
    core.clear_history().unwrap();
    assert_eq!(core.history_count().unwrap(), 0);
    assert!(core.history(String::new(), 10).unwrap().is_empty());
}

// ---- migration --------------------------------------------------------------

/// The migration has to land on a ledger that already has a strip in it — which
/// is every ledger but the one on a machine that has never run the app.
#[test]
fn the_migration_lands_on_a_populated_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let lane_id = seed_a_pre_history_ledger(Path::new(&path));

    let core = Core::open(path.clone()).unwrap();

    // Everything that was there is still there.
    let state = core.state().unwrap();
    assert_eq!(state.lanes.len(), 1);
    assert_eq!(state.lanes[0].id, lane_id);
    assert_eq!(state.lanes[0].title.as_deref(), Some("A lane from before"));
    assert_eq!(state.lanes[0].panes.len(), 1);
    assert_eq!(state.lanes[0].panes[0].url.as_deref(), Some("https://example.com/old"));
    assert_eq!(core.recents(10).unwrap().len(), 1, "0003's recents did not survive 0004");

    // And history works on it.
    assert_eq!(core.history_count().unwrap(), 0, "an upgraded ledger invented history");
    let pane = state.lanes[0].panes[0].id.clone();
    core.record_visit(pane, "https://example.com/new".into(), Some("New".into()), Vec::new()).unwrap();
    assert_eq!(urls(&core.history("new".into(), 10).unwrap()), vec!["https://example.com/new"]);
}

#[test]
fn the_migration_runs_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    seed_a_pre_history_ledger(Path::new(&path));
    // Three opens: the upgrade, and two that must do nothing. A migration that
    // re-runs its `CREATE TABLE` is an error that only shows up on the second
    // launch after a release.
    for _ in 0..3 {
        let core = Core::open(path.clone()).unwrap();
        let pane = core.state().unwrap().lanes[0].panes[0].id.clone();
        core.record_visit(pane, "https://example.com/x".into(), None, Vec::new()).unwrap();
    }
    let core = Core::open(path).unwrap();
    assert_eq!(core.history(String::new(), 10).unwrap()[0].visit_count, 3);
}

/// A ledger as it was before this piece: migrations 0001-0003 applied by hand,
/// with a lane, a pane and a recent in it.
///
/// Built from the same SQL the crate ships rather than from a checked-in
/// fixture file, so it cannot drift from what a real 0003 ledger looks like.
fn seed_a_pre_history_ledger(path: &Path) -> String {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute(
        "CREATE TABLE schema_migration (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
        [],
    )
    .unwrap();
    for (name, sql) in [
        ("0001_initial", include_str!("../migrations/0001_initial.sql")),
        ("0002_lane_span", include_str!("../migrations/0002_lane_span.sql")),
        ("0003_session_and_recents", include_str!("../migrations/0003_session_and_recents.sql")),
    ] {
        conn.execute_batch(sql).unwrap();
        conn.execute(
            "INSERT INTO schema_migration (name, applied_at) VALUES (?1, 0)",
            rusqlite::params![name],
        )
        .unwrap();
    }
    let lane_id = "01OLDLANE00000000000000000";
    conn.execute(
        "INSERT INTO lane (id, ordinal, width_pt, title, project_root, project_source,
                           created_at, last_focus_at, pinned, span)
         VALUES (?1, 0.0, 656, 'A lane from before', NULL, 'inherited', 1, 1, 0, 1)",
        rusqlite::params![lane_id],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO pane (id, lane_id, position, kind, relay_session_id, url, scroll_y,
                           data_store_id, snapshot_path, state)
         VALUES ('01OLDPANE00000000000000000', ?1, 0, 'web', NULL,
                 'https://example.com/old', NULL, NULL, NULL, 'live')",
        rusqlite::params![lane_id],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO recent (kind, value, cwd, seq, last_used_at, use_count)
         VALUES ('url', 'https://example.com/old', NULL, 1, 1, 1)",
        [],
    )
    .unwrap();
    lane_id.to_string()
}

/// Read the alias table the way anything outside the crate would have to.
fn alias_count(path: &Path) -> i64 {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.query_row("SELECT COUNT(*) FROM visit_alias", [], |r| r.get(0)).unwrap()
}

// ---- cost -------------------------------------------------------------------

/// How many pages the cost test builds.
///
/// Not a round number and not a guess: it is the count of distinct URLs in the
/// owner's real Vivaldi profile on 2026-09-12, read out of
/// `~/Library/Application Support/Vivaldi/Default/History`. A search that is
/// fast on 5 000 rows and untested on 100 000 has not been tested, and 5 000
/// was exactly the number round 1 measured itself against.
const HIS_CORPUS: u32 = 112_840;

/// A keystroke in the history palette is a SQLite read plus a scan, on the main
/// thread, with no debounce — the same bet ⌘P makes. This is the number that
/// bet rests on, measured rather than assumed.
///
/// # The measurement, release build, M-series, 112 840 pages
///
/// ```text
///           d:  56.27 ms, 60 hits    one character — below the trigram floor, so every row
///          de:  61.96 ms, 60 hits    two — the same, and the last keystroke that costs this
///         dep:   6.11 ms, 60 hits    three — the index takes over, and stays over
///        depl:   6.43 ms, 60 hits
///      deploy:   6.98 ms, 60 hits
/// log-group/2:   1.26 ms, 60 hits    a distinctive query barely touches the table
///         com:  25.15 ms, 60 hits    a needle three rows in five contain
///        zzqq:  65.38 ms,  0 hits    nothing literal: every row, for the subsequence tier
/// ```
///
/// The line that matters is the third: from the third character on, a query
/// costs single-digit milliseconds against 112 840 rows, where the round-1
/// linear scan extrapolated to roughly 100 ms a keystroke — and round 1 only
/// ever looked at the newest 2 000 rows to get its 2 ms.
///
/// Two shapes still pay for the whole table, both by construction and both
/// documented rather than hidden:
///
/// * **One or two characters.** FTS5's trigram tokenizer indexes
///   three-character windows, so there is no index below three and every row is
///   scored. It is the first two keystrokes only, and it is the price of the
///   answer being complete rather than the newest fourteen days of it.
/// * **A needle nothing contains.** `Ranking` comes back empty, and the scan
///   that follows is what lets `mxp` still find `max-pane`. It fires exactly
///   when the answer is "nothing matched", which is the one case where nobody
///   is reading a list.
///
/// The reason those are 60 ms rather than 150 is in `Haystack`: the index keeps
/// the text lowercase and scheme-stripped, so a row is scored where it lies in
/// the statement with nothing allocated per candidate.
///
/// Gated on `MAXPANE_BENCH`: building the corpus is ~19 s, far the largest cost
/// in the suite, and the number only means anything in release.
/// `./scripts/test.sh bench` runs it.
#[test]
fn cost_of_a_keystroke() {
    if std::env::var_os("MAXPANE_BENCH").is_none() {
        // Loud rather than silent: a suite that quietly does less than it says
        // is how a gate turns into a hole.
        println!("SKIPPED cost_of_a_keystroke — set MAXPANE_BENCH=1, or ./scripts/test.sh bench");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let ledger = Ledger::open(Some(Path::new(&path))).unwrap();
    // Synthetic, not his: the corpus is the right *size* and shape, and nobody
    // has to take a copy of a man's browsing to run a test. Titles and paths
    // are drawn from small word lists rather than sharing one sentence — a
    // corpus where every row says "rust" makes every query a worst case and
    // measures the fallback instead of the index. A redirect source on a fifth
    // of it, because aliases are in the same index.
    const HOSTS: [&str; 12] = [
        "github.com", "console.aws.amazon.com", "docs.rs", "news.ycombinator.com",
        "grafana.internal", "mail.google.com", "en.wikipedia.org", "localhost:3000",
        "developer.mozilla.org", "sqlite.org", "youtube.com", "linear.app",
    ];
    const WORDS: [&str; 16] = [
        "deploy", "metrics", "issues", "pull", "log-group", "dashboard", "inbox",
        "article", "session", "release", "schema", "migration", "profile", "queue",
        "worker", "report",
    ];
    for i in 0..HIS_CORPUS as usize {
        let host = HOSTS[i * 7 % HOSTS.len()];
        let a = WORDS[i * 3 % WORDS.len()];
        let b = WORDS[i * 11 % WORDS.len()];
        let url = format!("https://{host}/{a}/{i}/{b}");
        let title = format!("{a} {b} — {host} #{i}");
        ledger.record_visit(&url, Some(&title), 1).unwrap();
        if i % 5 == 0 {
            ledger.note_visit_alias(&format!("https://s{i}.example"), &url).unwrap();
        }
    }
    drop(ledger);
    let core = Core::open(path).unwrap();
    assert_eq!(core.history_count().unwrap(), HIS_CORPUS);
    assert_eq!(core.history_searchable_count().unwrap(), HIS_CORPUS, "the footer would be lying");

    let mut typed = Vec::new();
    for query in ["d", "de", "dep", "depl", "deploy", "log-group/2", "com", "zzqq"] {
        let start = std::time::Instant::now();
        let hits = core.history(query.to_string(), 60).unwrap();
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        println!("{query:>9}: {ms:6.2} ms, {} hits", hits.len());
        // `zzqq` matches nothing at all and takes the whole-table fallback on
        // purpose; it is measured and printed, not held to the typing budget.
        if !hits.is_empty() {
            typed.push(ms);
        }
    }
    let worst = typed.iter().cloned().fold(0.0f64, f64::max);
    // Generous against the ~10 ms measured in release, because the point is not
    // to pin a number to a machine: it is to catch the index falling out of the
    // plan — a query planner that stops using it, a per-row round trip, a scan
    // that came back. Any of those would be a hundred times this, not twice.
    assert!(worst < 300.0, "a keystroke cost {worst:.1} ms over {HIS_CORPUS} pages");
}

#[test]
fn a_page_visited_while_the_palette_is_open_is_in_the_next_query() {
    // The candidate rows are held between writes, so the bug to guard against
    // is a stale one: browse somewhere, search for it, and it is not there.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://first.example".into(), Some("First".into()), Vec::new())
        .unwrap();
    assert_eq!(core.history("first".into(), 10).unwrap().len(), 1);

    core.record_visit(pane.clone(), "https://second.example".into(), Some("Second".into()), Vec::new())
        .unwrap();
    assert_eq!(core.history("second".into(), 10).unwrap().len(), 1, "the cache went stale");

    core.name_visit("https://second.example".into(), "Renamed".into()).unwrap();
    assert_eq!(core.history("renamed".into(), 10).unwrap().len(), 1, "a rename went unseen");

    core.forget_visit("https://second.example".into()).unwrap();
    assert!(core.history("renamed".into(), 10).unwrap().is_empty(), "a forgotten page lingered");

    core.clear_history().unwrap();
    assert!(core.history("first".into(), 10).unwrap().is_empty(), "a cleared page lingered");
}

// ---- round 3: a view with room in it ----------------------------------------

#[test]
fn paging_continues_the_list_rather_than_restarting_it() {
    // Round 2 left the reader able to browse exactly 60 rows: ↓ 75 times and
    // the list stopped while the footer counted thousands. Paging is only a fix
    // if page two is the *rest* of page one — a second query that re-ranks or
    // re-orders would show row 60 twice and row 61 never.
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let core = Core::open(db(&dir)).unwrap();
    drop(ledger);
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    for i in 0..150 {
        ledger.record_visit(&format!("https://example.com/{i:03}"), None, 1_700_000_000_000 + i)
            .unwrap();
    }
    drop(ledger);

    let whole = urls(&core.history_page(String::new(), 0, 150).unwrap());
    assert_eq!(whole.len(), 150, "the cap is gone; the window should see all of it");
    let first = urls(&core.history_page(String::new(), 0, 60).unwrap());
    let second = urls(&core.history_page(String::new(), 60, 60).unwrap());
    let third = urls(&core.history_page(String::new(), 120, 60).unwrap());
    assert_eq!(third.len(), 30, "the last page should be short, not empty");
    assert_eq!([first, second, third].concat(), whole, "paging showed a different list");
}

#[test]
fn a_search_pages_through_one_ranking() {
    // The same rule for a query: page two is the next-best answers, not the
    // best answers of a fresh query. If `offset` were applied before the
    // ranking, row 11 would be a row the ranker had already rejected.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    for i in 0..40 {
        core.record_visit(pane.clone(), format!("https://grafana.example/d/{i:02}"), None, Vec::new())
            .unwrap();
    }
    let whole = urls(&core.history_page("grafana".into(), 0, 40).unwrap());
    let head = urls(&core.history_page("grafana".into(), 0, 10).unwrap());
    let tail = urls(&core.history_page("grafana".into(), 10, 10).unwrap());
    assert_eq!(head, whole[..10], "the first page is not the top of the ranking");
    assert_eq!(tail, whole[10..20], "the second page re-ranked instead of continuing");
}

#[test]
fn the_browse_list_is_ordered_by_when_it_happened() {
    // A day header is only true if every row under it is from that day, which
    // holds only when the list is ordered by the field the day is read from.
    // The clock moving backwards is the one case where `seq` and the calendar
    // disagree — and it is the case `seq` exists for, so both orderings stay.
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let now = 1_700_000_000_000i64;
    let day = 24 * 60 * 60 * 1_000;
    ledger.record_visit("https://example.com/today", None, now).unwrap();
    // Recorded after it, but it happened a day earlier — an NTP correction, or
    // a page imported from a profile that was open at the time.
    ledger.record_visit("https://example.com/yesterday", None, now - day).unwrap();
    ledger.record_visit("https://example.com/also-today", None, now + 1).unwrap();

    assert_eq!(
        ledger.history_by_date(0, 10).unwrap().iter().map(|e| e.url.clone()).collect::<Vec<_>>(),
        vec![
            "https://example.com/also-today".to_string(),
            "https://example.com/today".to_string(),
            "https://example.com/yesterday".to_string(),
        ],
        "yesterday was listed between two of today's pages"
    );
    // The palette is untouched: it still answers in the order things were
    // recorded, which is what a tied clock needs.
    assert_eq!(
        ledger.history_newest(10).unwrap()[0].url,
        "https://example.com/also-today"
    );
}

#[test]
fn a_day_is_counted_between_the_boundaries_the_caller_passes() {
    // The count on a day header. The boundaries come from the reader's
    // calendar, so this crate never has to know what a day is.
    let core = Core::open_in_memory().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let start = 1_700_000_000_000i64;
    let day = 24 * 60 * 60 * 1_000;
    for i in 0..5 {
        ledger.record_visit(&format!("https://example.com/a{i}"), None, start + i).unwrap();
    }
    for i in 0..3 {
        ledger.record_visit(&format!("https://example.com/b{i}"), None, start + day + i).unwrap();
    }
    assert_eq!(ledger.history_count_between(start, start + day).unwrap(), 5);
    assert_eq!(ledger.history_count_between(start + day, start + 2 * day).unwrap(), 3);
    // Half-open, so two adjacent days never count the same page twice.
    assert_eq!(ledger.history_count_between(start, start + 2 * day).unwrap(), 8);
    assert_eq!(core.history_day_count(start, start + day).unwrap(), 0);
}

#[test]
fn clearing_a_range_takes_the_search_index_with_it() {
    // `forget_visit` learned this the hard way: a row deleted without its index
    // entry leaves a search that finds a page which is no longer there. A range
    // delete has the same edge and more rows to get it wrong on.
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let now = 1_700_000_000_000i64;
    let hour = 60 * 60 * 1_000;
    ledger.record_visit("https://keepme.example/old", Some("Old"), now - 5 * hour).unwrap();
    ledger.record_visit("https://forgetme.example/recent", Some("Recent"), now - 10).unwrap();

    assert_eq!(ledger.clear_history_since(now - hour).unwrap(), 1);
    assert_eq!(ledger.history_count().unwrap(), 1, "the wrong side of the cutoff went");
    assert!(
        ledger.history_search("forgetme", 0, 10).unwrap().is_empty(),
        "a cleared page was still findable, which is worse than not clearing it"
    );
    assert_eq!(ledger.history_search("keepme", 0, 10).unwrap().len(), 1, "the index lost a survivor");

    // A cutoff of 0 is everything, and it is still one statement rather than a
    // different code path.
    assert_eq!(ledger.clear_history_since(0).unwrap(), 1);
    assert_eq!(ledger.history_count().unwrap(), 0);
}
