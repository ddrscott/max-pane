//! Browsing history: recorded on the first visit, found after a restart, and
//! with no hole where a redirect was.
//!
//! The kill criterion registered for this piece is "a page visited in a pane is
//! findable by title and by URL after a restart, and the record has no hole
//! where a redirect was", so most of what is below is that sentence taken
//! literally — including the restart, which is done the way `durability.rs`
//! does it: drop the `Core` with no shutdown path and reopen the file.

use laned_core::history::{HISTORY_MAX_AGE_MS, HISTORY_MAX_ROWS};
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
            None,
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
        Some("https://example.com/".into()),
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
        Some("https://example.com/".into()),
    )
    .unwrap();
    let all = core.history(String::new(), 50).unwrap();
    assert_eq!(urls(&all), vec!["https://www.example.com/en"]);
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
            Some("https://example.com".into()),
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
    core.record_visit(pane.clone(), "https://example.com/a".into(), Some("A".into()), None).unwrap();
    // A different page in between, so the coalescing window is not what is
    // being measured here.
    core.record_visit(pane.clone(), "https://example.com/b".into(), Some("B".into()), None).unwrap();
    core.record_visit(pane, "https://example.com/a".into(), Some("A".into()), None).unwrap();

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
        core.record_visit(pane.clone(), "https://example.com/a".into(), Some("A".into()), None).unwrap();
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
    core.record_visit(a, "https://example.com/a".into(), None, None).unwrap();
    core.record_visit(b, "https://example.com/a".into(), None, None).unwrap();
    assert_eq!(core.history(String::new(), 10).unwrap()[0].visit_count, 2);
}

#[test]
fn a_late_title_names_the_page_without_counting_a_visit() {
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    // `WKWebView.title` is usually still empty when the navigation finishes.
    core.record_visit(pane, "https://example.com/a".into(), None, None).unwrap();
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
    core.record_visit(a, "https://example.com/a".into(), Some("Named".into()), None).unwrap();
    core.record_visit(b, "https://example.com/a".into(), None, None).unwrap();
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
        core.record_visit(pane.clone(), url.into(), None, None).unwrap();
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
                None,
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
        core.record_visit(pane.clone(), format!("https://example.com/{i}"), None, None).unwrap();
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
        ledger.history_candidates(50).unwrap().into_iter().map(|c| c.url).collect();
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
    core.record_visit(pane.clone(), "https://docs.example/rust".into(), None, None).unwrap();
    // Visited later, and it does contain r…u…s…t as a subsequence.
    core.record_visit(pane, "https://n.example/rough-untidy-storage-thing".into(), None, None)
        .unwrap();
    assert_eq!(core.history("rust".into(), 10).unwrap()[0].url, "https://docs.example/rust");
}

// ---- pruning ----------------------------------------------------------------

#[test]
fn nothing_older_than_the_age_cap_survives() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    let now = 1_700_000_000_000i64;
    ledger.record_visit("https://old.example", Some("Old"), now - HISTORY_MAX_AGE_MS - 1).unwrap();
    ledger.record_visit("https://new.example", Some("New"), now).unwrap();

    assert_eq!(ledger.prune_history(HISTORY_MAX_ROWS, now - HISTORY_MAX_AGE_MS).unwrap(), 1);
    let left: Vec<String> =
        ledger.history_candidates(50).unwrap().into_iter().map(|c| c.url).collect();
    assert_eq!(left, vec!["https://new.example"]);
}

#[test]
fn the_row_cap_keeps_the_newest() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = Ledger::open(Some(Path::new(&db(&dir)))).unwrap();
    for i in 0..20 {
        ledger.record_visit(&format!("https://example.com/{i}"), None, 1_700_000_000_000).unwrap();
    }
    assert_eq!(ledger.prune_history(5, 0).unwrap(), 15);
    let left: Vec<String> =
        ledger.history_candidates(50).unwrap().into_iter().map(|c| c.url).collect();
    assert_eq!(
        left,
        (15..20).rev().map(|i| format!("https://example.com/{i}")).collect::<Vec<_>>()
    );
}

