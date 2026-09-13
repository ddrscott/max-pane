//! Importing another browser's history.
//!
//! Four things can go wrong here and none of them fails loudly, so each has a
//! test that pins it to a number rather than to a shape:
//!
//! 1. **The epoch.** Three families, three zeros. A wrong one yields history
//!    dated 1601 or 2040 — a plausible-looking table, not an error. Every
//!    fixture below is stamped with a raw value taken out of a real profile and
//!    asserted against the wall-clock date it means.
//! 2. **The order.** `seq` is a counter, and 112 840 imported pages taking the
//!    top of it would bury everything the user did today. See
//!    `the_mru_still_belongs_to_today`.
//! 3. **Doing it twice.** Every field of the merge is a `min` or a `max`, which
//!    is the whole reason there is no side table of what has been imported
//!    before. `importing_twice_changes_nothing` is what holds that claim up.
//! 4. **The way back.** `Replace` is one click and drops everything; the backup
//!    it takes first is the only undo, so its existence is a test.

use laned_core::import::{self, HistorySourceKind, ImportMode};
use laned_core::model::*;
use laned_core::Core;
use rusqlite::Connection;
use std::path::{Path, PathBuf};

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// A visit in Max Pane itself, so there is something for an import to be
/// ranked against.
fn visit(core: &Core, url: &str, title: &str) {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some(url.to_string()), None)
        .unwrap();
    let pane = st.lanes.last().unwrap().panes[0].id.clone();
    core.record_visit(pane, url.to_string(), Some(title.to_string()), vec![]).unwrap();
}

// ---- fixtures: one real file per family ------------------------------------

/// Epoch ms for a date, so a fixture can state what it means.
///
/// 2024-02-22T09:27:37Z is the first visit in the owner's Vivaldi profile, and
/// every Chromium fixture below is built from the raw µs value that sits in his
/// `visits` table for it.
const VIVALDI_FIRST_US: i64 = 13_353_094_057_202_910;
const VIVALDI_FIRST_MS: i64 = 1_708_620_457_202;

/// `history_visits.visit_time` for a real Safari row, and what it means.
const SAFARI_REAL_S: f64 = 782_798_843.440889;
const SAFARI_REAL_MS: i64 = 1_761_106_043_440;

fn chromium_source(dir: &Path, rows: &[(&str, Option<&str>, i64, i64, i64, i64)]) -> PathBuf {
    let path = dir.join("History");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
                           visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
                           last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
         CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL,
                             visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL);",
    )
    .unwrap();
    for (i, (url, title, count, last_us, first_us, hidden)) in rows.iter().enumerate() {
        let id = i as i64 + 1;
        conn.execute(
            "INSERT INTO urls (id, url, title, visit_count, last_visit_time, hidden)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![id, url, title, count, last_us, hidden],
        )
        .unwrap();
        if *first_us > 0 {
            conn.execute(
                "INSERT INTO visits (url, visit_time) VALUES (?1, ?2)",
                rusqlite::params![id, first_us],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO visits (url, visit_time) VALUES (?1, ?2)",
                rusqlite::params![id, last_us],
            )
            .unwrap();
        }
    }
    path
}

fn safari_source(dir: &Path, rows: &[(&str, Option<&str>, i64, f64, f64)]) -> PathBuf {
    let path = dir.join("History.db");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE,
                                     visit_count INTEGER NOT NULL);
         CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL,
                                      visit_time REAL NOT NULL, title TEXT NULL);",
    )
    .unwrap();
    for (i, (url, title, count, first_s, last_s)) in rows.iter().enumerate() {
        let id = i as i64 + 1;
        conn.execute(
            "INSERT INTO history_items (id, url, visit_count) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, url, count],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?1, ?2, NULL)",
            rusqlite::params![id, first_s],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?1, ?2, ?3)",
            rusqlite::params![id, last_s, title],
        )
        .unwrap();
    }
    path
}

