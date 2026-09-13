//! Bookmarks: the store, and taking another browser's.
//!
//! Three things here fail quietly rather than loudly, so each has a test that
//! pins a number or a name rather than a shape:
//!
//! 1. **The tree.** `parent_id` is a self-reference with `ON DELETE CASCADE`,
//!    and the two ways to lose a branch are a delete that takes more than it
//!    should and a move that puts a folder inside itself. Neither raises
//!    anything; both leave rows in the table that nothing can reach.
//! 2. **Doing it twice.** A merge has no side table saying what has already
//!    been imported — the identity is the address *and* the folder it is in —
//!    so `importing_twice_changes_nothing` is what holds that claim up, the
//!    same way it does for history.
//! 3. **What survives what.** Clearing history may not take the bookmarks with
//!    it. That is the whole reason this is not a flag on `visit`, and a delete
//!    is not a thing to discover by hand.

use laned_core::import::{self, HistorySourceKind, ImportMode};
use laned_core::Core;
use rusqlite::Connection;
use std::path::{Path, PathBuf};

fn core() -> (tempfile::TempDir, std::sync::Arc<Core>) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.db").to_string_lossy().into_owned();
    let core = Core::open(path).unwrap();
    (dir, core)
}

/// Title and depth, which is what the sidebar draws.
fn shape(core: &Core) -> Vec<(String, u32)> {
    core.bookmarks().unwrap().into_iter().map(|b| (b.title, b.depth)).collect()
}

fn folder(core: &Core, title: &str) -> String {
    core.add_bookmark(None, None, title.into()).unwrap().id
}

// ---- the store -------------------------------------------------------------

#[test]
fn a_kept_page_is_found_by_the_address_the_browser_reports() {
    // The star's question. WebKit hands back whichever spelling the server
    // used, so the lookup has to go through the same normalizer the visit did
    // or the star is dark on a page that is kept.
    let (_d, core) = core();
    core.add_bookmark(None, Some("https://example.com/".into()), "Example".into()).unwrap();

    assert_eq!(core.bookmarks_for_url("https://example.com".into()).unwrap().len(), 1);
    assert_eq!(core.bookmarks_for_url("HTTPS://Example.com:443/".into()).unwrap().len(), 1);
    assert!(core.bookmarks_for_url("https://example.com/other".into()).unwrap().is_empty());
}

#[test]
fn a_page_with_no_title_is_kept_under_its_address() {
    let (_d, core) = core();
    let kept = core
        .add_bookmark(None, Some("http://localhost:3000/api/users".into()), "  ".into())
        .unwrap();
    assert_eq!(kept.title, "localhost:3000/api/users");
}

#[test]
fn the_tree_comes_back_in_the_order_it_is_drawn() {
    // Every folder immediately followed by what is in it, siblings in the order
    // they were added — which is the order a bar is aimed at.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    core.add_bookmark(Some(work.clone()), Some("https://a.example".into()), "A".into()).unwrap();
    let rust = core.add_bookmark(Some(work), None, "Rust".into()).unwrap();
    core.add_bookmark(Some(rust.id), Some("https://b.example".into()), "B".into()).unwrap();
    core.add_bookmark(None, Some("https://c.example".into()), "C".into()).unwrap();

    assert_eq!(
        shape(&core),
        vec![
            ("Work".into(), 0),
            ("A".into(), 1),
            ("Rust".into(), 1),
            ("B".into(), 2),
            ("C".into(), 0),
        ]
    );
}

#[test]
fn deleting_a_folder_deletes_what_is_in_it_and_nothing_else() {
    let (_d, core) = core();
    let work = folder(&core, "Work");
    core.add_bookmark(Some(work.clone()), Some("https://a.example".into()), "A".into()).unwrap();
    core.add_bookmark(None, Some("https://c.example".into()), "C".into()).unwrap();

    core.remove_bookmark(work).unwrap();
    assert_eq!(shape(&core), vec![("C".into(), 0)]);
}

