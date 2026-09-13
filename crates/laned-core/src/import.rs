//! Taking another browser's history and making it ours.
//!
//! Three browser families, three schemas, three epochs, and one ledger whose
//! ordering key is not a clock. Each of those is a place this can go quietly
//! wrong — history dated 1601, or a hundred thousand pages from 2024 sitting on
//! top of what the user did this morning — so each gets its own section below.
//!
//! # Nothing is read out of a browser that is running
//!
//! Every one of these files is a live SQLite database belonging to a process we
//! do not control, and reading one in place is the fastest way to learn what a
//! torn page looks like. So an import never touches the original: it takes a
//! snapshot first ([`Snapshot::take`]) and reads that.
//!
//! The obvious snapshot is SQLite's own backup API, and it is tried first. It
//! does not work on the browser this feature exists for. Chromium opens its
//! `History` database with `PRAGMA locking_mode = EXCLUSIVE` and holds the lock
//! for the life of the process, so a second connection cannot so much as read
//! the schema — measured here against a running Vivaldi: `database is locked`
//! after a 15 s busy timeout, every time. The fallback is the one the format
//! documents: copy the file *and its `-journal`/`-wal`/`-shm` siblings*, then
//! open the copy read-write so SQLite can roll the hot journal back and hand us
//! the last committed state. A copy of the main file alone is the trap — it is
//! the one that yields a database that opens and is subtly out of date.
//!
//! The snapshot is deleted when [`Snapshot`] drops, and any snapshot left by a
//! process that died mid-import is swept by the next one. It lives beside the
//! ledger rather than in `/tmp`: it is a byte-for-byte copy of everywhere the
//! user has ever been, and the app's own directory is the one place that is
//! already as private as that.
//!
//! # Epochs
//!
//! | family | unit | zero |
//! |---|---|---|
//! | Chromium | microseconds | 1601-01-01 |
//! | Safari | seconds (float) | 2001-01-01 |
//! | Firefox | microseconds | 1970-01-01 |
//!
//! Getting one wrong produces dates, not errors, which is why
//! [`Epoch::to_epoch_ms`] is three named constants and `tests/import.rs` pins
//! each against a timestamp taken out of a real profile.

use crate::error::{CoreError, Result};
use crate::history::normalize_url;
use rusqlite::{Connection, OpenFlags};
use std::path::{Path, PathBuf};

/// Which schema a history file has, which is a smaller question than which
/// browser wrote it: every Chromium fork shares `urls`/`visits` down to the
/// column names, so Vivaldi, Chrome, Brave, Edge and Arc are one reader.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistorySourceKind {
    Chromium,
    Safari,
    Firefox,
}

/// One history file we could import from, as offered to the wizard.
///
/// Produced by looking at the disk, never from a fixed list: a browser the user
/// does not have installed is not a row they should have to read past, and a
/// browser we have never heard of is one they would never be offered. The
/// wizard hands this record straight back to [`crate::Core::import_history`],
/// so there is no id table to keep in step.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistorySource {
    /// "Vivaldi", "Safari", "Firefox" — the name on the user's Dock.
    pub name: String,
    /// The browser's own name for the profile, when it has more than one.
    pub profile: Option<String>,
    pub kind: HistorySourceKind,
    /// Absolute path to the history database.
    pub path: String,
    /// Absolute path to this profile's bookmarks, when we can read the format.
    ///
    /// `None` is not "this browser has no bookmarks" — it is "not from here".
    /// Safari keeps its in a binary property list, and the only reader for one
    /// on this machine is `plutil`, a macOS program. This crate is the
    /// platform-agnostic half of the app (see the README's layout) and shelling
    /// out to a system tool would make it macOS-only for one browser the owner
    /// does not use. The wizard says so on the row rather than importing half
    /// of Safari silently.
    pub bookmarks_path: Option<String>,
    /// Bytes, for a wizard that is about to copy it.
    pub size_bytes: u64,
    /// Why we cannot read it, when we cannot. `Some` here is not an error: the
    /// row is still offered, greyed, with the sentence that says what to do.
    pub blocked: Option<String>,
}

/// What to do with the history already in the ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ImportMode {
    /// Keep it, and fold the source into it.
    Merge,
    /// Drop it, and let the source stand alone. Backed up first.
    Replace,
}