fn firefox_source(dir: &Path, rows: &[(&str, Option<&str>, i64, i64, i64)]) -> PathBuf {
    let path = dir.join("places.sqlite");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                                  visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL,
                                  last_visit_date INTEGER);
         CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);",
    )
    .unwrap();
    for (i, (url, title, count, first_us, last_us)) in rows.iter().enumerate() {
        let id = i as i64 + 1;
        conn.execute(
            "INSERT INTO moz_places (id, url, title, visit_count, last_visit_date) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![id, url, title, count, last_us],
        )
        .unwrap();
        for t in [first_us, last_us] {
            conn.execute(
                "INSERT INTO moz_historyvisits (place_id, visit_date) VALUES (?1, ?2)",
                rusqlite::params![id, t],
            )
            .unwrap();
        }
    }
    path
}

fn source(path: &Path, kind: HistorySourceKind) -> import::HistorySource {
    import::HistorySource {
        name: "Fixture".into(),
        profile: None,
        kind,
        path: path.to_string_lossy().into_owned(),
        // The fixtures are history files with no bookmarks beside them; the
        // bookmark readers have their own fixtures in `tests/bookmarks.rs`.
        bookmarks_path: None,
        size_bytes: std::fs::metadata(path).map(|m| m.len()).unwrap_or(0),
        blocked: None,
    }
}

// ---- the epochs ------------------------------------------------------------

#[test]
fn a_chromium_timestamp_lands_in_2024_and_not_in_1601() {
    let dir = tempfile::tempdir().unwrap();
    let src = chromium_source(
        dir.path(),
        &[("https://example.com/a", Some("A"), 3, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)],
    );
    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    let rows = core.history(String::new(), 10).unwrap();
    assert_eq!(rows[0].first_visit_at, VIVALDI_FIRST_MS);
    assert_eq!(rows[0].last_visit_at, VIVALDI_FIRST_MS);
}

#[test]
fn a_safari_timestamp_is_seconds_since_2001() {
    let dir = tempfile::tempdir().unwrap();
    let src = safari_source(
        dir.path(),
        &[("https://example.com/s", Some("S"), 2, SAFARI_REAL_S, SAFARI_REAL_S)],
    );
    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Safari), ImportMode::Merge)
        .unwrap();
    let rows = core.history(String::new(), 10).unwrap();
    assert_eq!(rows[0].last_visit_at, SAFARI_REAL_MS);
    // The title lives on the newest visit, not on the page.
    assert_eq!(rows[0].title.as_deref(), Some("S"));
}

#[test]
fn a_firefox_timestamp_is_microseconds_since_1970() {
    let dir = tempfile::tempdir().unwrap();
    let src = firefox_source(
        dir.path(),
        &[("https://example.com/f", Some("F"), 1, 1_700_000_000_000_000, 1_700_000_123_000_000)],
    );
    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Firefox), ImportMode::Merge)
        .unwrap();
    let rows = core.history(String::new(), 10).unwrap();
    assert_eq!(rows[0].first_visit_at, 1_700_000_000_000);
    assert_eq!(rows[0].last_visit_at, 1_700_000_123_000);
}

// ---- the order -------------------------------------------------------------

/// The single thing that decides whether this feature is worth having.
#[test]
fn the_mru_still_belongs_to_today() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://today.example/one", "One");
    visit(&core, "https://today.example/two", "Two");

    // Two years of someone else's browsing, every row older than both.
    let old: Vec<(String, i64)> = (0..500)
        .map(|i| (format!("https://old.example/{i}"), VIVALDI_FIRST_US + i * 1_000_000))
        .collect();
    let rows: Vec<(&str, Option<&str>, i64, i64, i64, i64)> = old
        .iter()
        .map(|(u, t)| (u.as_str(), Some("Old"), 1i64, *t, *t, 0i64))
        .collect();
    let src = chromium_source(dir.path(), &rows);
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    let mru = core.history(String::new(), 5).unwrap();
    assert_eq!(
        mru.iter().map(|e| e.url.clone()).take(2).collect::<Vec<_>>(),
        vec!["https://today.example/two", "https://today.example/one"],
        "500 pages from 2024 took the top of the MRU"
    );
}