#[test]
fn a_folder_cannot_be_moved_inside_itself() {
    // The one move that detaches a branch silently: `TREE_SQL` walks down from
    // the bar, so a cycle is not a hang — it is rows that exist and are
    // reachable by nothing.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    let rust = core.add_bookmark(Some(work.clone()), None, "Rust".into()).unwrap();

    assert!(core.move_bookmark(work.clone(), Some(rust.id), None).is_err());
    assert!(core.move_bookmark(work.clone(), Some(work), None).is_err());
    assert_eq!(shape(&core).len(), 2, "the tree lost a branch");
}

#[test]
fn moving_a_bookmark_with_no_index_files_it_at_the_end_of_the_new_folder() {
    // What the editor's folder popup does. A popup has no place in it to point
    // at, so "somewhere in Work" can only mean the end.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    core.add_bookmark(Some(work.clone()), Some("https://a.example".into()), "A".into()).unwrap();
    let loose = core.add_bookmark(None, Some("https://b.example".into()), "B".into()).unwrap();

    core.move_bookmark(loose.id, Some(work), None).unwrap();
    assert_eq!(shape(&core), vec![("Work".into(), 0), ("A".into(), 1), ("B".into(), 1)]);
}

// ---- putting them in an order ----------------------------------------------

/// The case the whole section is about: eight folders arriving from an import
/// in the source's order, which is not the owner's.
fn bar(core: &Core, titles: &[&str]) -> Vec<String> {
    titles.iter().map(|t| folder(core, t)).collect()
}

fn titles(core: &Core) -> Vec<String> {
    core.bookmarks().unwrap().into_iter().map(|b| b.title).collect()
}

#[test]
fn a_folder_moved_to_the_front_of_the_bar_lands_there_and_the_rest_close_up() {
    let (_d, core) = core();
    let ids = bar(&core, &["A", "B", "C", "D"]);

    core.move_bookmark(ids[2].clone(), None, Some(0)).unwrap();
    assert_eq!(titles(&core), ["C", "A", "B", "D"]);

    // Dense, 0..n, with nothing doubled — the property `TREE_SQL`'s zero-padded
    // sort key rests on, and the one a half-finished move would break.
    let positions: Vec<u32> = core.bookmarks().unwrap().into_iter().map(|b| b.position).collect();
    assert_eq!(positions, [0, 1, 2, 3]);
}

#[test]
fn an_index_past_the_end_is_the_end_rather_than_an_error() {
    // The drop below the last row. A table hands back "after row n", and the
    // caller should not have to know how many siblings there were to ask for it.
    let (_d, core) = core();
    let ids = bar(&core, &["A", "B", "C"]);

    core.move_bookmark(ids[0].clone(), None, Some(99)).unwrap();
    assert_eq!(titles(&core), ["B", "C", "A"]);
}

#[test]
fn the_index_is_where_the_row_ends_up_not_a_gap_in_the_list_it_left() {
    // The off-by-one this is all about, settled once so nobody has to work it
    // out twice. The index counts the siblings *without* this row, so `2` means
    // "end up third" from either side. A table hands back the other convention —
    // a gap in the list as drawn, which still has the dragged row in it — and
    // converting is `SidebarModel.dropTarget`'s job, where the row indices are.
    let (_d, core) = core();
    let ids = bar(&core, &["A", "B", "C", "D"]);

    core.move_bookmark(ids[0].clone(), None, Some(2)).unwrap();
    assert_eq!(titles(&core), ["B", "C", "A", "D"]);

    // Now from below the same spot, to the same index.
    core.move_bookmark(ids[3].clone(), None, Some(2)).unwrap();
    assert_eq!(titles(&core), ["B", "C", "D", "A"]);
}

#[test]
fn a_move_into_a_folder_leaves_the_one_it_came_out_of_dense() {
    let (_d, core) = core();
    let work = folder(&core, "Work");
    for t in ["A", "B", "C"] {
        core.add_bookmark(Some(work.clone()), Some(format!("https://{t}.example")), t.into())
            .unwrap();
    }
    let play = folder(&core, "Play");

    let b = core.bookmarks().unwrap().into_iter().find(|x| x.title == "B").unwrap();
    core.move_bookmark(b.id, Some(play), Some(0)).unwrap();

    let left: Vec<(String, u32)> = core
        .bookmarks()
        .unwrap()
        .into_iter()
        .filter(|x| ["A", "C"].contains(&x.title.as_str()))
        .map(|x| (x.title, x.position))
        .collect();
    assert_eq!(left, [("A".to_string(), 0), ("C".to_string(), 1)]);
}