/// What an import would do, or did. Returned by the dry run *and* carried in
/// the outcome, so the wizard shows one shape of report twice and the numbers
/// on the confirmation screen are the numbers that were acted on.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportPlan {
    /// Pages in the source we can use: normalized, actually visited, distinct.
    pub source_pages: u32,
    /// Source rows that did not become a page here, with the reasons collapsed
    /// into one number: an unrecordable scheme, a URL typed and never loaded, a
    /// row the browser itself hides, or a second spelling of a page already
    /// counted. A list of them is not something anyone reads — 3 800 of the
    /// owner's 112 846 are OAuth bounces — and the number is what says whether
    /// the import looks like the browser it came from.
    pub skipped: u32,
    /// Source pages the ledger already has. In `Merge` these are folded; in
    /// `Replace` they are simply the overlap, which is the number that tells
    /// the user how much of the old ledger the new one still covers.
    pub already_known: u32,
    /// Source pages the ledger has never seen.
    pub new_pages: u32,
    /// Epoch ms of the oldest and newest visit in the source. `None` for an
    /// empty source.
    pub earliest_visit_at: Option<i64>,
    pub latest_visit_at: Option<i64>,
    /// Pages in the ledger before the import.
    pub existing_pages: u32,
    /// Pages in the ledger afterwards.
    pub resulting_pages: u32,
    /// Bookmarks the source has, folders not counted.
    ///
    /// # Why bookmarks ride in the history wizard rather than getting one of
    /// their own
    ///
    /// Because "import from Vivaldi" is one decision. The wizard already finds
    /// the profiles on this Mac, already explains merge against replace,
    /// already refuses to write before a dry run has been read, and already
    /// takes the snapshot that a Firefox bookmark import needs anyway — its
    /// bookmarks are in `places.sqlite`, the file the history is in. A second
    /// wizard would be a second copy of all of that, asking the same question
    /// about the same browser on the next screen along.
    ///
    /// `None` means this source has bookmarks we cannot read — see
    /// [`HistorySource::bookmarks_path`] — as against `Some(0)`, which means it
    /// has none.
    pub source_bookmarks: Option<u32>,
    /// Source bookmarks already kept here, at the same address in the same
    /// folder.
    pub bookmarks_already_known: u32,
    /// Bookmark rows here before the import, folders counted: it is the number
    /// the tree draws.
    pub existing_bookmarks: u32,
    pub resulting_bookmarks: u32,
}

/// An import that happened.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportOutcome {
    pub plan: ImportPlan,
    /// Rows written for pages the ledger had never seen.
    pub inserted: u32,
    /// Rows folded into an entry that already existed. Always 0 for `Replace`.
    pub updated: u32,
    /// Rows `Replace` dropped.
    pub discarded: u32,
    /// Bookmark rows written, folders included.
    pub bookmarks_inserted: u32,
    /// Bookmark rows `Replace` dropped.
    pub bookmarks_discarded: u32,
    /// Where `Replace` put the old ledger. Named so a wrong choice at the
    /// wizard is one `cp` from being undone, which is the whole reason
    /// `Replace` is allowed to be one click.
    pub backup_path: Option<String>,
    pub elapsed_ms: i64,
}

/// One page, as the source told it and after `normalize_url`.
#[derive(Debug, Clone, PartialEq)]
pub struct SourcePage {
    pub url: String,
    pub title: Option<String>,
    pub first_visit_at: i64,
    pub last_visit_at: i64,
    pub visit_count: u32,
}

/// The zero and the unit of a browser's clock. See the table in the module doc.
#[derive(Debug, Clone, Copy)]
enum Epoch {
    /// Microseconds since 1601-01-01. 11 644 473 600 s of it before 1970.
    Chromium,
    /// Seconds, fractional, since 2001-01-01.
    Safari,
    /// Microseconds since 1970-01-01.
    Unix,
}

impl Epoch {
    const WINDOWS_TO_UNIX_MS: i64 = 11_644_473_600_000;
    const APPLE_TO_UNIX_MS: i64 = 978_307_200_000;

    fn to_epoch_ms(self, raw: f64) -> i64 {
        match self {
            Epoch::Chromium => (raw / 1000.0) as i64 - Self::WINDOWS_TO_UNIX_MS,
            Epoch::Safari => (raw * 1000.0) as i64 + Self::APPLE_TO_UNIX_MS,
            Epoch::Unix => (raw / 1000.0) as i64,
        }
    }
}

// ---- detection -------------------------------------------------------------

