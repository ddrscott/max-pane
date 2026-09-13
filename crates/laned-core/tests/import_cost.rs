//! What importing a real browser profile costs.
//!
//! Doubly gated, and for two different reasons. `MAXPANE_BENCH` because the
//! numbers only mean anything in release, which is the same gate
//! `cost_of_a_keystroke` is behind. And `MAXPANE_IMPORT_SOURCE` because this one
//! reads a real person's browsing history off a real disk: there is no synthetic
//! stand-in that would answer the question — 112 846 rows of genuine URLs with
//! genuine titles are what the trigram index has to narrow, and `HOSTS[i * 7 %
//! 12]` is not that corpus however many rows it has.
//!
//! ```sh
//! MAXPANE_BENCH=1 \
//! MAXPANE_IMPORT_SOURCE="$HOME/Library/Application Support/Vivaldi/Default/History" \
//!   cargo test --release -p laned-core --test import_cost -- --nocapture
//! ```
//!
//! It is read-only against the source and leaves nothing behind: the ledger it
//! builds is a `tempfile::tempdir` and the snapshot is deleted when the import
//! is over. The numbers it printed on the machine this was written on are in the
//! README, beside round 2's keystroke costs, which is where the rest of
//! history's measurements live.

use laned_core::import::{self, HistorySourceKind, ImportMode};
use laned_core::Core;
use std::path::{Path, PathBuf};

/// Which family a path belongs to, from its file name — the same guess
/// `import::detect` makes from the directory it found it in.
fn kind_of(path: &Path) -> HistorySourceKind {
    match path.file_name().and_then(|n| n.to_str()) {
        Some("places.sqlite") => HistorySourceKind::Firefox,
        Some("History.db") => HistorySourceKind::Safari,
        _ => HistorySourceKind::Chromium,
    }
}

/// The database file and its WAL, separately: an import is one enormous
/// transaction, and "how large does the ledger become" has a different answer
/// before and after that transaction is folded back into the file.
fn megabytes(path: &Path) -> (f64, f64) {
    let size = |suffix: &str| {
        let mut p = path.as_os_str().to_os_string();
        p.push(suffix);
        std::fs::metadata(PathBuf::from(p)).map(|m| m.len()).unwrap_or(0) as f64 / 1_048_576.0
    };
    (size(""), size("-wal"))
}

#[test]
fn cost_of_importing_a_real_profile() {
    if std::env::var_os("MAXPANE_BENCH").is_none() {
        println!("SKIPPED cost_of_importing_a_real_profile — set MAXPANE_BENCH=1");
        return;
    }
    let Some(raw) = std::env::var_os("MAXPANE_IMPORT_SOURCE") else {
        println!(
            "SKIPPED cost_of_importing_a_real_profile — set MAXPANE_IMPORT_SOURCE to a \
             browser history file"
        );
        return;
    };
    let path = PathBuf::from(raw);
    assert!(path.is_file(), "MAXPANE_IMPORT_SOURCE is not a file: {}", path.display());

    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("ledger.db");
    let core = Core::open(ledger.to_string_lossy().into_owned()).unwrap();

    // Something of our own to be interleaved against, so the MRU assertion
    // below is about ordering rather than about an empty table.
    let st = core
        .create_lane(
            laned_core::model::Placement::End,
            laned_core::model::PaneKind::Web,
            None,
            Some("https://max-pane.local/today".into()),
            None,
        )
        .unwrap();
    let pane = st.lanes[0].panes[0].id.clone();
    core.record_visit(pane, "https://max-pane.local/today".into(), Some("Today".into()), vec![])
        .unwrap();

    let source = import::HistorySource {
        name: "Measured".into(),
        profile: None,
        kind: kind_of(&path),
        path: path.to_string_lossy().into_owned(),
        // This measures the history half against a real profile. Pointing it at
        // the bookmarks beside that profile would fold two numbers into one and
        // make the one the README quotes unreadable.
        bookmarks_path: None,
        size_bytes: std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
        blocked: None,
    };
    println!(
        "\nsource: {} ({:.0} MB)",
        path.display(),
        source.size_bytes as f64 / 1_048_576.0
    );

    let start = std::time::Instant::now();
    let plan = core.plan_history_import(source.clone(), ImportMode::Merge).unwrap();
    println!("dry run:  {:6.0} ms", start.elapsed().as_secs_f64() * 1000.0);
    println!(
        "          {} pages, {} skipped, {} new",
        plan.source_pages, plan.skipped, plan.new_pages
    );

    let start = std::time::Instant::now();
    let outcome = core.import_history(source.clone(), ImportMode::Merge).unwrap();
    let import_ms = start.elapsed().as_secs_f64() * 1000.0;
    println!(
        "import:   {import_ms:6.0} ms  ({} inserted, {} folded)",
        outcome.inserted, outcome.updated
    );
    let (db_mb, wal_mb) = megabytes(&ledger);
    println!(
        "ledger:   {db_mb:6.1} MB + {wal_mb:.1} MB wal, for {} pages",
        core.history_count().unwrap()
    );

    // The acceptance criterion this whole feature turns on.
    let mru = core.history(String::new(), 5).unwrap();
    println!("mru[0]:   {}", mru[0].url);
    assert_eq!(
        mru[0].url, "https://max-pane.local/today",
        "an imported page took the top of the MRU"
    );

    // The same queries `cost_of_a_keystroke` uses, over a real corpus instead of
    // a generated one.
    println!("\nkeystrokes over {} pages:", core.history_count().unwrap());
    let mut worst = 0.0f64;
    for query in ["g", "gi", "git", "gith", "github", "docs.rs/ru", "com", "zzqq"] {
        let start = std::time::Instant::now();
        let hits = core.history(query.to_string(), 60).unwrap();
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        println!("  {query:>10}: {ms:6.2} ms, {} hits", hits.len());
        if !hits.is_empty() {
            worst = worst.max(ms);
        }
    }
    assert!(worst < 300.0, "a keystroke cost {worst:.1} ms after the import");

    // Twice is a no-op, on the real thing and not only on a fixture.
    let before = core.history(String::new(), 200).unwrap();
    let start = std::time::Instant::now();
    let again = core.import_history(source, ImportMode::Merge).unwrap();
    println!(
        "\nsecond import: {:.0} ms, {} inserted, {} folded",
        start.elapsed().as_secs_f64() * 1000.0,
        again.inserted,
        again.updated
    );
    assert_eq!(again.inserted, 0, "a second import of one profile added rows");
    assert_eq!(
        before,
        core.history(String::new(), 200).unwrap(),
        "a second import moved something"
    );
}