#[test]
fn a_nudge_stops_at_the_ends_instead_of_wrapping() {
    // Wrapping would make the eighth press of ⌘⇧↑ undo the seven before it,
    // which is the one thing a list you are ordering by hand cannot do.
    let (_d, core) = core();
    let ids = bar(&core, &["A", "B", "C"]);

    core.nudge_bookmark(ids[0].clone(), false).unwrap();
    assert_eq!(titles(&core), ["A", "B", "C"]);
    core.nudge_bookmark(ids[2].clone(), true).unwrap();
    assert_eq!(titles(&core), ["A", "B", "C"]);

    core.nudge_bookmark(ids[2].clone(), false).unwrap();
    assert_eq!(titles(&core), ["A", "C", "B"]);
}

#[test]
fn a_nudge_never_changes_folder() {
    // A row at the bottom of `Work` nudged down does not fall into whatever is
    // below `Work` on the bar. The result of that keystroke would be off screen
    // as often as not, and undoing it means knowing where it went.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    let last =
        core.add_bookmark(Some(work), Some("https://a.example".into()), "A".into()).unwrap();
    folder(&core, "Play");

    core.nudge_bookmark(last.id.clone(), true).unwrap();
    let moved = core.bookmarks().unwrap().into_iter().find(|b| b.id == last.id).unwrap();
    assert!(moved.parent_id.is_some(), "the nudge fell out of the folder");
    assert_eq!(titles(&core), ["Work", "A", "Play"]);
}

#[test]
fn an_order_the_user_chose_survives_a_second_import() {
    // The import appends what is new and leaves what is here alone — so a bar
    // the owner has spent a minute arranging must not spring back to Vivaldi's
    // order the next time he imports.
    let (_d, core) = core();
    let ids = bar(&core, &["Work", "Play", "Read"]);
    core.move_bookmark(ids[2].clone(), None, Some(0)).unwrap();
    assert_eq!(titles(&core), ["Read", "Work", "Play"]);

    let dir = tempfile::tempdir().unwrap();
    let source = chromium_profile(dir.path());
    core.import_history(source, ImportMode::Merge).unwrap();

    let after = titles(&core);
    let order: Vec<&String> =
        after.iter().filter(|t| ["Read", "Work", "Play"].contains(&t.as_str())).collect();
    assert_eq!(order, ["Read", "Work", "Play"], "the import reordered the bar");
}

#[test]
fn a_move_of_a_row_that_is_gone_is_not_an_error() {
    // The sidebar's rows are a snapshot. A drop that lands after the row was
    // deleted somewhere else should do nothing, not raise at the user.
    let (_d, core) = core();
    folder(&core, "A");
    core.move_bookmark("no-such-row".into(), None, Some(0)).unwrap();
    assert_eq!(titles(&core), ["A"]);
}

#[test]
fn a_rename_is_the_users_and_a_visit_does_not_undo_it() {
    // The difference between this store and `visit`: a history row learns its
    // name from the page every time it loads, and a bookmark does not.
    let (_d, core) = core();
    let kept = core
        .add_bookmark(None, Some("https://example.com".into()), "Example Domain".into())
        .unwrap();
    core.rename_bookmark(kept.id, "The one with the example".into()).unwrap();
    core.name_visit("https://example.com".into(), "Example Domain".into()).unwrap();

    assert_eq!(core.bookmarks().unwrap()[0].title, "The one with the example");
}

#[test]
fn clearing_history_keeps_the_bookmarks() {
    // The reason this is a table and not a column on `visit`.
    let (_d, core) = core();
    core.add_bookmark(None, Some("https://example.com".into()), "Example".into()).unwrap();
    core.clear_history().unwrap();
    assert_eq!(core.bookmark_count().unwrap(), 1);
}

// ---- the one door ----------------------------------------------------------