/// Chromium forks, by the directory each puts under `~/Library/Application
/// Support`, and by the Keychain item holding its password key. They differ in
/// nothing else: same tables, same columns, same epoch, same exclusive lock.
///
/// The third column is only read by [`crate::logins`], and it is here because
/// it is the one fact about a fork that is **not** derivable from the other
/// two: Google Chrome lives in `Google/Chrome`, is called "Google Chrome" on
/// the Dock, and its key is filed under `Chrome Safe Storage`. Three spellings
/// of one browser, which is exactly the kind of thing that belongs in one
/// table rather than in a `match` somewhere else.
pub(crate) const CHROMIUM_FAMILY: &[(&str, &str, &str)] = &[
    ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
    ("Google Chrome", "Google/Chrome", "Chrome Safe Storage"),
    ("Chrome Beta", "Google/Chrome Beta", "Chrome Safe Storage"),
    ("Chrome Canary", "Google/Chrome Canary", "Chromium Safe Storage"),
    ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
    ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
    ("Chromium", "Chromium", "Chromium Safe Storage"),
    ("Arc", "Arc/User Data", "Arc Safe Storage"),
    ("Opera", "com.operasoftware.Opera", "Opera Safe Storage"),
];

/// Every history file on this machine we know how to read.
pub fn detect() -> Vec<HistorySource> {
    match std::env::var("HOME") {
        Ok(home) => detect_in(Path::new(&home)),
        Err(_) => Vec::new(),
    }
}

/// [`detect`] against an arbitrary home directory, which is the only thing that
/// makes it testable: the real one holds whatever this machine happens to have
/// installed, so a test written against it asserts about the developer's Dock.
pub fn detect_in(home: &Path) -> Vec<HistorySource> {
    let support = home.join("Library/Application Support");
    let mut out = Vec::new();

    for (name, dir, _safe_storage) in CHROMIUM_FAMILY {
        let root = support.join(dir);
        if !root.is_dir() {
            continue;
        }
        // Chromium keeps one `History` per profile directory, and Opera keeps
        // it loose in the root. Sorted, because readdir order is the file
        // system's business and a wizard whose rows move between launches
        // trains the user to read every one.
        let mut profiles: Vec<(Option<String>, PathBuf)> = Vec::new();
        if root.join("History").is_file() {
            profiles.push((None, root.join("History")));
        }
        if let Ok(entries) = std::fs::read_dir(&root) {
            let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            dirs.sort();
            for d in dirs {
                let file = d.join("History");
                if file.is_file() {
                    let label = d.file_name().map(|n| n.to_string_lossy().into_owned());
                    profiles.push((label, file));
                }
            }
        }
        for (profile, path) in profiles {
            out.push(describe(name, profile, HistorySourceKind::Chromium, &path));
        }
    }

    let safari = home.join("Library/Safari/History.db");
    if safari.is_file() {
        out.push(describe("Safari", None, HistorySourceKind::Safari, &safari));
    }

    let firefox = support.join("Firefox/Profiles");
    if let Ok(entries) = std::fs::read_dir(&firefox) {
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
        dirs.sort();
        for d in dirs {
            let file = d.join("places.sqlite");
            if file.is_file() {
                let label = d.file_name().map(|n| n.to_string_lossy().into_owned());
                out.push(describe("Firefox", label, HistorySourceKind::Firefox, &file));
            }
        }
    }

    out
}

/// Fill in the row, including whether we are allowed to open the file at all.
///
/// The permission question is asked here, with a plain `File::open`, rather
/// than being discovered halfway through an import. `~/Library/Safari` is
/// behind TCC: without Full Disk Access the open fails `EPERM`, and SQLite
/// reports that as `unable to open database file` — indistinguishable, in a
/// dialog, from a corrupt profile. So the wizard is told the truth up front and
/// says which checkbox to tick.
fn describe(name: &str, profile: Option<String>, kind: HistorySourceKind, path: &Path) -> HistorySource {
    let size_bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let blocked = match std::fs::File::open(path) {
        Ok(_) => None,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Some(format!(
            "macOS is withholding {name}'s history. Give Max Pane Full Disk Access in \
             System Settings → Privacy & Security, then reopen this window."
        )),
        Err(e) => Some(format!("{}: {e}", path.display())),
    };
    // Beside the history file, and named by the family. Firefox is the odd one
    // out only in that its bookmarks are *in* `places.sqlite`, so the path is
    // the same file twice — which is what lets one snapshot serve both halves
    // of a Firefox import.
    let bookmarks = match kind {
        HistorySourceKind::Chromium => {
            let f = path.with_file_name("Bookmarks");
            f.is_file().then(|| f.to_string_lossy().into_owned())
        }
        HistorySourceKind::Firefox => Some(path.to_string_lossy().into_owned()),
        HistorySourceKind::Safari => None,
    };
    HistorySource {
        name: name.to_string(),
        profile,
        kind,
        path: path.to_string_lossy().into_owned(),
        bookmarks_path: bookmarks,
        size_bytes,
        blocked,
    }
}