#[test]
fn pruning_takes_the_aliases_with_it() {
    // Otherwise the alias table is the thing that grows forever, and a search
    // matches a redirect source whose page is long gone.
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    {
        let ledger = Ledger::open(Some(Path::new(&path))).unwrap();
        ledger.record_visit("https://www.example.com/en", Some("Example"), 1_000).unwrap();
        ledger.note_visit_alias("https://example.com", "https://www.example.com/en").unwrap();
        assert_eq!(alias_count(Path::new(&path)), 1);
        assert_eq!(ledger.prune_history(0, 0).unwrap(), 1);
    }
    assert_eq!(alias_count(Path::new(&path)), 0, "an alias outlived the page it pointed at");
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
        Some("https://example.com".into()),
    )
    .unwrap();
    core.record_visit(pane, "https://keep.example".into(), Some("Keep".into()), None).unwrap();

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
    core.record_visit(pane, "https://example.com/a".into(), Some("A".into()), None).unwrap();
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
    core.record_visit(pane, "https://example.com/new".into(), Some("New".into()), None).unwrap();
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
        core.record_visit(pane, "https://example.com/x".into(), None, None).unwrap();
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

/// A keystroke in the history palette is a SQLite read plus a scan, on the main
/// thread, with no debounce — the same bet ⌘P makes. This is the number that
/// bet rests on, measured rather than assumed.
///
/// `cargo test --release --test history -- --nocapture cost_of_a_keystroke`
#[test]
fn cost_of_a_keystroke() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let ledger = Ledger::open(Some(Path::new(&path))).unwrap();
    // A full ledger, with a redirect source on a fifth of it.
    for i in 0..HISTORY_MAX_ROWS {
        let url = format!("https://host{}.example/section/{i}/page-about-something", i % 400);
        ledger.record_visit(&url, Some(&format!("Page {i} — something about rust and sqlite")), 1)
            .unwrap();
        if i % 5 == 0 {
            ledger.note_visit_alias(&format!("https://short{i}.example"), &url).unwrap();
        }
    }
    let core = Core::open(path).unwrap();
    assert_eq!(core.history_count().unwrap(), HISTORY_MAX_ROWS);

    let mut samples = Vec::new();
    // The worst case is a query that matches nearly everything, because every
    // survivor is scored and sorted rather than rejected on the first char.
    for query in ["r", "ru", "rus", "rust", "rust sql", "page 4", "zzqq"] {
        let start = std::time::Instant::now();
        let hits = core.history(query.to_string(), 60).unwrap();
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        samples.push(ms);
        println!("{query:>9}: {ms:6.2} ms, {} hits", hits.len());
    }
    let worst = samples.iter().cloned().fold(0.0f64, f64::max);
    // Generous, because this runs in debug in the normal suite. The point is to
    // catch a change that makes it linear in something it should not be — a
    // per-row query, or a scan that stopped being capped.
    assert!(worst < 250.0, "a keystroke cost {worst:.1} ms over {HISTORY_MAX_ROWS} pages");
}

#[test]
fn a_page_visited_while_the_palette_is_open_is_in_the_next_query() {
    // The candidate rows are held between writes, so the bug to guard against
    // is a stale one: browse somewhere, search for it, and it is not there.
    let core = Core::open_in_memory().unwrap();
    let pane = web_pane(&core, "https://example.com");
    core.record_visit(pane.clone(), "https://first.example".into(), Some("First".into()), None)
        .unwrap();
    assert_eq!(core.history("first".into(), 10).unwrap().len(), 1);

    core.record_visit(pane.clone(), "https://second.example".into(), Some("Second".into()), None)
        .unwrap();
    assert_eq!(core.history("second".into(), 10).unwrap().len(), 1, "the cache went stale");

    core.name_visit("https://second.example".into(), "Renamed".into()).unwrap();
    assert_eq!(core.history("renamed".into(), 10).unwrap().len(), 1, "a rename went unseen");

    core.forget_visit("https://second.example".into()).unwrap();
    assert!(core.history("renamed".into(), 10).unwrap().is_empty(), "a forgotten page lingered");

    core.clear_history().unwrap();
    assert!(core.history("first".into(), 10).unwrap().is_empty(), "a cleared page lingered");
}