#[test]
fn typing_finds_a_bookmark_the_way_it_finds_a_page() {
    // Same ranker as history, so the tiers are the same: a literal hit beats a
    // title coincidence, and a subsequence is the last resort rather than the
    // first.
    let (_d, core) = core();
    core.add_bookmark(None, Some("https://shop.example.com/hoppers".into()), "Shop".into())
        .unwrap();
    core.add_bookmark(None, Some("https://launchd.info/y".into()), "Launchd notes".into())
        .unwrap();

    let hits = core.search_bookmarks("hop".into(), 10).unwrap();
    assert_eq!(hits[0].bookmark.url.as_deref(), Some("https://shop.example.com/hoppers"));

    // `mxp` finding `max-pane` is the tier that only applies when nothing
    // matched literally, and it applies here too because it is one ranker.
    core.add_bookmark(None, Some("https://max-pane.local".into()), "Max Pane".into()).unwrap();
    let hits = core.search_bookmarks("mxp".into(), 10).unwrap();
    assert_eq!(hits[0].bookmark.url.as_deref(), Some("https://max-pane.local"));
}

#[test]
fn a_hit_says_which_folder_it_came_out_of() {
    // Two bookmarks called `notes` is the case the row has to tell apart.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    let rust = core.add_bookmark(Some(work), None, "Rust".into()).unwrap();
    core.add_bookmark(Some(rust.id), Some("https://a.example/notes".into()), "Notes".into())
        .unwrap();
    core.add_bookmark(None, Some("https://b.example/notes".into()), "Notes".into()).unwrap();

    let hits = core.search_bookmarks("a.example".into(), 10).unwrap();
    assert_eq!(hits[0].folder_path.as_deref(), Some("Work/Rust"));
    let hits = core.search_bookmarks("b.example".into(), 10).unwrap();
    assert_eq!(hits[0].folder_path, None, "a row on the bar is in no folder");
}

#[test]
fn folders_are_not_something_the_door_can_open() {
    let (_d, core) = core();
    folder(&core, "Work");
    assert!(core.search_bookmarks("work".into(), 10).unwrap().is_empty());
}

// ---- reading another browser ----------------------------------------------

/// Chromium's `Bookmarks`, with the shape a real one has: string microsecond
/// dates since 1601, a `bookmark_bar` root and an `other` root.
const CHROMIUM_BOOKMARKS: &str = r#"{
  "roots": {
    "bookmark_bar": {
      "type": "folder", "name": "Bookmarks bar", "date_added": "13353094057202910",
      "children": [
        {"type": "url", "name": "Docs", "url": "https://docs.example.com/",
         "date_added": "13353094057202910"},
        {"type": "folder", "name": "Work", "date_added": "13353094057202910",
         "children": [
           {"type": "url", "name": "Board", "url": "https://board.example.com/x",
            "date_added": "13353094057202910"}
         ]},
        {"type": "url", "name": "An extension", "url": "chrome-extension://abcd/options.html",
         "date_added": "13353094057202910"}
      ]
    },
    "other": {
      "type": "folder", "name": "Other bookmarks", "date_added": "13353094057202910",
      "children": [
        {"type": "url", "name": "Loose", "url": "https://loose.example.com/",
         "date_added": "13353094057202910"}
      ]
    },
    "synced": {"type": "folder", "name": "Mobile bookmarks", "date_added": "0", "children": []}
  }
}"#;

/// The same instant as `tests/import.rs`'s `VIVALDI_FIRST_US`: 2024-02-22.
const VIVALDI_FIRST_MS: i64 = 1_708_620_457_202;

#[test]
fn a_chromium_bar_lands_on_the_bar_and_the_rest_becomes_a_folder() {
    let tree = import::read_chromium_bookmarks(CHROMIUM_BOOKMARKS).unwrap();
    let flat = import::flatten(&tree);
    let names: Vec<(Vec<String>, &str)> =
        flat.iter().map(|b| (b.folder.clone(), b.url.as_str())).collect();

    assert_eq!(
        names,
        vec![
            (vec![], "https://docs.example.com"),
            (vec!["Work".to_string()], "https://board.example.com/x"),
            (vec!["Other Bookmarks".to_string()], "https://loose.example.com"),
        ],
        "the bar was buried, or the extension row survived"
    );
    // An empty root contributes no folder: a bar with "Mobile Bookmarks" on it
    // and nothing inside is a row that can only disappoint.
    assert!(!flat.iter().any(|b| b.folder.iter().any(|f| f == "Mobile Bookmarks")));
    assert_eq!(flat[0].added_at, VIVALDI_FIRST_MS, "the 1601 epoch was not converted");
}