// ---- the snapshot ----------------------------------------------------------

/// A private copy of a source history file, removed when this drops.
pub struct Snapshot {
    dir: PathBuf,
    db: PathBuf,
}

impl Snapshot {
    /// Where snapshots go: one directory, swept on entry.
    ///
    /// Swept rather than uniquely named, because the failure mode being guarded
    /// against is a process that died holding 642 MB of someone's browsing
    /// history — and a unique name turns that into a pile of them. There is one
    /// import at a time by construction (the core is behind a mutex), so one
    /// directory is enough.
    fn dir_for(ledger: Option<&Path>) -> PathBuf {
        let base = ledger
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .unwrap_or_else(std::env::temp_dir);
        base.join("import-snapshot")
    }

    /// Copy `source` somewhere we can read it without the browser's help.
    pub fn take(source: &Path, ledger: Option<&Path>) -> Result<Self> {
        let dir = Self::dir_for(ledger);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).map_err(|e| io_err(&dir, e))?;
        let db = dir.join("source.db");
        let snap = Snapshot { dir, db };

        // The backup API first: it is the only copy guaranteed to be a
        // transactionally consistent one, and it is what works for a browser
        // that is closed or that does not hold an exclusive lock.
        if backup_with_sqlite(source, &snap.db).is_ok() {
            return Ok(snap);
        }
        // Chromium's exclusive lock lands here. See the module doc: the
        // siblings are not optional, they are where the last transaction is.
        //
        // The half-written destination the failed backup left has to go first.
        // `fs::copy` would truncate the main file, but a `-journal` or `-wal`
        // beside it belongs to a database that no longer exists, and SQLite
        // would take it for the source's.
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let _ = std::fs::remove_file(with_suffix(&snap.db, suffix));
        }
        std::fs::copy(source, &snap.db).map_err(|e| io_err(source, e))?;
        for suffix in ["-journal", "-wal", "-shm"] {
            let from = with_suffix(source, suffix);
            if from.is_file() {
                let to = with_suffix(&snap.db, suffix);
                std::fs::copy(&from, &to).map_err(|e| io_err(&from, e))?;
            }
        }
        Ok(snap)
    }

    /// A copy of a file that is not a SQLite database — Chromium's `Bookmarks`,
    /// which is JSON.
    ///
    /// The lock that forced [`Snapshot::take`]'s file copy is SQLite's and does
    /// not apply here, so this could read the original in place. It does not,
    /// for the reason the module doc gives for everything else in this file:
    /// the file belongs to a process we do not control, and Chromium rewrites
    /// it whole. A rename-into-place means a reader sees the old file or the
    /// new one — today, in that version of Chromium, on that file system. The
    /// copy costs a few milliseconds on a file measured in hundreds of
    /// kilobytes and does not depend on being right about that.
    pub fn take_plain(source: &Path, ledger: Option<&Path>) -> Result<Self> {
        let dir = Self::dir_for(ledger);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).map_err(|e| io_err(&dir, e))?;
        let db = dir.join("source.db");
        std::fs::copy(source, &db).map_err(|e| io_err(source, e))?;
        Ok(Snapshot { dir, db })
    }

    /// The copy, as a path. Named `db` inside because that is what it is for
    /// every caller but the one above.
    pub fn file(&self) -> &Path {
        &self.db
    }

    /// The copy, opened. Read-write on purpose: a hot journal has to be rolled
    /// back before the file is readable at all, and SQLite will not do that
    /// through a read-only connection — it reports `SQLITE_READONLY_RECOVERY`
    /// and the caller sees a database that "cannot be opened".
    pub fn open(&self) -> Result<Connection> {
        Connection::open(&self.db).map_err(Into::into)
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(suffix);
    PathBuf::from(s)
}

fn io_err(path: &Path, e: std::io::Error) -> CoreError {
    CoreError::Ledger { message: format!("{}: {e}", path.display()) }
}

/// One attempt, all pages, and a verdict. Never a retry loop.
///
/// `Backup::run_to_completion` sleeps and retries on `SQLITE_BUSY` with no
/// bound, which is exactly wrong here: a running Chromium is not transiently
/// busy, it holds an exclusive lock for the life of the process, so the retry
/// is an infinite loop rather than patience. Found the hard way — the first
/// measurement run against the owner's live Vivaldi never printed a line.
///
/// `step(-1)` takes the whole database in one go, which is also what makes the
/// copy consistent when it does work: no other writer gets in between pages.
fn backup_with_sqlite(source: &Path, dest: &Path) -> Result<()> {
    let src = Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    // Short on purpose: this rides out a writer mid-transaction, it does not wait
    // out an exclusive lock. Waiting longer only delays the file copy that is
    // going to happen anyway, and it is paid on every import.
    src.busy_timeout(std::time::Duration::from_millis(250))?;
    let mut out = Connection::open(dest)?;
    let backup = rusqlite::backup::Backup::new(&src, &mut out)?;
    match backup.step(-1)? {
        rusqlite::backup::StepResult::Done => Ok(()),
        _ => Err(CoreError::Ledger { message: format!("{}: locked", source.display()) }),
    }
}