/// Interleaved, not stacked at either end: a page from the middle of the
/// imported range sits between two local visits that straddle it.
#[test]
fn an_imported_page_sits_where_its_clock_says() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://local.example/old", "Local old");
    let between = laned_core::now_ms();
    std::thread::sleep(std::time::Duration::from_millis(5));
    visit(&core, "https://local.example/new", "Local new");

    // Chromium µs for the instant between the two local visits.
    let us = (between + 2) * 1000 + Epoch_WINDOWS_US;
    let src = chromium_source(dir.path(), &[("https://mid.example/", Some("Mid"), 1, us, us, 0)]);
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    let urls: Vec<String> = core.history(String::new(), 10).unwrap().iter().map(|e| e.url.clone()).collect();
    assert_eq!(
        urls,
        vec!["https://local.example/new", "https://mid.example", "https://local.example/old"]
    );
}

/// 11 644 473 600 s, in µs. Spelled out here so the fixture above reads as
/// arithmetic rather than as a magic number.
#[allow(non_upper_case_globals)]
const Epoch_WINDOWS_US: i64 = 11_644_473_600_000_000;

/// A re-`seq` may not reorder what was already there.
#[test]
fn the_pages_already_here_keep_their_order() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    for i in 0..8 {
        visit(&core, &format!("https://local.example/{i}"), "L");
    }
    let before: Vec<String> = core.history(String::new(), 20).unwrap().iter().map(|e| e.url.clone()).collect();

    let src = chromium_source(
        dir.path(),
        &[("https://old.example/", Some("O"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)],
    );
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    let after: Vec<String> = core
        .history(String::new(), 20)
        .unwrap()
        .iter()
        .map(|e| e.url.clone())
        .filter(|u| u.contains("local.example"))
        .collect();
    assert_eq!(before, after);
}

// ---- merge -----------------------------------------------------------------

#[test]
fn merge_keeps_the_earliest_first_visit_and_the_latest_last() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://both.example/", "Ours");
    let ours = core.history(String::new(), 1).unwrap()[0].clone();

    // Older first visit, older last visit: only the first should move.
    let older_us = (ours.first_visit_at - 100_000) * 1000 + Epoch_WINDOWS_US;
    let src = chromium_source(
        dir.path(),
        &[("https://both.example/", Some("Theirs"), 40, older_us, older_us, 0)],
    );
    let outcome = core
        .import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    assert_eq!((outcome.inserted, outcome.updated), (0, 1));
    let row = core.history(String::new(), 1).unwrap()[0].clone();
    assert_eq!(row.first_visit_at, ours.first_visit_at - 100_000);
    assert_eq!(row.last_visit_at, ours.last_visit_at);
    // Greatest, not sum: see `import::fold`.
    assert_eq!(row.visit_count, 40);
    // A title is only replaced by a newer title, and theirs is older.
    assert_eq!(row.title.as_deref(), Some("Ours"));
    assert_eq!(core.history_count().unwrap(), 1);
}

#[test]
fn a_page_we_have_never_named_takes_the_imported_name() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some("https://x.example/".into()), None)
        .unwrap();
    let pane = st.lanes.last().unwrap().panes[0].id.clone();
    core.record_visit(pane, "https://x.example/".into(), None, vec![]).unwrap();

    let src = chromium_source(
        dir.path(),
        &[("https://x.example/", Some("Named by them"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)],
    );
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    assert_eq!(
        core.history(String::new(), 1).unwrap()[0].title.as_deref(),
        Some("Named by them")
    );
}

#[test]
fn importing_twice_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://overlap.example/", "Ours");
    let src = chromium_source(
        dir.path(),
        &[
            ("https://overlap.example/", Some("Theirs"), 9, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            ("https://new.example/", Some("New"), 4, VIVALDI_FIRST_US + 5, VIVALDI_FIRST_US, 0),
        ],
    );
    let s = source(&src, HistorySourceKind::Chromium);

    core.import_history(s.clone(), ImportMode::Merge).unwrap();
    let once = core.history(String::new(), 50).unwrap();
    let second = core.import_history(s, ImportMode::Merge).unwrap();
    let twice = core.history(String::new(), 50).unwrap();

    assert_eq!(once, twice, "a second import of the same profile moved something");
    assert_eq!(second.inserted, 0);
    assert_eq!(core.history_count().unwrap(), 2);
}

// ---- replace ---------------------------------------------------------------