fn firefox_bookmarks(dir: &Path) -> PathBuf {
    let path = dir.join("places.sqlite");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                                  visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL,
                                  last_visit_date INTEGER);
         CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
         CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER,
                                     parent INTEGER, position INTEGER, title LONGVARCHAR,
                                     dateAdded INTEGER, guid TEXT);
         INSERT INTO moz_places (id, url, title) VALUES
           (1, 'https://docs.example.com/', 'Docs'),
           (2, 'https://board.example.com/x', 'Board'),
           (3, 'https://loose.example.com/', 'Loose');
         -- The roots, by the guids Firefox documents rather than by their ids.
         INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid) VALUES
           (1, 2, NULL, 0, 0, '',        0, 'root________'),
           (2, 2, NULL, 1, 0, 'menu',    0, 'menu________'),
           (3, 2, NULL, 1, 1, 'toolbar', 0, 'toolbar_____'),
           (5, 2, NULL, 1, 2, 'unfiled', 0, 'unfiled_____'),
           (10, 1, 1, 3, 0, 'Docs',  1708620457202000, 'aaaaaaaaaaaa'),
           (11, 2, NULL, 3, 1, 'Work', 1708620457202000, 'bbbbbbbbbbbb'),
           (12, 1, 2, 11, 0, 'Board', 1708620457202000, 'cccccccccccc'),
           (13, 3, NULL, 3, 2, NULL,  1708620457202000, 'dddddddddddd'),
           (14, 1, 3, 5, 0, 'Loose', 1708620457202000, 'eeeeeeeeeeee');",
    )
    .unwrap();
    path
}

#[test]
fn a_firefox_toolbar_lands_on_the_bar_and_a_separator_is_not_a_bookmark() {
    let dir = tempfile::tempdir().unwrap();
    let path = firefox_bookmarks(dir.path());
    let conn = Connection::open(&path).unwrap();
    let flat = import::flatten(&import::read_firefox_bookmarks(&conn).unwrap());

    assert_eq!(
        flat.iter().map(|b| (b.folder.clone(), b.url.as_str())).collect::<Vec<_>>(),
        vec![
            (vec![], "https://docs.example.com"),
            (vec!["Work".to_string()], "https://board.example.com/x"),
            (vec!["Other Bookmarks".to_string()], "https://loose.example.com"),
        ]
    );
    assert_eq!(flat[0].added_at, VIVALDI_FIRST_MS, "the 1970 µs epoch was not converted");
}

// ---- importing -------------------------------------------------------------

/// A source with both halves: Chromium keeps them in two files in one profile.
fn chromium_profile(dir: &Path) -> import::HistorySource {
    let history = dir.join("History");
    let conn = Connection::open(&history).unwrap();
    conn.execute_batch(
        "CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                           visit_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL,
                           hidden INTEGER DEFAULT 0 NOT NULL);
         CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL);
         INSERT INTO urls (id, url, title, visit_count, last_visit_time, hidden)
           VALUES (1, 'https://docs.example.com/', 'Docs', 3, 13353094057202910, 0);
         INSERT INTO visits (url, visit_time) VALUES (1, 13353094057202910);",
    )
    .unwrap();
    std::fs::write(dir.join("Bookmarks"), CHROMIUM_BOOKMARKS).unwrap();
    import::HistorySource {
        name: "Fixture".into(),
        profile: None,
        kind: HistorySourceKind::Chromium,
        path: history.to_string_lossy().into_owned(),
        bookmarks_path: Some(dir.join("Bookmarks").to_string_lossy().into_owned()),
        size_bytes: 0,
        blocked: None,
    }
}