// ---- reading ---------------------------------------------------------------

/// Every page in a snapshot, normalized, deduped, and on our clock.
///
/// Returns the pages and the count of source rows that did not survive — the
/// wizard reports that number rather than a list, because the reasons are all
/// varieties of "not a page you visited" and a list of 3 800 `chrome-extension`
/// URLs is not something anyone reads.
pub fn read_pages(conn: &Connection, kind: HistorySourceKind) -> Result<(Vec<SourcePage>, u32)> {
    let (sql, epoch) = match kind {
        // `hidden` is Chromium's own "never offer this back to the user": OAuth
        // consent bounces, redirect waypoints, subframe loads. 3 800 of the
        // owner's 112 846, and a sample of them is entirely untitled
        // interstitials — exactly what migration 0004 decided a history row is
        // not. `last_visit_time > 0` drops the nine rows that were typed and
        // never loaded.
        HistorySourceKind::Chromium => (
            "SELECT u.url, u.title, u.last_visit_time, u.visit_count,
                    (SELECT MIN(v.visit_time) FROM visits v WHERE v.url = u.id)
               FROM urls u
              WHERE u.last_visit_time > 0{hidden}",
            Epoch::Chromium,
        ),
        HistorySourceKind::Firefox => (
            "SELECT p.url, p.title, p.last_visit_date, p.visit_count,
                    (SELECT MIN(h.visit_date) FROM moz_historyvisits h WHERE h.place_id = p.id)
               FROM moz_places p
              WHERE p.last_visit_date IS NOT NULL{hidden}",
            Epoch::Unix,
        ),
        // Safari keeps the title on the *visit*, not the page, so the name of
        // an entry is the name it had the last time it loaded — which is the
        // same rule `Ledger::name_visit` follows for our own rows.
        HistorySourceKind::Safari => (
            "SELECT i.url,
                    (SELECT v.title FROM history_visits v
                      WHERE v.history_item = i.id AND v.title IS NOT NULL
                      ORDER BY v.visit_time DESC LIMIT 1),
                    (SELECT MAX(v.visit_time) FROM history_visits v WHERE v.history_item = i.id),
                    i.visit_count,
                    (SELECT MIN(v.visit_time) FROM history_visits v WHERE v.history_item = i.id)
               FROM history_items i",
            Epoch::Safari,
        ),
    };

    // Chromium gained `hidden` in 2010 and Firefox has always had it, but a
    // profile old enough to lack it should import rather than fail: the column
    // is a filter, not the data.
    let table = match kind {
        HistorySourceKind::Chromium => "urls",
        HistorySourceKind::Firefox => "moz_places",
        HistorySourceKind::Safari => "history_items",
    };
    // Counted before anything is filtered, so `skipped` is the honest
    // difference between what the browser has and what we took — the rows the
    // SQL drops are as invisible to the user as the ones Rust drops, and a
    // report that only admitted to the second kind would be short by the 3 800
    // hidden rows in the owner's own profile.
    let source_rows: i64 =
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
    let hidden = if kind != HistorySourceKind::Safari && has_column(conn, table, "hidden")? {
        match kind {
            HistorySourceKind::Chromium => " AND u.hidden = 0",
            _ => " AND p.hidden = 0",
        }
    } else {
        ""
    };
    let sql = sql.replace("{hidden}", hidden);

    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt.query([])?;
    // Normalizing collapses rows the source kept apart — `example.com` and
    // `example.com/`, two casings of one host — so the fold has to happen here
    // rather than being left to the ledger's upsert: only here are both halves
    // still source rows, and "earliest first, latest last" needs to be true
    // within the source before it is applied across the two corpora.
    let mut merged: std::collections::HashMap<String, SourcePage> = std::collections::HashMap::new();
    while let Some(row) = rows.next()? {
        let Ok(raw) = row.get::<_, String>(0) else { continue };
        let Some(url) = normalize_url(&raw) else { continue };
        let title: Option<String> = row.get(1).ok().flatten();
        let title = title.filter(|t| !t.trim().is_empty());
        let last_raw: Option<f64> = row.get(2).ok().flatten();
        let Some(last_raw) = last_raw else { continue };
        let count: i64 = row.get(3).unwrap_or(0);
        let first_raw: Option<f64> = row.get(4).ok().flatten();

        let last = epoch.to_epoch_ms(last_raw);
        // A page whose visit rows have been pruned away still has a last visit
        // on the page row; `first` falls back to it rather than to zero, which
        // would date the entry 1970 and put it at the bottom of history for
        // ever.
        let first = first_raw.map(|r| epoch.to_epoch_ms(r)).unwrap_or(last).min(last);
        let page = SourcePage {
            url,
            title,
            first_visit_at: first,
            last_visit_at: last,
            // Chromium records 1 397 pages with a zero count that plainly have
            // visits; the ledger's column is `NOT NULL DEFAULT 1` and a zero
            // there would read as "never visited" in the picker.
            visit_count: count.max(1) as u32,
        };
        match merged.entry(page.url.clone()) {
            std::collections::hash_map::Entry::Occupied(mut e) => {
                fold(e.get_mut(), &page);
            }
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(page);
            }
        }
    }
    let mut pages: Vec<SourcePage> = merged.into_values().collect();
    // Oldest first, so the bulk insert writes in the order the re-seq is about
    // to want and a debugging eye on the table sees a chronology.
    pages.sort_by(|a, b| {
        a.last_visit_at
            .cmp(&b.last_visit_at)
            .then_with(|| a.url.cmp(&b.url))
    });
    let skipped = (source_rows - pages.len() as i64).max(0) as u32;
    Ok((pages, skipped))
}