#[test]
fn replace_drops_what_was_there_and_leaves_a_way_back() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://mine.example/", "Mine");
    visit(&core, "https://also-mine.example/", "Also");

    let src = chromium_source(
        dir.path(),
        &[("https://theirs.example/", Some("Theirs"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)],
    );
    let outcome = core
        .import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Replace)
        .unwrap();

    assert_eq!(outcome.discarded, 2);
    assert_eq!(outcome.inserted, 1);
    let urls: Vec<String> = core.history(String::new(), 10).unwrap().iter().map(|e| e.url.clone()).collect();
    assert_eq!(urls, vec!["https://theirs.example"]);

    let backup = PathBuf::from(outcome.backup_path.expect("replace took no backup"));
    assert!(backup.is_file(), "the only undo is not on disk");
    let old = Core::open(backup.to_string_lossy().into_owned()).unwrap();
    assert_eq!(old.history_count().unwrap(), 2, "the backup does not hold the old history");
}

/// The backup is of the whole ledger, not of history: the lanes have to come
/// back with it or it is not a way back from anything.
#[test]
fn the_backup_holds_the_strip_as_well() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://mine.example/", "Mine");
    let lanes = core.state().unwrap().lanes.len();

    let src = chromium_source(dir.path(), &[("https://t.example/", None, 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)]);
    let outcome = core
        .import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Replace)
        .unwrap();
    let old = Core::open(outcome.backup_path.unwrap()).unwrap();
    assert_eq!(old.state().unwrap().lanes.len(), lanes);
}

// ---- what does not come in -------------------------------------------------