#[test]
fn one_import_brings_both_halves() {
    let (_d, core) = core();
    let src = tempfile::tempdir().unwrap();
    let source = chromium_profile(src.path());

    let plan = core.plan_history_import(source.clone(), ImportMode::Merge).unwrap();
    assert_eq!(plan.source_pages, 1);
    assert_eq!(plan.source_bookmarks, Some(3), "the extension row was counted");

    let outcome = core.import_history(source, ImportMode::Merge).unwrap();
    assert_eq!(outcome.inserted, 1);
    // Three pages plus the two folders they needed.
    assert_eq!(outcome.bookmarks_inserted, 5);
    assert_eq!(
        shape(&core),
        vec![
            ("Docs".into(), 0),
            ("Work".into(), 0),
            ("Board".into(), 1),
            ("Other Bookmarks".into(), 0),
            ("Loose".into(), 1),
        ]
    );
}

#[test]
fn importing_twice_changes_nothing() {
    // No side table of what has been imported: the identity is the address and
    // the folder it is in, and both are already in the tree.
    let (_d, core) = core();
    let src = tempfile::tempdir().unwrap();
    let source = chromium_profile(src.path());

    core.import_history(source.clone(), ImportMode::Merge).unwrap();
    let before = shape(&core);
    let again = core.import_history(source, ImportMode::Merge).unwrap();

    assert_eq!(again.bookmarks_inserted, 0);
    assert_eq!(shape(&core), before);
}

#[test]
fn a_merge_files_into_the_folder_that_is_already_there() {
    // The failure this pins is a second `Work` beside the first, which is what
    // matching on id rather than on the path the user reads would produce.
    let (_d, core) = core();
    let work = folder(&core, "Work");
    core.add_bookmark(Some(work), Some("https://mine.example".into()), "Mine".into()).unwrap();

    let src = tempfile::tempdir().unwrap();
    core.import_history(chromium_profile(src.path()), ImportMode::Merge).unwrap();

    let folders: Vec<String> = core
        .bookmarks()
        .unwrap()
        .into_iter()
        .filter(|b| b.is_folder)
        .map(|b| b.title)
        .collect();
    assert_eq!(folders, vec!["Work", "Other Bookmarks"]);
    assert_eq!(
        shape(&core),
        vec![
            ("Work".into(), 0),
            ("Mine".into(), 1),
            ("Board".into(), 1),
            ("Docs".into(), 0),
            ("Other Bookmarks".into(), 0),
            ("Loose".into(), 1),
        ]
    );
}

#[test]
fn a_rename_survives_a_second_import() {
    // A merge never updates a row that is already here, because the title in it
    // is the user's and the source's is the page's.
    let (_d, core) = core();
    let src = tempfile::tempdir().unwrap();
    let source = chromium_profile(src.path());
    core.import_history(source.clone(), ImportMode::Merge).unwrap();

    let docs = core.bookmarks().unwrap().into_iter().find(|b| b.title == "Docs").unwrap();
    core.rename_bookmark(docs.id, "The docs".into()).unwrap();
    core.import_history(source, ImportMode::Merge).unwrap();

    assert!(core.bookmarks().unwrap().iter().any(|b| b.title == "The docs"));
    assert!(!core.bookmarks().unwrap().iter().any(|b| b.title == "Docs"));
}

#[test]
fn replace_drops_what_was_kept_and_says_how_much() {
    let (_d, core) = core();
    core.add_bookmark(None, Some("https://mine.example".into()), "Mine".into()).unwrap();

    let src = tempfile::tempdir().unwrap();
    let outcome = core.import_history(chromium_profile(src.path()), ImportMode::Replace).unwrap();

    assert_eq!(outcome.bookmarks_discarded, 1);
    assert!(!core.bookmarks().unwrap().iter().any(|b| b.title == "Mine"));
    assert!(outcome.backup_path.is_some(), "the only way back from one click");
}

#[test]
fn a_source_whose_bookmarks_we_cannot_read_says_so_rather_than_saying_none() {
    let (_d, core) = core();
    let src = tempfile::tempdir().unwrap();
    let mut source = chromium_profile(src.path());
    source.bookmarks_path = None;

    let plan = core.plan_history_import(source, ImportMode::Merge).unwrap();
    assert_eq!(plan.source_bookmarks, None);
}