/// Merge `other` into `into`: earliest first visit, latest last visit, greatest
/// count, and a title only ever replaced by a title.
///
/// # Why every field is a min or a max
///
/// Because that is what makes importing twice a no-op, and "importing twice
/// does not double anything" is otherwise a side table recording which source
/// rows have already been seen — a second store, to be migrated and kept in
/// step, in service of a number nobody ranks on. `min`, `max` and `max` are
/// idempotent by construction, so the second import of a profile writes the
/// same values the first one did and the ledger cannot tell them apart.
///
/// The cost is that `visit_count` under `Merge` is *not* a total: 50 visits in
/// Vivaldi folded with 3 in Max Pane reads 50, not 53. That is the right trade
/// here because `visit_count` is displayed and never ranked — [`crate::history::Ranking`]
/// scores tier first and breaks ties on `seq` — so summing would buy a more
/// literal number at the price of the one property that matters.
pub fn fold(into: &mut SourcePage, other: &SourcePage) {
    into.first_visit_at = into.first_visit_at.min(other.first_visit_at);
    into.last_visit_at = into.last_visit_at.max(other.last_visit_at);
    into.visit_count = into.visit_count.max(other.visit_count);
    if into.title.is_none() {
        into.title = other.title.clone();
    } else if other.last_visit_at >= into.last_visit_at && other.title.is_some() {
        into.title = other.title.clone();
    }
}

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        let name: String = r.get(1)?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

// ---- bookmarks -------------------------------------------------------------
//
// A second tree in the same profile, and three ways of storing it: Chromium
// keeps `Bookmarks` as JSON beside `History`, Firefox keeps `moz_bookmarks`
// inside `places.sqlite` — the file the history is already in — and Safari
// keeps a binary property list this crate deliberately does not read. See
// `HistorySource::bookmarks_path`.
//
// The tree is read whole and in source order, because order is the thing a
// bookmarks bar is. The owner's eight folders have been in the same eight
// places for years, and an import that sorted them by title or by date would
// arrive looking like somebody else's bar.

/// One node of another browser's bookmarks, in the order that browser draws it.
///
/// Recursive, unlike [`crate::model::Bookmark`], and for the opposite reason:
/// nothing sends this across the FFI. It exists between a reader and the
/// ledger, where the shape the source actually has is the cheapest one to hold.
#[derive(Debug, Clone, PartialEq)]
pub struct SourceBookmark {
    pub title: String,
    /// `None` for a folder.
    pub url: Option<String>,
    pub added_at: i64,
    pub children: Vec<SourceBookmark>,
}

/// One kept page with the folders above it, which is the form both the
/// "already known" count and the insert want.
#[derive(Debug, Clone, PartialEq)]
pub struct FlatBookmark {
    /// Folder titles from the bar down. Empty means on the bar.
    pub folder: Vec<String>,
    pub title: String,
    /// Normalized.
    pub url: String,
    pub added_at: i64,
}