#[test]
fn a_url_that_is_not_a_page_is_skipped_and_counted() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let src = chromium_source(
        dir.path(),
        &[
            ("https://real.example/", Some("Real"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            ("chrome-extension://abcdef/popup.html", Some("Ext"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            ("mailto:someone@example.com", None, 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            // Chromium's own "never offer this back": an OAuth bounce.
            ("https://hidden.example/consent", None, 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 1),
            // Typed into the omnibox and never loaded.
            ("https://never.example/", None, 0, 0, 0, 0),
        ],
    );
    let plan = core
        .plan_history_import(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    assert_eq!(plan.source_pages, 1);
    assert_eq!(plan.skipped, 4, "the rows filtered in SQL still have to be owned up to");
    assert_eq!(core.history_count().unwrap(), 0, "a dry run wrote something");
}

/// Two source rows that normalize to one page are one row, folded, before the
/// ledger ever sees them.
#[test]
fn two_spellings_of_one_page_arrive_as_one() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let src = chromium_source(
        dir.path(),
        &[
            ("https://Example.COM:443/x", Some("Early"), 2, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            ("https://example.com/x", Some("Late"), 7, VIVALDI_FIRST_US + 60_000_000, VIVALDI_FIRST_US + 60_000_000, 0),
        ],
    );
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    let rows = core.history(String::new(), 10).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].url, "https://example.com/x");
    assert_eq!(rows[0].first_visit_at, VIVALDI_FIRST_MS);
    assert_eq!(rows[0].visit_count, 7);
    assert_eq!(rows[0].title.as_deref(), Some("Late"));
}

// ---- searching what came in ------------------------------------------------

#[test]
fn an_imported_page_is_findable_by_url_and_by_title() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://local.example/rust", "Local rust page");
    let src = chromium_source(
        dir.path(),
        &[(
            "https://doc.rust-lang.org/std/vec/struct.Vec.html",
            Some("Vec in std::vec - Rust"),
            12,
            VIVALDI_FIRST_US,
            VIVALDI_FIRST_US,
            0,
        )],
    );
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    let by_url = core.history("rust-lang".into(), 10).unwrap();
    assert!(by_url.iter().any(|e| e.url.contains("struct.Vec.html")), "not in the index");
    let by_title = core.history("std::vec".into(), 10).unwrap();
    assert!(by_title.iter().any(|e| e.url.contains("struct.Vec.html")));
    // The local page is still reachable, which is what proves the index was
    // rebuilt rather than replaced.
    assert!(core.history("Local rust".into(), 10).unwrap().iter().any(|e| e.url.contains("local.example")));
}

// ---- detection -------------------------------------------------------------

#[test]
fn the_wizard_offers_what_is_installed_and_nothing_else() {
    let home = tempfile::tempdir().unwrap();
    let vivaldi = home.path().join("Library/Application Support/Vivaldi/Default");
    std::fs::create_dir_all(&vivaldi).unwrap();
    std::fs::write(vivaldi.join("History"), b"").unwrap();
    let profile2 = home.path().join("Library/Application Support/Vivaldi/Profile 2");
    std::fs::create_dir_all(&profile2).unwrap();
    std::fs::write(profile2.join("History"), b"").unwrap();
    let ff = home.path().join("Library/Application Support/Firefox/Profiles/abc.default-release");
    std::fs::create_dir_all(&ff).unwrap();
    std::fs::write(ff.join("places.sqlite"), b"").unwrap();
    // A browser that is installed but has never been opened: a directory with
    // no history file in it is not a source.
    std::fs::create_dir_all(home.path().join("Library/Application Support/Chromium")).unwrap();

    let found = import::detect_in(home.path());
    let names: Vec<(String, Option<String>)> =
        found.iter().map(|s| (s.name.clone(), s.profile.clone())).collect();
    assert_eq!(
        names,
        vec![
            ("Vivaldi".to_string(), Some("Default".to_string())),
            ("Vivaldi".to_string(), Some("Profile 2".to_string())),
            ("Firefox".to_string(), Some("abc.default-release".to_string())),
        ]
    );
    assert!(found.iter().all(|s| s.blocked.is_none()));
}

/// A file macOS will not let us open is offered anyway, with the sentence that
/// says why — because SQLite reports TCC as "unable to open database file",
/// which in a dialog is indistinguishable from a corrupt profile.
#[test]
fn a_source_we_cannot_read_says_so_rather_than_looking_broken() {
    let home = tempfile::tempdir().unwrap();
    let safari = home.path().join("Library/Safari");
    std::fs::create_dir_all(&safari).unwrap();
    let file = safari.join("History.db");
    std::fs::write(&file, b"").unwrap();
    let mut perms = std::fs::metadata(&file).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o000);
    std::fs::set_permissions(&file, perms).unwrap();

    let found = import::detect_in(home.path());
    let safari_row = found.iter().find(|s| s.name == "Safari").unwrap();
    let why = safari_row.blocked.as_deref().unwrap_or_default();
    assert!(why.contains("Full Disk Access"), "unhelpful: {why}");

    // And it refuses rather than half-importing.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    assert!(core.import_history(safari_row.clone(), ImportMode::Merge).is_err());
}

// ---- the snapshot ----------------------------------------------------------

/// 642 MB of someone's browsing history may not outlive the import that needed
/// it, and may not be somewhere it will be forgotten.
#[test]
fn the_snapshot_is_beside_the_ledger_and_is_gone_afterwards() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = PathBuf::from(db(&dir));
    let src = chromium_source(dir.path(), &[("https://a.example/", None, 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)]);

    let snapshot_dir = {
        let snap = import::Snapshot::take(&src, Some(&ledger)).unwrap();
        snap.open().unwrap();
        dir.path().join("import-snapshot")
    };
    assert!(!snapshot_dir.exists(), "a copy of a browsing history was left behind");

    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    assert!(!snapshot_dir.exists());
}