/// Depth-first, parents before children — the order the ledger has to write
/// them in, because a folder must exist before anything can be filed under it.
///
/// Folders with nothing importable inside them survive as an empty `folder`
/// path on nothing, which is to say they vanish. That is deliberate: a folder
/// is not something the user asked for separately from what is in it, and a bar
/// that arrives with three empty folders of OAuth redirects in it is worse than
/// one that arrives without them. A folder the user really did leave empty is
/// the same case and the same answer.
pub fn flatten(tree: &[SourceBookmark]) -> Vec<FlatBookmark> {
    fn walk(nodes: &[SourceBookmark], path: &mut Vec<String>, out: &mut Vec<FlatBookmark>) {
        for node in nodes {
            match &node.url {
                Some(url) => out.push(FlatBookmark {
                    folder: path.clone(),
                    title: node.title.clone(),
                    url: url.clone(),
                    added_at: node.added_at,
                }),
                None => {
                    path.push(node.title.clone());
                    walk(&node.children, path, out);
                    path.pop();
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(tree, &mut Vec::new(), &mut out);
    out
}

/// Another browser's bookmarks, as a tree. Empty when we cannot read them.
pub fn read_bookmarks(source: &HistorySource, ledger: Option<&Path>) -> Result<Vec<SourceBookmark>> {
    let Some(path) = source.bookmarks_path.as_deref() else { return Ok(Vec::new()) };
    let path = Path::new(path);
    match source.kind {
        HistorySourceKind::Chromium => {
            let snap = Snapshot::take_plain(path, ledger)?;
            let text = std::fs::read_to_string(snap.file()).map_err(|e| io_err(path, e))?;
            read_chromium_bookmarks(&text)
        }
        HistorySourceKind::Firefox => {
            let snap = Snapshot::take(path, ledger)?;
            let conn = snap.open()?;
            read_firefox_bookmarks(&conn)
        }
        HistorySourceKind::Safari => Ok(Vec::new()),
    }
}

/// Chromium's `Bookmarks`: `{"roots": {"bookmark_bar": …, "other": …}}`, each
/// node `{"type": "url"|"folder", "name", "url", "children", "date_added"}`.
///
/// The bar's children land on our bar and the other roots become folders on it,
/// rather than everything landing under a "Vivaldi" folder. The bar is the part
/// the owner uses daily and burying it one level down to preserve a hierarchy
/// nobody looks at would be importing the file rather than the bookmarks.
/// "Other Bookmarks" is where a browser puts what you saved without choosing,
/// so it stays a folder — it is often thousands of rows, and on the bar it
/// would be the bar.
pub fn read_chromium_bookmarks(text: &str) -> Result<Vec<SourceBookmark>> {
    let doc: serde_json::Value = serde_json::from_str(text)
        .map_err(|e| CoreError::Ledger { message: format!("bookmarks: {e}") })?;
    let Some(roots) = doc.get("roots") else { return Ok(Vec::new()) };
    let mut out = Vec::new();
    if let Some(bar) = roots.get("bookmark_bar") {
        out.extend(chromium_children(bar));
    }
    for (key, label) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
        let Some(node) = roots.get(key) else { continue };
        let children = chromium_children(node);
        if children.is_empty() {
            continue;
        }
        out.push(SourceBookmark {
            title: label.to_string(),
            url: None,
            added_at: chromium_date(node),
            children,
        });
    }
    Ok(out)
}

fn chromium_children(node: &serde_json::Value) -> Vec<SourceBookmark> {
    node.get("children")
        .and_then(|c| c.as_array())
        .map(|c| c.iter().filter_map(chromium_node).collect())
        .unwrap_or_default()
}

fn chromium_node(node: &serde_json::Value) -> Option<SourceBookmark> {
    let name = node.get("name").and_then(|n| n.as_str()).unwrap_or("").trim();
    let added_at = chromium_date(node);
    match node.get("type").and_then(|t| t.as_str()) {
        Some("folder") => Some(SourceBookmark {
            // A folder with no name is one the user cannot aim at, and the
            // ledger will not store an empty title. `folder_path` then reads
            // `Work//Rust`, so the placeholder has to be something.
            title: if name.is_empty() { "Untitled".to_string() } else { name.to_string() },
            url: None,
            added_at,
            children: chromium_children(node),
        }),
        Some("url") => {
            // Same filter history uses: `chrome-extension:` and `javascript:`
            // bookmarks are not pages this app can open, and a row that cannot
            // be opened is worse on a bar than in a history list — the bar is
            // aimed at.
            let url = normalize_url(node.get("url").and_then(|u| u.as_str()).unwrap_or(""))?;
            Some(SourceBookmark {
                title: if name.is_empty() { crate::history::search_handle(&url).to_string() } else { name.to_string() },
                url: Some(url),
                added_at,
                children: Vec::new(),
            })
        }
        _ => None,
    }
}

/// Chromium writes `date_added` as a *string* of microseconds since 1601 —
/// JSON has one number type and this one does not fit a double without losing
/// the last few digits, which is why the file quotes it.
fn chromium_date(node: &serde_json::Value) -> i64 {
    node.get("date_added")
        .and_then(|d| d.as_str())
        .and_then(|d| d.parse::<f64>().ok())
        .map(|raw| Epoch::Chromium.to_epoch_ms(raw))
        .unwrap_or(0)
}

/// Firefox's `moz_bookmarks`, which is in `places.sqlite` beside the history.
///
/// Rows are found by `guid` rather than by the well-known ids 2/3/5, because
/// the guids are the documented contract and the ids are an implementation
/// detail that a profile restored from a backup does not necessarily keep.
pub fn read_firefox_bookmarks(conn: &Connection) -> Result<Vec<SourceBookmark>> {
    let mut stmt = conn.prepare(
        "SELECT b.id, b.parent, b.type, COALESCE(b.title, ''), b.dateAdded, p.url, b.guid
           FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
          ORDER BY b.parent, b.position",
    )?;
    struct Node {
        kind: i64,
        title: String,
        added_at: i64,
        url: Option<String>,
    }
    let mut nodes: std::collections::HashMap<i64, Node> = std::collections::HashMap::new();
    let mut children: std::collections::HashMap<i64, Vec<i64>> = std::collections::HashMap::new();
    let mut roots: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    let mut rows = stmt.query([])?;
    while let Some(r) = rows.next()? {
        let id: i64 = r.get(0)?;
        let parent: i64 = r.get(1).unwrap_or(0);
        let kind: i64 = r.get(2).unwrap_or(0);
        let title: String = r.get(3).unwrap_or_default();
        let added_raw: Option<f64> = r.get(4).ok().flatten();
        let url: Option<String> = r.get(5).ok().flatten();
        let guid: String = r.get(6).unwrap_or_default();
        roots.insert(guid, id);
        nodes.insert(
            id,
            Node {
                kind,
                title,
                added_at: added_raw.map(|raw| Epoch::Unix.to_epoch_ms(raw)).unwrap_or(0),
                url,
            },
        );
        children.entry(parent).or_default().push(id);
    }

    fn build(
        id: i64,
        nodes: &std::collections::HashMap<i64, Node>,
        children: &std::collections::HashMap<i64, Vec<i64>>,
        depth: u32,
    ) -> Option<SourceBookmark> {
        // Firefox has no cycles, and a corrupt profile that did would otherwise
        // recurse until the stack ran out — in a call the shell made off the
        // main thread, where the crash is a dead app and no message.
        if depth > 64 {
            return None;
        }
        let node = nodes.get(&id)?;
        match node.kind {
            // 2 is a folder, 1 is a bookmark, 3 is a separator and is not one.
            2 => Some(SourceBookmark {
                title: if node.title.trim().is_empty() { "Untitled".into() } else { node.title.clone() },
                url: None,
                added_at: node.added_at,
                children: children
                    .get(&id)
                    .map(|kids| kids.iter().filter_map(|k| build(*k, nodes, children, depth + 1)).collect())
                    .unwrap_or_default(),
            }),
            1 => {
                let url = normalize_url(node.url.as_deref().unwrap_or(""))?;
                Some(SourceBookmark {
                    title: if node.title.trim().is_empty() {
                        crate::history::search_handle(&url).to_string()
                    } else {
                        node.title.clone()
                    },
                    url: Some(url),
                    added_at: node.added_at,
                    children: Vec::new(),
                })
            }
            _ => None,
        }
    }

    let mut out = Vec::new();
    if let Some(toolbar) = roots.get("toolbar_____") {
        if let Some(kids) = children.get(toolbar) {
            out.extend(kids.iter().filter_map(|k| build(*k, &nodes, &children, 1)));
        }
    }
    for (guid, label) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks")] {
        let Some(root) = roots.get(guid) else { continue };
        let kids: Vec<SourceBookmark> = children
            .get(root)
            .map(|kids| kids.iter().filter_map(|k| build(*k, &nodes, &children, 1)).collect())
            .unwrap_or_default();
        if kids.is_empty() {
            continue;
        }
        out.push(SourceBookmark {
            title: label.to_string(),
            url: None,
            added_at: nodes.get(root).map(|n| n.added_at).unwrap_or(0),
            children: kids,
        });
    }
    Ok(out)
}