/// The case that actually happens: the browser is open.
///
/// Chromium holds `PRAGMA locking_mode = EXCLUSIVE` on `History` for the life of
/// the process, so SQLite's backup API cannot read a single page of it — and
/// `Backup::run_to_completion` answers a `SQLITE_BUSY` by sleeping and trying
/// again, for ever. The first measurement run against the owner's live Vivaldi
/// hung on exactly that and never printed a line. This holds the same lock, so
/// the fallback and its bound are both exercised rather than assumed.
#[test]
fn a_profile_whose_browser_is_running_still_imports() {
    let dir = tempfile::tempdir().unwrap();
    let src = chromium_source(
        dir.path(),
        &[("https://locked.example/", Some("Locked"), 4, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)],
    );

    // The browser, still open.
    let browser = Connection::open(&src).unwrap();
    browser.pragma_update(None, "locking_mode", "exclusive").unwrap();
    browser
        .execute("INSERT INTO urls (id, url, title, visit_count, last_visit_time, hidden)
                  VALUES (99, 'https://while-open.example/', 'Open', 1, ?1, 0)",
                 [VIVALDI_FIRST_US + 1_000_000])
        .unwrap();
    // The exclusive lock is taken on the first write and kept; prove it, so a
    // future SQLite that stopped doing that cannot make this test vacuous.
    // `busy_timeout(0)`, because rusqlite opens every connection with a 5 s one
    // and this assertion is about a lock that is never coming free — five
    // seconds of the default run spent waiting to be told so.
    assert!(
        Connection::open_with_flags(&src, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .and_then(|c| {
                c.busy_timeout(std::time::Duration::ZERO)?;
                c.query_row("SELECT COUNT(*) FROM urls", [], |r| r.get::<_, i64>(0))
            })
            .is_err(),
        "the fixture is not actually locked, so this proves nothing"
    );

    let started = std::time::Instant::now();
    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    assert!(started.elapsed().as_secs() < 30, "the backup retried instead of falling back");

    let urls: Vec<String> =
        core.history(String::new(), 10).unwrap().iter().map(|e| e.url.clone()).collect();
    assert!(urls.contains(&"https://locked.example".to_string()));
    // Committed before the lock was taken by *this* connection, so the file copy
    // has to carry it: that is what the `-journal` sibling is for.
    assert!(
        urls.contains(&"https://while-open.example".to_string()),
        "the copy lost the last transaction"
    );
    drop(browser);
}

/// The copy is a copy: nothing writes to the browser's own file, including the
/// hot-journal rollback the snapshot needs before it can be read.
#[test]
fn the_source_file_is_never_written_to() {
    let dir = tempfile::tempdir().unwrap();
    let src = chromium_source(dir.path(), &[("https://a.example/", None, 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0)]);
    let before = std::fs::metadata(&src).unwrap().modified().unwrap();
    let bytes = std::fs::read(&src).unwrap();

    let core = Core::open(db(&dir)).unwrap();
    core.import_history(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();

    assert_eq!(std::fs::metadata(&src).unwrap().modified().unwrap(), before);
    assert_eq!(std::fs::read(&src).unwrap(), bytes);
}

// ---- the report ------------------------------------------------------------

#[test]
fn a_dry_run_reports_what_an_import_would_do() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://shared.example/", "Shared");

    let src = chromium_source(
        dir.path(),
        &[
            ("https://shared.example/", Some("Shared"), 1, VIVALDI_FIRST_US, VIVALDI_FIRST_US, 0),
            ("https://one.example/", Some("One"), 1, VIVALDI_FIRST_US + 10, VIVALDI_FIRST_US, 0),
            ("https://two.example/", Some("Two"), 1, VIVALDI_FIRST_US + 20, VIVALDI_FIRST_US, 0),
        ],
    );
    let s = source(&src, HistorySourceKind::Chromium);

    let merge = core.plan_history_import(s.clone(), ImportMode::Merge).unwrap();
    assert_eq!(merge.source_pages, 3);
    assert_eq!(merge.already_known, 1);
    assert_eq!(merge.new_pages, 2);
    assert_eq!(merge.existing_pages, 1);
    assert_eq!(merge.resulting_pages, 3);
    assert_eq!(merge.earliest_visit_at, Some(VIVALDI_FIRST_MS));

    let replace = core.plan_history_import(s.clone(), ImportMode::Replace).unwrap();
    assert_eq!(replace.resulting_pages, 3);
    assert_eq!(replace.existing_pages, 1);

    // And the numbers the report gave are the numbers that happened.
    let outcome = core.import_history(s, ImportMode::Merge).unwrap();
    assert_eq!(outcome.plan, merge);
    assert_eq!(outcome.inserted, 2);
    assert_eq!(outcome.updated, 1);
    assert_eq!(core.history_count().unwrap(), 3);
}

#[test]
fn an_empty_source_imports_nothing_and_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    visit(&core, "https://mine.example/", "Mine");
    let src = chromium_source(dir.path(), &[]);
    let plan = core
        .plan_history_import(source(&src, HistorySourceKind::Chromium), ImportMode::Merge)
        .unwrap();
    assert_eq!(plan.source_pages, 0);
    assert_eq!(plan.earliest_visit_at, None);
    assert_eq!(plan.resulting_pages, 1);
}
