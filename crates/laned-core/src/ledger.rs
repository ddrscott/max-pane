//! SQLite persistence. Every layout mutation commits here before the shell is
//! allowed to animate it, so a `kill -9` can only ever lose the frame in flight.

use crate::error::{CoreError, Result};
use crate::model::*;
use rusqlite::functions::FunctionFlags;
use rusqlite::{params, Connection, OptionalExtension, Row};
use std::path::{Path, PathBuf};

/// Applied in order on open. Never edit a file that has shipped.
const MIGRATIONS: &[(&str, &str)] = &[
    ("0001_initial", include_str!("../migrations/0001_initial.sql")),
    ("0002_lane_span", include_str!("../migrations/0002_lane_span.sql")),
    (
        "0003_session_and_recents",
        include_str!("../migrations/0003_session_and_recents.sql"),
    ),
    ("0004_history", include_str!("../migrations/0004_history.sql")),
    ("0005_pane_height", include_str!("../migrations/0005_pane_height.sql")),
    ("0006_pane_zoom", include_str!("../migrations/0006_pane_zoom.sql")),
    ("0007_lane_dock", include_str!("../migrations/0007_lane_dock.sql")),
    (
        "0008_site_permission",
        include_str!("../migrations/0008_site_permission.sql"),
    ),
    (
        "0009_history_index",
        include_str!("../migrations/0009_history_index.sql"),
    ),
    ("0010_bookmarks", include_str!("../migrations/0010_bookmarks.sql")),
    ("0011_history_edges", include_str!("../migrations/0011_history_edges.sql")),
];

/// A needle as an FTS5 query: one quoted phrase, nothing else.
///
/// The typed string reaches the index verbatim, and FTS5's query language would
/// otherwise read `AND`, `*`, `:`, `(` and `-` in it as operators — a URL is
/// made of those characters, so an unquoted address is a syntax error rather
/// than a search. A phrase over the trigram tokenizer means "contains this
/// substring", which is exactly the tier `history::tier` is about to assign.
/// How much of the table a shoulder query may hand back before reading its
/// answer costs more than reading the whole table.
///
/// There is a crossing point and it is not the same on every corpus. Reading a
/// row by rowid out of the FTS5 content table costs about 2.0 µs on the owner's
/// real 108 855 pages and about 0.6 µs on the generated corpus
/// `cost_of_a_keystroke` builds, where the rows are shorter and the table stays
/// in the page cache; reading the same row in one sequential pass costs about
/// 0.5 µs on either. So the narrowing wins up to somewhere between a quarter
/// and all of the table depending on how cold it is, and a third is the middle
/// of that: it keeps the measured wins on both corpora and refuses the case the
/// budget is actually for — a one-character needle against a corpus that is
/// mostly one host, where "the rows whose URL starts with g" is not a narrowing
/// at all and would be several times *slower* than the scan it replaced.
///
/// Above the budget the stage is skipped, not truncated. The answer is the
/// scan's answer either way; only its cost changes. Nothing here can make a row
/// unfindable, which is the property this whole file is arranged around.
const SHOULDER_BUDGET_DIVISOR: i64 = 3;

fn fts_phrase(needle: &str) -> String {
    format!("\"{}\"", needle.replace('"', "\"\""))
}

pub struct Ledger {
    conn: Connection,
    /// Where the file is, or `None` for an in-memory ledger.
    ///
    /// Kept because two things need to name the ledger rather than only write
    /// to it: `Replace` takes a backup of it before dropping history, and an
    /// import puts its snapshot of someone else's 642 MB browsing history in a
    /// sibling directory rather than in `/tmp`. Both want the path the
    /// connection was opened on, and asking SQLite for it afterwards
    /// (`PRAGMA database_list`) would be the same string with a worse failure
    /// mode.
    path: Option<PathBuf>,
}

impl Ledger {
    /// Open (creating if needed) the ledger at `path`, or an in-memory one when
    /// `path` is `None`. Migrations run before the first read.
    pub fn open(path: Option<&Path>) -> Result<Self> {
        let conn = match path {
            Some(p) => {
                if let Some(dir) = p.parent() {
                    std::fs::create_dir_all(dir).map_err(|e| CoreError::Ledger {
                        message: format!("create {}: {e}", dir.display()),
                    })?;
                }
                Connection::open(p)?
            }
            None => Connection::open_in_memory()?,
        };
        // WAL survives a crash mid-write; NORMAL is safe under WAL because the
        // write-ahead log is fsynced at checkpoint, and we accept losing only
        // the last transaction on power loss (not on `kill -9`).
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        Self::register_edges(&conn)?;
        let mut l = Ledger { conn, path: path.map(|p| p.to_path_buf()) };
        l.migrate()?;
        Ok(l)
    }

    /// The file this ledger is, or `None` in memory.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Teach this connection to build [`crate::history::edges`].
    ///
    /// Registered before the migrations run, because 0011 fills its new column
    /// with it. In SQL rather than in Rust so that the backfill, the wholesale
    /// rebuild an import does and the single-row reindex every visit does are
    /// one statement each against one definition — a second copy of "what is a
    /// word start" living in SQL is how the index and the ranker would come to
    /// disagree, and a disagreement there is a page that is in the table and
    /// cannot be found.
    fn register_edges(conn: &Connection) -> Result<()> {
        conn.create_scalar_function(
            "maxpane_edges",
            1,
            FunctionFlags::SQLITE_UTF8
                | FunctionFlags::SQLITE_DETERMINISTIC
                | FunctionFlags::SQLITE_INNOCUOUS,
            |ctx| Ok(crate::history::edges(ctx.get_raw(0).as_str().unwrap_or_default())),
        )?;
        Ok(())
    }

    fn migrate(&mut self) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migration (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
            [],
        )?;
        for (name, sql) in MIGRATIONS {
            let done: Option<String> = self
                .conn
                .query_row("SELECT name FROM schema_migration WHERE name = ?1", [name], |r| r.get(0))
                .optional()?;
            if done.is_some() {
                continue;
            }
            let tx = self.conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.execute(
                "INSERT INTO schema_migration (name, applied_at) VALUES (?1, ?2)",
                params![name, crate::now_ms()],
            )?;
            tx.commit()?;
        }
        Ok(())
    }

    // ---- reads -------------------------------------------------------------

    /// Every lane in ordinal order, panes attached, top-to-bottom.
    pub fn lanes(&self) -> Result<Vec<Lane>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, ordinal, width_pt, title, project_root, project_source,
                    created_at, last_focus_at, keep_live, span,
                    dock_side, dock_mode, dock_width_pt
             FROM lane ORDER BY ordinal ASC",
        )?;
        let mut lanes: Vec<Lane> = stmt.query_map([], row_to_lane)?.collect::<rusqlite::Result<_>>()?;

        // One pass over every pane beats one query per lane at 150 lanes.
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state, height_weight, zoom
             FROM pane ORDER BY lane_id, position ASC",
        )?;
        let panes: Vec<Pane> = stmt.query_map([], row_to_pane)?.collect::<rusqlite::Result<_>>()?;

        let mut by_lane: std::collections::HashMap<&str, Vec<Pane>> = std::collections::HashMap::new();
        for p in &panes {
            by_lane.entry(p.lane_id.as_str()).or_default().push(p.clone());
        }
        for lane in &mut lanes {
            if let Some(v) = by_lane.remove(lane.id.as_str()) {
                lane.panes = v;
            }
        }
        Ok(lanes)
    }

    pub fn lane(&self, id: &str) -> Result<Lane> {
        let mut lane = self
            .conn
            .query_row(
                "SELECT id, ordinal, width_pt, title, project_root, project_source,
                        created_at, last_focus_at, keep_live, span,
                        dock_side, dock_mode, dock_width_pt FROM lane WHERE id = ?1",
                [id],
                row_to_lane,
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound { kind: "lane".into(), id: id.into() })?;
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state, height_weight, zoom
             FROM pane WHERE lane_id = ?1 ORDER BY position ASC",
        )?;
        lane.panes = stmt.query_map([id], row_to_pane)?.collect::<rusqlite::Result<_>>()?;
        Ok(lane)
    }

    pub fn pane(&self, id: &str) -> Result<Pane> {
        self.conn
            .query_row(
                "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                        data_store_id, snapshot_path, state, height_weight, zoom FROM pane WHERE id = ?1",
                [id],
                row_to_pane,
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound { kind: "pane".into(), id: id.into() })
    }

    /// The ordinals bracketing a placement, as (before, after).
    pub fn neighbours(&self, placement: &Placement) -> Result<(Option<f64>, Option<f64>)> {
        Ok(match placement {
            Placement::End => (
                self.conn.query_row("SELECT MAX(ordinal) FROM lane", [], |r| r.get::<_, Option<f64>>(0))?,
                None,
            ),
            Placement::RightOf { lane_id } => {
                let o = self.ordinal_of(lane_id)?;
                let next: Option<f64> =
                    self.conn
                        .query_row("SELECT MIN(ordinal) FROM lane WHERE ordinal > ?1", [o], |r| r.get(0))?;
                (Some(o), next)
            }
            Placement::LeftOf { lane_id } => {
                let o = self.ordinal_of(lane_id)?;
                let prev: Option<f64> =
                    self.conn
                        .query_row("SELECT MAX(ordinal) FROM lane WHERE ordinal < ?1", [o], |r| r.get(0))?;
                (prev, Some(o))
            }
        })
    }

    pub fn ordinal_of(&self, lane_id: &str) -> Result<f64> {
        self.conn
            .query_row("SELECT ordinal FROM lane WHERE id = ?1", [lane_id], |r| r.get(0))
            .optional()?
            .ok_or_else(|| CoreError::NotFound { kind: "lane".into(), id: lane_id.into() })
    }

    pub fn app_state(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM app_state WHERE key = ?1", [key], |r| r.get(0))
            .optional()?)
    }

    // ---- writes ------------------------------------------------------------

    pub fn set_app_state(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO app_state (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn insert_lane(&self, lane: &Lane) -> Result<()> {
        self.conn.execute(
            "INSERT INTO lane (id, ordinal, width_pt, title, project_root, project_source,
                               created_at, last_focus_at, keep_live, span,
                               dock_side, dock_mode, dock_width_pt)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                lane.id,
                lane.ordinal,
                lane.width_pt,
                lane.title,
                lane.project_root,
                project_source_str(lane.project_source),
                lane.created_at,
                lane.last_focus_at,
                lane.keep_live as i32,
                lane.span,
                lane.dock.map(|d| dock_side_str(d.side)),
                lane.dock.map(|d| dock_mode_str(d.mode)),
                lane.dock.map(|d| d.width_pt),
            ],
        )?;
        Ok(())
    }

    pub fn set_span(&self, lane_id: &str, span: u32) -> Result<()> {
        self.conn.execute("UPDATE lane SET span = ?2 WHERE id = ?1", params![lane_id, span])?;
        Ok(())
    }

    pub fn insert_pane(&self, pane: &Pane) -> Result<()> {
        self.conn.execute(
            "INSERT INTO pane (id, lane_id, position, kind, relay_session_id, url, scroll_y,
                               data_store_id, snapshot_path, state, height_weight, zoom)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                pane.id,
                pane.lane_id,
                pane.position,
                kind_str(pane.kind),
                pane.relay_session_id,
                pane.url,
                pane.scroll_y,
                pane.data_store_id,
                pane.snapshot_path,
                state_str(pane.state),
                pane.height_weight,
                pane.zoom,
            ],
        )?;
        Ok(())
    }

    pub fn set_ordinal(&self, lane_id: &str, ordinal: f64) -> Result<()> {
        let n = self.conn.execute("UPDATE lane SET ordinal = ?2 WHERE id = ?1", params![lane_id, ordinal])?;
        if n == 0 {
            return Err(CoreError::NotFound { kind: "lane".into(), id: lane_id.into() });
        }
        Ok(())
    }

    /// Rewrite every ordinal to an even `STEP` spacing, preserving current order.
    /// Called when a midpoint insert runs out of room.
    pub fn renormalize(&mut self) -> Result<()> {
        let ids: Vec<String> = {
            let mut stmt = self.conn.prepare("SELECT id FROM lane ORDER BY ordinal ASC")?;
            let ids = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            ids
        };
        let tx = self.conn.transaction()?;
        for (i, id) in ids.iter().enumerate() {
            tx.execute(
                "UPDATE lane SET ordinal = ?2 WHERE id = ?1",
                params![id, i as f64 * crate::ordinal::STEP],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn delete_lane(&self, lane_id: &str) -> Result<()> {
        self.conn.execute("DELETE FROM lane WHERE id = ?1", [lane_id])?;
        Ok(())
    }

    /// Remove a pane and close the gap in its lane's stack.
    pub fn delete_pane(&mut self, pane_id: &str) -> Result<String> {
        let pane = self.pane(pane_id)?;
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM pane WHERE id = ?1", [pane_id])?;
        tx.execute(
            "UPDATE pane SET position = position - 1 WHERE lane_id = ?1 AND position > ?2",
            params![pane.lane_id, pane.position],
        )?;
        tx.commit()?;
        Ok(pane.lane_id)
    }

    /// Move a pane into `lane_id`'s stack, landing at `index` among the panes
    /// already there — counted **without** this one.
    ///
    /// Returns the lane it came out of, so the caller can decide what to do
    /// with a column that is now empty.
    ///
    /// `position` is a dense `0..n` in both lanes when this returns, and that
    /// is the whole reason this is one transaction rather than a delete and an
    /// insert. Half of it is a lane with two panes at position 1, which
    /// `lanes()` orders by whatever SQLite feels like — a stack that
    /// rearranges itself on the next launch, which is exactly the failure
    /// PRD §6's commit-before-you-animate rule exists to make impossible.
    ///
    /// The shape is deliberately `move_bookmark_to`'s, down to the correlated
    /// subquery that closes the gap in the source: these are the same problem —
    /// a row leaving one ordered sibling list and joining another — and two
    /// implementations of it is how they come to disagree about what an index
    /// counts.
    ///
    /// `height_weight` is `Some` only for a move that changes lane. Heights are
    /// shares of a column, so a share carried over from a different column
    /// means nothing; a reorder *inside* one lane must leave every weight
    /// bit-identical, which is what `None` says.
    pub fn move_pane_to(
        &mut self,
        pane_id: &str,
        lane_id: &str,
        index: u32,
        height_weight: Option<f64>,
    ) -> Result<String> {
        let pane = self.pane(pane_id)?;
        // Existence, before anything is written: reparenting a pane onto a lane
        // that is not there would leave it unreachable from `lanes()` and
        // therefore invisible, with nothing on screen to say where it went.
        self.ordinal_of(lane_id)?;
        let from = pane.lane_id;
        if let Some(weight) = height_weight {
            if !weight.is_finite() || weight <= 0.0 {
                return Err(CoreError::Ledger {
                    message: format!("height weight must be positive and finite, got {weight}"),
                });
            }
        }

        let tx = self.conn.transaction()?;

        // Ordered ids of the stack it is joining, with the pane itself taken
        // out first: a move within one lane is the common case, and leaving it
        // in would make "put it at index 2" mean two different things depending
        // on which side of 2 it started.
        let mut siblings: Vec<String> = {
            let mut stmt =
                tx.prepare("SELECT id FROM pane WHERE lane_id = ?1 ORDER BY position, id")?;
            let ids: Vec<String> =
                stmt.query_map([lane_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            ids
        };
        siblings.retain(|s| s != pane_id);
        let at = (index as usize).min(siblings.len());
        siblings.insert(at, pane_id.to_string());

        {
            let mut stmt =
                tx.prepare("UPDATE pane SET lane_id = ?2, position = ?3 WHERE id = ?1")?;
            for (position, sibling) in siblings.iter().enumerate() {
                stmt.execute(params![sibling, lane_id, position as i64])?;
            }
        }

        if let Some(weight) = height_weight {
            tx.execute(
                "UPDATE pane SET height_weight = ?2 WHERE id = ?1",
                params![pane_id, weight],
            )?;
        }

        // The lane it came out of is left dense too, for the reason
        // `delete_pane` closes its gap: nothing reads the hole, but a sparse
        // column is one whose next value is not obvious to whoever writes here
        // next — and `next_position` is `MAX + 1`, which a hole makes a lie.
        if from != lane_id {
            tx.execute(
                "UPDATE pane SET position = (
                     SELECT COUNT(*) FROM pane s
                      WHERE s.lane_id = pane.lane_id AND s.position < pane.position
                 ) WHERE lane_id = ?1",
                params![from],
            )?;
        }
        tx.commit()?;
        Ok(from)
    }

    /// Move every pane of `from_lane` into `into_lane`'s stack, in the order
    /// they already stand, starting at `index` among the panes already there —
    /// and delete `from_lane`, in the same transaction.
    ///
    /// `move_pane_to` once per pane would be a stack of commits with a lane
    /// holding half its panes between two of them, and a `kill -9` there
    /// leaves a column that is neither where it was nor where it was dropped.
    /// The delete is inside for the same reason: an empty lane surviving a
    /// crash is a header on the strip with nothing under it.
    ///
    /// `weights` names each arriving pane's new `height_weight`, and must name
    /// all of them. The deletion comes last because `pane.lane_id` cascades.
    pub fn merge_lane_into(
        &mut self,
        from_lane: &str,
        into_lane: &str,
        index: u32,
        weights: &[(String, f64)],
    ) -> Result<()> {
        if from_lane == into_lane {
            return Err(CoreError::Invalid { message: "a lane cannot be merged into itself".into() });
        }
        self.ordinal_of(from_lane)?;
        self.ordinal_of(into_lane)?;
        if let Some((_, w)) = weights.iter().find(|(_, w)| !w.is_finite() || *w <= 0.0) {
            return Err(CoreError::Ledger {
                message: format!("height weight must be positive and finite, got {w}"),
            });
        }

        let tx = self.conn.transaction()?;
        let ids_of = |lane: &str| -> Result<Vec<String>> {
            let mut stmt =
                tx.prepare("SELECT id FROM pane WHERE lane_id = ?1 ORDER BY position, id")?;
            let ids = stmt.query_map([lane], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            Ok(ids)
        };
        let arriving = ids_of(from_lane)?;
        let mut stack = ids_of(into_lane)?;
        let at = (index as usize).min(stack.len());
        stack.splice(at..at, arriving.iter().cloned());

        {
            let mut stmt =
                tx.prepare("UPDATE pane SET lane_id = ?2, position = ?3 WHERE id = ?1")?;
            for (position, id) in stack.iter().enumerate() {
                stmt.execute(params![id, into_lane, position as i64])?;
            }
            let mut stmt = tx.prepare("UPDATE pane SET height_weight = ?2 WHERE id = ?1")?;
            for (id, weight) in weights {
                if arriving.contains(id) {
                    stmt.execute(params![id, weight])?;
                }
            }
        }
        tx.execute("DELETE FROM lane WHERE id = ?1", [from_lane])?;
        tx.commit()?;
        Ok(())
    }

    pub fn update_lane_tag(&self, lane_id: &str, root: Option<&str>, source: ProjectSource) -> Result<()> {
        self.conn.execute(
            "UPDATE lane SET project_root = ?2, project_source = ?3 WHERE id = ?1",
            params![lane_id, root, project_source_str(source)],
        )?;
        Ok(())
    }

    pub fn update_lane_title(&self, lane_id: &str, title: Option<&str>) -> Result<()> {
        self.conn.execute("UPDATE lane SET title = ?2 WHERE id = ?1", params![lane_id, title])?;
        Ok(())
    }

    pub fn update_lane_width(&self, lane_id: &str, width_pt: u32) -> Result<()> {
        self.conn.execute("UPDATE lane SET width_pt = ?2 WHERE id = ?1", params![lane_id, width_pt])?;
        Ok(())
    }

    pub fn set_keep_live(&self, lane_id: &str, keep_live: bool) -> Result<()> {
        self.conn
            .execute("UPDATE lane SET keep_live = ?2 WHERE id = ?1", params![lane_id, keep_live as i32])?;
        Ok(())
    }

    /// Claim an edge for `lane_id`, or release the one it holds.
    ///
    /// One transaction, with the incumbent's release inside it. The unique
    /// index in migration 0007 makes two lanes on one edge impossible, which
    /// means the two-statement version of this does not produce a wrong strip —
    /// it produces a *failure*, on the second press of dock-left, which is
    /// worse. The user pressed dock-left on this lane and meant it, so whoever
    /// held the edge gives it up and goes back to scrolling with the strip at
    /// the ordinal it never stopped holding.
    pub fn set_dock(&mut self, lane_id: &str, dock: Option<Dock>) -> Result<()> {
        const CLEAR: &str = "UPDATE lane SET dock_side = NULL, dock_mode = NULL, dock_width_pt = NULL";
        let tx = self.conn.transaction()?;
        match dock {
            None => {
                tx.execute(&format!("{CLEAR} WHERE id = ?1"), params![lane_id])?;
            }
            Some(d) => {
                tx.execute(
                    &format!("{CLEAR} WHERE dock_side = ?1 AND id <> ?2"),
                    params![dock_side_str(d.side), lane_id],
                )?;
                let n = tx.execute(
                    "UPDATE lane SET dock_side = ?2, dock_mode = ?3, dock_width_pt = ?4 WHERE id = ?1",
                    params![lane_id, dock_side_str(d.side), dock_mode_str(d.mode), d.width_pt],
                )?;
                if n == 0 {
                    return Err(CoreError::NotFound { kind: "lane".into(), id: lane_id.into() });
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn touch_focus(&self, lane_id: &str, at: i64) -> Result<()> {
        self.conn.execute("UPDATE lane SET last_focus_at = ?2 WHERE id = ?1", params![lane_id, at])?;
        Ok(())
    }

    pub fn update_pane_url(&self, pane_id: &str, url: &str) -> Result<()> {
        self.conn.execute("UPDATE pane SET url = ?2 WHERE id = ?1", params![pane_id, url])?;
        Ok(())
    }

    pub fn update_pane_scroll(&self, pane_id: &str, scroll_y: f64) -> Result<()> {
        self.conn.execute("UPDATE pane SET scroll_y = ?2 WHERE id = ?1", params![pane_id, scroll_y])?;
        Ok(())
    }

    /// `WKWebView.interactionState`, deliberately not part of `Pane`.
    ///
    /// It is tens of kilobytes per pane and it is read exactly once, when the
    /// web view is built. Carrying it in the record would copy every pane's
    /// blob across the FFI on every layout mutation — at 150 lanes, megabytes
    /// per keystroke — to serve a read that happens once per pane per launch.
    pub fn update_pane_interaction_state(&self, pane_id: &str, state: Option<&[u8]>) -> Result<()> {
        self.conn.execute(
            "UPDATE pane SET interaction_state = ?2 WHERE id = ?1",
            params![pane_id, state],
        )?;
        Ok(())
    }

    pub fn pane_interaction_state(&self, pane_id: &str) -> Result<Option<Vec<u8>>> {
        Ok(self
            .conn
            .query_row("SELECT interaction_state FROM pane WHERE id = ?1", [pane_id], |r| {
                r.get::<_, Option<Vec<u8>>>(0)
            })
            .optional()?
            .flatten())
    }

    // ---- recents -----------------------------------------------------------

    /// Record a launch, or bump the one already there.
    pub fn note_recent(
        &self,
        kind: RecentKind,
        value: &str,
        cwd: Option<&str>,
        now_ms: i64,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO recent (kind, value, cwd, seq, last_used_at, use_count)
             VALUES (?1, ?2, ?3, (SELECT COALESCE(MAX(seq), 0) + 1 FROM recent), ?4, 1)
             ON CONFLICT(kind, value) DO UPDATE SET
                 seq = excluded.seq,
                 last_used_at = excluded.last_used_at,
                 use_count = use_count + 1,
                 -- The directory follows the command: running `npm test` in a
                 -- different repo should offer that repo next time, not the one
                 -- it first ran in a month ago.
                 cwd = COALESCE(excluded.cwd, cwd)",
            params![recent_kind_str(kind), value, cwd, now_ms],
        )?;
        Ok(())
    }

    /// Most recent first.
    pub fn recents(&self, limit: u32) -> Result<Vec<Recent>> {
        let mut stmt = self.conn.prepare(
            "SELECT kind, value, cwd, last_used_at, use_count
             FROM recent ORDER BY seq DESC LIMIT ?1",
        )?;
        let rows: Vec<Recent> = stmt
            .query_map([limit], row_to_recent)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    pub fn forget_recent(&self, kind: RecentKind, value: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM recent WHERE kind = ?1 AND value = ?2",
            params![recent_kind_str(kind), value],
        )?;
        Ok(())
    }

    // ---- site permissions ---------------------------------------------------

    /// What the user last said about this site, in this cookie jar, for this
    /// feature. `None` means they have never been asked, which is the only
    /// state that may raise a prompt.
    pub fn site_permission(
        &self,
        data_store_id: &str,
        origin: &str,
        feature: SiteFeature,
    ) -> Result<Option<bool>> {
        let found: Option<i64> = self
            .conn
            .query_row(
                "SELECT allowed FROM site_permission
                 WHERE data_store_id = ?1 AND origin = ?2 AND feature = ?3",
                params![data_store_id, origin, site_feature_str(feature)],
                |r| r.get(0),
            )
            .optional()?;
        Ok(found.map(|v| v != 0))
    }

    pub fn set_site_permission(
        &self,
        data_store_id: &str,
        origin: &str,
        feature: SiteFeature,
        allowed: bool,
        now_ms: i64,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO site_permission (data_store_id, origin, feature, allowed, decided_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(data_store_id, origin, feature) DO UPDATE SET
                 allowed = excluded.allowed,
                 decided_at = excluded.decided_at",
            params![
                data_store_id,
                origin,
                site_feature_str(feature),
                allowed as i64,
                now_ms
            ],
        )?;
        Ok(())
    }

    /// Undo every remembered decision for a site, so it is asked again next
    /// time. The only way back from a `Block` the user regrets — a permission
    /// that cannot be revoked is worse than one that is never remembered.
    pub fn forget_site_permissions(&self, data_store_id: &str, origin: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM site_permission WHERE data_store_id = ?1 AND origin = ?2",
            params![data_store_id, origin],
        )?;
        Ok(())
    }

    // ---- history -----------------------------------------------------------

    /// The text a query is matched against, as one string per entry.
    ///
    /// URL, then title, then every alias, newline-separated — and lowercase,
    /// which is the point: the ranker needs a lowercase string and folding one
    /// per row per keystroke was, measured at 112 840 rows, a larger cost than
    /// the matching. Folded once at write time it is free forever.
    ///
    /// It exists twice — here and in the `INSERT … SELECT` of migration 0009 —
    /// because the migration has to backfill ledgers this code will never see
    /// written. `a_ledger_written_before_the_index_is_backfilled` is what keeps
    /// the two agreeing.
    /// Addresses are stored with the scheme already off, which is
    /// `search_handle`'s job in Rust done once at write time. It is not a
    /// saving of eight bytes a row: `htt`, `tps` and `://` were otherwise
    /// substrings of every URL in the table, so the third character of a
    /// perfectly ordinary search matched the entire corpus and the index
    /// narrowed nothing. `normalize_url` guarantees the `scheme://`, so the
    /// `instr` cannot come back 0 for a row that is in this table.
    const HAYSTACK_SQL: &'static str =
        "lower(substr(v.url, instr(v.url, '://') + 3)) || char(10) ||
         lower(COALESCE(v.title, '')) || char(10) ||
         lower(COALESCE((SELECT group_concat(substr(a.alias_url, instr(a.alias_url, '://') + 3),
                                             char(10))
                           FROM visit_alias a WHERE a.url = v.url), ''))";

    /// Put one entry's searchable text back in step with its row.
    ///
    /// Called after every write that can change what an entry matches — a
    /// visit, a title arriving late, a redirect source being learned. Cheap
    /// enough to do unconditionally: it is two statements against one rowid,
    /// on a path that already did an upsert.
    fn reindex_visit(&self, url: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM visit_search WHERE rowid = (SELECT rowid FROM visit WHERE url = ?1)",
            [url],
        )?;
        self.conn.execute(
            &format!(
                "INSERT INTO visit_search (rowid, haystack, edges, seq)
                 SELECT rid, hay, maxpane_edges(hay), sq
                   FROM (SELECT v.rowid AS rid, {} AS hay, v.seq AS sq
                           FROM visit v WHERE v.url = ?1)",
                Self::HAYSTACK_SQL
            ),
            [url],
        )?;
        Ok(())
    }

    /// Record a settle, or bump the entry already there.
    ///
    /// `url` must already be normalized ([`crate::history::normalize_url`]);
    /// this is the write, not the policy.
    pub fn record_visit(&self, url: &str, title: Option<&str>, now_ms: i64) -> Result<()> {
        self.conn.execute(
            "INSERT INTO visit (url, title, seq, first_visit_at, last_visit_at, visit_count)
             VALUES (?1, ?2, (SELECT COALESCE(MAX(seq), 0) + 1 FROM visit), ?3, ?3, 1)
             ON CONFLICT(url) DO UPDATE SET
                 seq = excluded.seq,
                 last_visit_at = excluded.last_visit_at,
                 visit_count = visit_count + 1,
                 -- A page that arrives titled and then fires again before its
                 -- <title> has parsed would otherwise blank the name the entry
                 -- is findable by. A later title may replace an earlier one;
                 -- nothing may replace one with nothing.
                 title = COALESCE(NULLIF(?2, ''), title)",
            params![url, title, now_ms],
        )?;
        self.reindex_visit(url)
    }

    /// Name an entry that already exists, without counting a visit.
    ///
    /// `WKWebView.title` is usually still empty when the navigation finishes —
    /// the document's `<title>` lands a beat later — so the shell learns the
    /// name second. That is a correction to a visit, not another one, and a
    /// method that could insert would turn a slow title into a phantom row for
    /// a page that was never reached.
    pub fn name_visit(&self, url: &str, title: &str) -> Result<()> {
        if title.is_empty() {
            return Ok(());
        }
        let changed = self
            .conn
            .execute("UPDATE visit SET title = ?2 WHERE url = ?1", params![url, title])?;
        if changed > 0 {
            self.reindex_visit(url)?;
        }
        Ok(())
    }

    /// Remember that `alias` redirected to `url`.
    ///
    /// Silently does nothing when `url` has no entry: the foreign key would
    /// reject it anyway, and an alias is a detail of a visit rather than a
    /// reason to fail one.
    pub fn note_visit_alias(&self, alias: &str, url: &str) -> Result<()> {
        if alias == url {
            return Ok(());
        }
        let changed = self.conn.execute(
            "INSERT INTO visit_alias (alias_url, url)
             SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM visit WHERE url = ?2)
             ON CONFLICT(alias_url) DO UPDATE SET url = excluded.url",
            params![alias, url],
        )?;
        if changed > 0 {
            self.reindex_visit(url)?;
        }
        Ok(())
    }

    /// Turn a page that turned out to be a bounce into an alias of where it
    /// bounced to.
    ///
    /// A client-side redirect is indistinguishable from a page until the moment
    /// it redirects: `location.replace` and `<meta refresh>` both finish loading
    /// first, so by the time the shell knows, the interstitial is already an
    /// entry — with no title, because a bounce page rarely has one. Measured on
    /// the owner's corpus: `youtu.be/…` produced three rows and none of them
    /// was the address he typed.
    ///
    /// Its own aliases move with it, so a three-hop chain collapses to one
    /// entry and every address along the way stays searchable.
    ///
    /// Unconditional, rather than sparing an entry with several visits: a URL
    /// that bounces bounces every time, and "I have been here twice" is not
    /// evidence that it was ever a page. The cost of being wrong is one row
    /// that is findable by its own address instead of listed under it.
    pub fn demote_to_alias(&self, bounce: &str, destination: &str) -> Result<()> {
        if bounce == destination {
            return Ok(());
        }
        // Before the delete: the cascade would take these with it.
        self.conn.execute(
            "UPDATE visit_alias SET url = ?2 WHERE url = ?1",
            params![bounce, destination],
        )?;
        self.forget_visit(bounce)?;
        self.note_visit_alias(bounce, destination)
    }

    /// The newest `limit` pages, most recent first — the answer to an empty
    /// query, and the whole answer, because every row matches equally.
    pub fn history_newest(&self, limit: u32) -> Result<Vec<crate::model::HistoryEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT url, title, first_visit_at, last_visit_at, visit_count
               FROM visit ORDER BY seq DESC LIMIT ?1",
        )?;
        let rows = stmt
            .query_map([limit], |r| {
                Ok(crate::model::HistoryEntry {
                    url: r.get(0)?,
                    title: r.get(1)?,
                    first_visit_at: r.get(2)?,
                    last_visit_at: r.get(3)?,
                    visit_count: r.get::<_, i64>(4)? as u32,
                    matched_field: crate::model::SearchField::Url,
                    score: 0,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Score every row the FTS5 expression `query` matches.
    ///
    /// One place, because the narrowings above differ only in what they ask the
    /// index — what is done with a candidate row is the same scan of the same
    /// borrowed text either way.
    fn offer_matching(&self, ranking: &mut crate::history::Ranking<'_>, query: &str) -> Result<()> {
        let mut stmt = self
            .conn
            .prepare("SELECT rowid, haystack, seq FROM visit_search WHERE visit_search MATCH ?1")?;
        let mut rows = stmt.query(params![query])?;
        while let Some(r) = rows.next()? {
            let hay: &str = r.get_ref(1)?.as_str().unwrap_or_default();
            ranking.offer(r.get(0)?, r.get(2)?, crate::history::Haystack::new(hay));
        }
        Ok(())
    }

    /// How many rows the expression matches, without reading one of them.
    ///
    /// Measured on the owner's 108 855 pages: walking the posting list for the
    /// 21 501 rows a field of which starts with `g` costs 0.87 ms, and reading
    /// those same rows out of the FTS5 content table costs 42.6 ms. The count
    /// is 2% of the read, which is what makes it worth asking first.
    fn matching_count(&self, query: &str) -> Result<i64> {
        let n = self.conn.query_row(
            "SELECT COUNT(*) FROM visit_search WHERE visit_search MATCH ?1",
            params![query],
            |r| r.get(0),
        )?;
        Ok(n)
    }

    /// The largest `visit.rowid`, which is O(1) on a rowid table and is the row
    /// count plus whatever has since been forgotten.
    ///
    /// A budget wants an order of magnitude, not a census: `COUNT(*)` over
    /// 108 855 rows walks the `url` index and costs milliseconds a keystroke,
    /// which is a large fraction of the query it is trying to protect.
    fn rowid_ceiling(&self) -> Result<i64> {
        let n = self
            .conn
            .query_row("SELECT MAX(rowid) FROM visit", [], |r| r.get::<_, Option<i64>>(0))?;
        Ok(n.unwrap_or(0))
    }

    /// The best `limit` pages for `needle`, best first.
    ///
    /// # Why the whole corpus is in play and it is still fast
    ///
    /// Round 1 scored the newest 2 000 rows and called the rest unreachable —
    /// a row at depth 2 499 sat in the table and could not be found while the
    /// footer counted it. There is no depth here. What replaces it is the
    /// index of migrations 0009 and 0011, used three ways:
    ///
    /// * **Three characters or more** — `MATCH` on the haystack column narrows
    ///   the table to the rows that literally contain them, and every one of
    ///   those is scored.
    /// * **One or two characters** — below the trigram tokenizer's floor the
    ///   haystack column has nothing to say, so the *shoulder* column of 0011
    ///   is asked instead: first for the rows a field of which starts with what
    ///   was typed, then for the rows a word of which does. See
    ///   [`crate::history::edges`].
    /// * **A needle nothing contains** — every row is scored. Which is
    ///   affordable only because the index stores the text: a row is scored
    ///   where it lies in the statement, lowercase already, with nothing
    ///   allocated per candidate. See [`crate::history::Haystack`].
    ///
    /// The last case is also what keeps `mxp` finding `max-pane`. A trigram
    /// index cannot see a subsequence, and the subsequence tier only ever
    /// applies when nothing matched literally — which is exactly when `MATCH`
    /// comes back empty and this falls through to the scan.
    ///
    /// # Why a narrowed answer is the same answer
    ///
    /// The index narrows; it never ranks. The haystack column can only drop
    /// rows that contain none of the typed characters anywhere, so what
    /// [`crate::history::Ranking`] sees is what an uncapped scan would have
    /// handed it.
    ///
    /// The shoulder column is narrower than that — it drops rows that contain
    /// the needle only mid-word — so it is trusted only where it provably
    /// cannot cost a row a place. [`crate::history::MatchTier`] puts 10 000
    /// between tiers and under 1 000 inside one, so every prefix match outranks
    /// every word-prefix match, which outranks every mid-word one. A shoulder
    /// query returns *every* row that can reach the tier it was asked about
    /// (the entries are a superset of the positions the ranker calls a prefix —
    /// see [`crate::history::edges`]), so once `offset + limit` of them have
    /// reached it, the rows left behind are all a tier lower and none of them
    /// could have been on the page. When fewer reach it, the tier below is in
    /// play and the whole table is read instead. Nothing is ever dropped for
    /// being slow to find: that was round 1's `0 OF 5013 PAGES`, and it is not
    /// being built a second door.
    pub fn history_search(
        &self,
        needle: &str,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<crate::model::HistoryEntry>> {
        let want = offset as usize + limit as usize;
        let mut ranking = crate::history::Ranking::new(needle);
        if needle.chars().count() >= crate::history::TRIGRAM_MIN_CHARS {
            self.offer_matching(&mut ranking, &fts_phrase(needle))?;
        } else {
            // Widest last: a field-start query is the most selective thing that
            // can still be complete, and on the owner's corpus it is what
            // answers 34 of the 36 first keystrokes. Each stage starts a fresh
            // `Ranking` rather than adding to the last, because the second
            // query's rows are a superset of the first's and offering a row
            // twice would count it twice.
            //
            // One budget for the pass, not one per stage: a field-start query
            // that comes back with too few prefix matches to fill the page has
            // still been paid for, and the word-start query after it has to fit
            // in what is left, or the two together cost more than the scan they
            // were avoiding.
            let mut budget = self.rowid_ceiling()? / SHOULDER_BUDGET_DIVISOR;
            for (shoulder, tier) in [
                (crate::history::EDGE_FIELD, crate::history::MatchTier::Prefix),
                (crate::history::EDGE_WORD, crate::history::MatchTier::WordPrefix),
            ] {
                let Some(q) = crate::history::edge_query(needle, shoulder) else { continue };
                let q = format!("edges : {}", fts_phrase(&q));
                let n = self.matching_count(&q)?;
                if n == 0 || n > budget {
                    continue;
                }
                budget -= n;
                let mut staged = crate::history::Ranking::new(needle);
                self.offer_matching(&mut staged, &q)?;
                if staged.hits_down_to(tier) >= want {
                    ranking = staged;
                    break;
                }
            }
        }
        if ranking.is_empty() {
            let mut stmt = self.conn.prepare("SELECT rowid, haystack, seq FROM visit_search")?;
            let mut rows = stmt.query([])?;
            while let Some(r) = rows.next()? {
                let hay: &str = r.get_ref(1)?.as_str().unwrap_or_default();
                ranking.offer(r.get(0)?, r.get(2)?, crate::history::Haystack::new(hay));
            }
        }
        // Ranked, then paged — never paged first. The ranking is over the whole
        // narrowed corpus, so row 61 is the 61st best answer and not the best
        // answer of a second batch; asking for `offset + limit` and dropping
        // the head is what makes "show more" continue the same list instead of
        // starting a new one. The cost of a deep page is the drop, which is
        // `offset` comparisons against a heap that was going to be built
        // anyway.
        let hits = ranking.finish(offset as usize + limit as usize);
        let hits = hits.into_iter().skip(offset as usize);
        // Only now is a row read. Fewer than `limit` point lookups on the
        // primary key, against a scan that would have read every column of
        // every match to find them.
        let mut stmt = self.conn.prepare(
            "SELECT url, title, first_visit_at, last_visit_at, visit_count
               FROM visit WHERE rowid = ?1",
        )?;
        let mut out = Vec::with_capacity(limit as usize);
        for hit in hits {
            let row = stmt
                .query_row([hit.rowid], |r| {
                    Ok(crate::model::HistoryEntry {
                        url: r.get(0)?,
                        title: r.get(1)?,
                        first_visit_at: r.get(2)?,
                        last_visit_at: r.get(3)?,
                        visit_count: r.get::<_, i64>(4)? as u32,
                        matched_field: hit.field,
                        score: hit.score,
                    })
                })
                .optional()?;
            // `None` would mean the index outlived its row, which every write
            // path here is written to prevent. Skipping rather than failing:
            // a search is not the place to discover it, and the palette showing
            // one row fewer beats the palette showing an error.
            if let Some(row) = row {
                out.push(row);
            }
        }
        Ok(out)
    }

    /// Drop one entry and every alias pointing at it.
    pub fn forget_visit(&self, url: &str) -> Result<()> {
        // Before the row goes: the index is keyed by its rowid.
        self.conn.execute(
            "DELETE FROM visit_search WHERE rowid = (SELECT rowid FROM visit WHERE url = ?1)",
            [url],
        )?;
        self.conn.execute("DELETE FROM visit WHERE url = ?1", [url])?;
        Ok(())
    }

    pub fn clear_history(&self) -> Result<()> {
        self.conn.execute("DELETE FROM visit_search", [])?;
        self.conn.execute("DELETE FROM visit", [])?;
        Ok(())
    }

    /// How many entries are on record. For the palette's footer, and for tests.
    pub fn history_count(&self) -> Result<u32> {
        Ok(self
            .conn
            .query_row("SELECT COUNT(*) FROM visit", [], |r| r.get::<_, i64>(0))? as u32)
    }

    /// The browse list: every page, newest first *by when it happened*, paged.
    ///
    /// # Why this is not `history_newest` with an offset
    ///
    /// `history_newest` orders by `seq`, and 0004 gives the reason: a wall clock
    /// has ties, and two settles inside one millisecond must not come back in
    /// whatever order SQLite feels like.
    ///
    /// A day-grouped view asks a different question. Its headers are computed
    /// from `last_visit_at`, and a header is only *true* if every row beneath it
    /// falls inside that day — which holds only when the list is ordered by the
    /// same field the day is read from. The two orderings agree for every visit
    /// this app records (`seq` and the clock advance together) and for every row
    /// an import writes (it re-derives `seq` from `last_visit_at` so another
    /// browser's pages interleave rather than stack on top). They part company
    /// exactly when the clock moves backwards — which is the case `seq` exists
    /// for. So the palette keeps `seq`, the calendar keeps the calendar, and
    /// `seq DESC` is the tie-break here so that paging a list with a hundred
    /// rows on one millisecond does not show the same row twice.
    ///
    /// `visit_age` from 0004 is the index this reads backwards, which is what it
    /// was left in place for.
    pub fn history_by_date(&self, offset: u32, limit: u32) -> Result<Vec<crate::model::HistoryEntry>> {
        let mut stmt = self.conn.prepare(
            "SELECT url, title, first_visit_at, last_visit_at, visit_count
               FROM visit ORDER BY last_visit_at DESC, seq DESC LIMIT ?2 OFFSET ?1",
        )?;
        let rows = stmt
            .query_map([offset, limit], |r| {
                Ok(crate::model::HistoryEntry {
                    url: r.get(0)?,
                    title: r.get(1)?,
                    first_visit_at: r.get(2)?,
                    last_visit_at: r.get(3)?,
                    visit_count: r.get::<_, i64>(4)? as u32,
                    matched_field: crate::model::SearchField::Url,
                    score: 0,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// How many pages were last visited in `[start_ms, end_ms)`.
    ///
    /// The number a day header carries, and the number the clear dialog says out
    /// loud before anything is deleted.
    ///
    /// Asked one day at a time rather than computed once as a `GROUP BY`,
    /// because the day boundaries are the *reader's*: they move with his
    /// timezone and jump an hour twice a year, and this crate has no timezone
    /// database and should not grow one to answer a question `Calendar` on the
    /// other side of the FFI already answers correctly. `visit_age` makes each
    /// call a range scan over the rows being counted rather than over the table.
    pub fn history_count_between(&self, start_ms: i64, end_ms: i64) -> Result<u32> {
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM visit WHERE last_visit_at >= ?1 AND last_visit_at < ?2",
            params![start_ms, end_ms],
            |r| r.get::<_, i64>(0),
        )? as u32)
    }

    /// Forget every page last visited at or after `cutoff_ms`, and say how many
    /// that was. A cutoff of `0` is everything.
    ///
    /// # One row per URL is felt here and nowhere else
    ///
    /// 0004 keeps one row per URL rather than one per navigation, which is what
    /// makes the palette one line per page instead of eleven lines for the PR
    /// you opened eleven times. The bill for that arrives here: a page first
    /// seen a year ago and reopened five minutes ago is *one* row whose
    /// `last_visit_at` is inside the last hour, so "forget the last hour" takes
    /// the year with it. Chrome, which keeps every visit, would delete only the
    /// one. There is no honest way to split a row that was never two rows — so
    /// the count this returns is a count of pages, the dialog above it says
    /// pages, and neither pretends to be counting visits.
    ///
    /// One transaction, because the index is deleted before the rows are. In
    /// the other order a failure leaves index entries pointing at rows that are
    /// gone; in this order, without a transaction, it leaves rows that exist and
    /// cannot be found by searching — the same silent hole the row cap was.
    pub fn clear_history_since(&self, cutoff_ms: i64) -> Result<u32> {
        // `unchecked_transaction` rather than `transaction`, which wants `&mut
        // self`: every reader of the ledger holds it behind one lock already, so
        // the borrow checker's version of that guarantee would mean making this
        // the only `&mut` method on the history path.
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM visit_search
              WHERE rowid IN (SELECT rowid FROM visit WHERE last_visit_at >= ?1)",
            [cutoff_ms],
        )?;
        let gone = tx.execute("DELETE FROM visit WHERE last_visit_at >= ?1", [cutoff_ms])?;
        tx.commit()?;
        Ok(gone as u32)
    }

    // ---- importing another browser's history -------------------------------

    // ---- bookmarks ---------------------------------------------------------

    /// The tree in the order it is drawn: every folder immediately followed by
    /// what is inside it, siblings by `position`.
    ///
    /// One recursive walk rather than a query per folder. The sort key is the
    /// chain of zero-padded positions from the bar down — `0000000002/0000000000`
    /// — which is the only ordering that puts a folder's children under the
    /// folder and nowhere else. Padded because it is compared as text: at ten
    /// digits, `position` would have to exceed two billion before `10` sorted
    /// before `9`, and the renumber in `remove_bookmark` keeps it near zero.
    const TREE_SQL: &'static str =
        "WITH RECURSIVE tree(id, parent_id, is_folder, url, title, position, added_at, depth, sort) AS (
           SELECT id, parent_id, is_folder, url, title, position, added_at, 0,
                  printf('%010d', position)
             FROM bookmark WHERE parent_id IS NULL
           UNION ALL
           SELECT b.id, b.parent_id, b.is_folder, b.url, b.title, b.position, b.added_at,
                  t.depth + 1, t.sort || '/' || printf('%010d', b.position)
             FROM bookmark b JOIN tree t ON b.parent_id = t.id
         )
         SELECT id, parent_id, is_folder, url, title, position, added_at, depth FROM tree";

    fn row_to_bookmark(r: &Row) -> rusqlite::Result<Bookmark> {
        Ok(Bookmark {
            id: r.get(0)?,
            parent_id: r.get(1)?,
            is_folder: r.get::<_, i64>(2)? != 0,
            url: r.get(3)?,
            title: r.get(4)?,
            position: r.get::<_, i64>(5)? as u32,
            added_at: r.get(6)?,
            depth: r.get::<_, i64>(7)? as u32,
        })
    }

    /// Everything, in tree order.
    pub fn bookmarks(&self) -> Result<Vec<Bookmark>> {
        let mut stmt = self.conn.prepare(&format!("{} ORDER BY sort", Self::TREE_SQL))?;
        let rows = stmt
            .query_map([], Self::row_to_bookmark)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// The folders alone, in the same order — what a "file this somewhere"
    /// control offers.
    pub fn bookmark_folders(&self) -> Result<Vec<Bookmark>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{} WHERE is_folder = 1 ORDER BY sort", Self::TREE_SQL))?;
        let rows = stmt
            .query_map([], Self::row_to_bookmark)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// One row, without walking the tree for it.
    ///
    /// `depth` comes back 0 here and it is the one place in this file that says
    /// something untrue about a row. It is what a single-row lookup can know
    /// without the recursive walk, the two callers (rename, remove) are about
    /// the row and not about where it sits, and the alternative is running the
    /// whole tree to answer a question about one node.
    pub fn bookmark(&self, id: &str) -> Result<Option<Bookmark>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, parent_id, is_folder, url, title, position, added_at, 0
               FROM bookmark WHERE id = ?1",
        )?;
        Ok(stmt.query_row([id], Self::row_to_bookmark).optional()?)
    }

    /// Every placement of one address. The star's question, and it is a list
    /// because the same page may be kept in two folders.
    pub fn bookmarks_for_url(&self, url: &str) -> Result<Vec<Bookmark>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, parent_id, is_folder, url, title, position, added_at, 0
               FROM bookmark WHERE url = ?1 ORDER BY added_at",
        )?;
        let rows = stmt
            .query_map([url], Self::row_to_bookmark)?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// `Documentation/Rust`, or `None` for a row on the bar.
    ///
    /// Walks upwards from the row rather than downwards from the bar, so the
    /// cost is the depth of one branch and not the size of the tree.
    pub fn folder_path(&self, id: &str) -> Result<Option<String>> {
        let mut names: Vec<String> = Vec::new();
        let mut cursor: Option<String> = self
            .conn
            .query_row("SELECT parent_id FROM bookmark WHERE id = ?1", [id], |r| r.get(0))
            .optional()?
            .flatten();
        // Bounded rather than `while let`: `move_bookmark_to` refuses to
        // build a cycle, and this is the read that would hang if one ever got
        // in anyway. A tree deeper than this is not one anybody is navigating.
        for _ in 0..64 {
            let Some(node) = cursor else { break };
            let row: Option<(String, Option<String>)> = self
                .conn
                .query_row("SELECT title, parent_id FROM bookmark WHERE id = ?1", [&node], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?;
            let Some((title, parent)) = row else { break };
            names.push(title);
            cursor = parent;
        }
        if names.is_empty() {
            return Ok(None);
        }
        names.reverse();
        Ok(Some(names.join("/")))
    }

    /// Add a page or a folder at the end of `parent`.
    ///
    /// At the end, always. "Newest first" is how history is read and the
    /// opposite of how a bar is: the folders on it are in the order they have
    /// been in for years, and an add that pushed everything one place along
    /// would move eight targets the user aims at by muscle memory.
    pub fn insert_bookmark(
        &self,
        parent_id: Option<&str>,
        is_folder: bool,
        url: Option<&str>,
        title: &str,
        now_ms: i64,
    ) -> Result<Bookmark> {
        if let Some(parent) = parent_id {
            let is_a_folder: Option<i64> = self
                .conn
                .query_row("SELECT is_folder FROM bookmark WHERE id = ?1", [parent], |r| r.get(0))
                .optional()?;
            match is_a_folder {
                Some(1) => {}
                // Not an error the user can cause through the app, and worth
                // refusing rather than writing: a row parented to a page is
                // invisible in the tree — `TREE_SQL` would still emit it, under
                // a "folder" that renders as a link — and nothing would ever
                // say why.
                _ => {
                    return Err(CoreError::Ledger {
                        message: format!("bookmark {parent} is not a folder"),
                    })
                }
            }
        }
        let position: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM bookmark WHERE parent_id IS ?1",
            params![parent_id],
            |r| r.get(0),
        )?;
        let id = crate::new_id();
        self.conn.execute(
            "INSERT INTO bookmark (id, parent_id, is_folder, url, title, position, added_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![id, parent_id, is_folder as i64, url, title, position, now_ms],
        )?;
        Ok(Bookmark {
            id,
            parent_id: parent_id.map(str::to_string),
            is_folder,
            url: url.map(str::to_string),
            title: title.to_string(),
            position: position as u32,
            added_at: now_ms,
            depth: 0,
        })
    }

    /// Rename one row. A bookmark's title is the user's, not the page's.
    pub fn rename_bookmark(&self, id: &str, title: &str) -> Result<()> {
        self.conn
            .execute("UPDATE bookmark SET title = ?2 WHERE id = ?1", params![id, title])?;
        Ok(())
    }

    /// Put one row at `index` among `parent_id`'s children, reparenting it if it
    /// is not there already. `None` for the index means the end.
    ///
    /// Refuses to put a folder inside its own subtree. That is the one move
    /// that detaches a branch from the bar entirely: `TREE_SQL` starts at
    /// `parent_id IS NULL` and walks down, so a cycle is not an infinite loop
    /// there — it is a subtree that silently stops existing, with its rows
    /// still in the table and reachable by nothing.
    ///
    /// # Why this renumbers instead of taking a fractional ordinal
    ///
    /// `ordinal.rs` exists to make an insert write one row instead of the whole
    /// strip, and the case for reaching for it here is that a bar the user drags
    /// through is exactly what it was written for. It still loses on this table,
    /// for three reasons that are about bookmarks rather than about ordinals.
    ///
    /// The saving is not there. A drag commits once, on drop, not once a frame —
    /// so the write it saves is one `UPDATE` per sibling in one transaction.
    /// Measured in release: 0.28 ms to renumber a folder of 47, which is the
    /// size of the owner's largest, and 2.7 ms for a folder of 1 000, which is
    /// larger than any bookmarks bar anyone has. The strip's problem was
    /// hundreds of lanes and a *live* drag writing every frame — a different
    /// shape of cost, not a bigger helping of this one.
    ///
    /// The sort key would have to change. `TREE_SQL` orders the tree by
    /// `printf('%010d', position)` joined down the branch, because that is the
    /// only key that keeps a folder's children under the folder. A `REAL`
    /// cannot be zero-padded into a text key without picking a width, a scale
    /// and a rounding, and getting any of them wrong reorders a bar silently.
    ///
    /// And dense positions are load-bearing elsewhere: `insert_bookmark` and
    /// `apply_bookmark_import` both append at `MAX(position) + 1`, and
    /// `remove_bookmark` closes the gap it leaves for the same reason. Making
    /// this column fractional means changing all four and the migration under
    /// them, to buy nothing measurable.
    ///
    /// If a folder ever does hold enough rows for 2.7 ms to matter, the switch
    /// is a migration and this one function; nothing above it knows how the
    /// order is stored.
    pub fn move_bookmark_to(
        &self,
        id: &str,
        parent_id: Option<&str>,
        index: Option<u32>,
    ) -> Result<()> {
        if let Some(parent) = parent_id {
            if parent == id || self.is_descendant(parent, id)? {
                return Err(CoreError::Ledger {
                    message: "a folder cannot be moved inside itself".into(),
                });
            }
        }
        let from: Option<Option<String>> = self
            .conn
            .query_row("SELECT parent_id FROM bookmark WHERE id = ?1", [id], |r| r.get(0))
            .optional()?;
        // A move of a row that is not there is not an error to raise at the
        // user: the sidebar's rows are a snapshot, and the row may have been
        // deleted between the drag starting and the drop landing.
        let Some(from) = from else { return Ok(()) };

        // One transaction because the row leaves one sibling list and joins
        // another. Half of that is a bar with two rows at position 3, which
        // `TREE_SQL` would order by whatever SQLite felt like — a bar that
        // rearranges itself on restart, which is the failure this is all for.
        let tx = self.conn.unchecked_transaction()?;

        // Ordered ids of where it is going, with the row itself taken out first:
        // a move within one folder is the common case, and leaving it in would
        // make "put it at index 3" mean two different things depending on which
        // side of 3 it started.
        let mut siblings: Vec<String> = {
            let mut stmt = tx.prepare(
                "SELECT id FROM bookmark WHERE parent_id IS ?1 ORDER BY position, added_at, id",
            )?;
            let ids: Vec<String> =
                stmt.query_map(params![parent_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            ids
        };
        siblings.retain(|s| s != id);
        let at = (index.unwrap_or(u32::MAX) as usize).min(siblings.len());
        siblings.insert(at, id.to_string());

        {
            let mut stmt =
                tx.prepare("UPDATE bookmark SET parent_id = ?2, position = ?3 WHERE id = ?1")?;
            for (position, sibling) in siblings.iter().enumerate() {
                stmt.execute(params![sibling, parent_id, position as i64])?;
            }
        }

        // The folder it came out of is left dense too, for the reason
        // `remove_bookmark` states: nothing reads the gap, but a sparse column
        // is one whose next value is not obvious to whoever writes here next.
        if from.as_deref() != parent_id {
            tx.execute(
                "UPDATE bookmark SET position = (
                     SELECT COUNT(*) FROM bookmark s
                      WHERE s.parent_id IS bookmark.parent_id AND s.position < bookmark.position
                 ) WHERE parent_id IS ?1",
                params![from],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// The ids of one folder's children, in the order the bar draws them.
    ///
    /// Its one caller is the nudge, which needs to know what is above and below
    /// a row without reading the whole tree to find out.
    pub fn bookmark_siblings(&self, parent_id: Option<&str>) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT id FROM bookmark WHERE parent_id IS ?1 ORDER BY position, added_at, id",
        )?;
        let rows = stmt
            .query_map(params![parent_id], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    fn is_descendant(&self, node: &str, ancestor: &str) -> Result<bool> {
        let mut cursor = Some(node.to_string());
        for _ in 0..64 {
            let Some(current) = cursor else { return Ok(false) };
            if current == ancestor {
                return Ok(true);
            }
            cursor = self
                .conn
                .query_row("SELECT parent_id FROM bookmark WHERE id = ?1", [&current], |r| {
                    r.get(0)
                })
                .optional()?
                .flatten();
        }
        Ok(false)
    }

    /// Drop one row, and everything under it.
    ///
    /// The siblings it leaves behind are renumbered so that `position` stays a
    /// dense 0..n. Nothing reads the gap a delete would leave — the order is
    /// the same either way — but a sparse column is one whose next value is not
    /// obvious to the next person to write against it, and closing it is one
    /// statement over the tens of rows in a folder.
    pub fn remove_bookmark(&self, id: &str) -> Result<()> {
        let parent: Option<Option<String>> = self
            .conn
            .query_row("SELECT parent_id FROM bookmark WHERE id = ?1", [id], |r| r.get(0))
            .optional()?;
        let Some(parent) = parent else { return Ok(()) };
        self.conn.execute("DELETE FROM bookmark WHERE id = ?1", [id])?;
        self.conn.execute(
            "UPDATE bookmark SET position = (
                 SELECT COUNT(*) FROM bookmark s
                  WHERE s.parent_id IS bookmark.parent_id AND s.position < bookmark.position
             ) WHERE parent_id IS ?1",
            params![parent],
        )?;
        Ok(())
    }

    /// How many rows the tree holds, folders included.
    pub fn bookmark_count(&self) -> Result<u32> {
        Ok(self
            .conn
            .query_row("SELECT COUNT(*) FROM bookmark", [], |r| r.get::<_, i64>(0))?
            as u32)
    }

    /// Every kept page as `("Work/Rust", "https://…")`.
    ///
    /// The identity an import compares on. Not the URL alone: the same page in
    /// two folders is two bookmarks on purpose (see migration 0010), so a
    /// source row that names a folder this ledger does not have that page in is
    /// a row this ledger does not have.
    ///
    /// Built by reading the tree and walking it once here rather than asking
    /// SQLite for a recursive path per row: an import compares every source
    /// bookmark against it, and one pass over a few thousand rows is cheaper
    /// than a few thousand queries.
    pub fn bookmark_placements(&self) -> Result<std::collections::HashSet<(String, String)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, parent_id, title, url FROM bookmark")?;
        let rows: Vec<(String, Option<String>, String, Option<String>)> = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let by_id: std::collections::HashMap<&str, (Option<&str>, &str)> = rows
            .iter()
            .map(|(id, parent, title, _)| (id.as_str(), (parent.as_deref(), title.as_str())))
            .collect();
        let mut out = std::collections::HashSet::new();
        for (_, parent, _, url) in &rows {
            let Some(url) = url else { continue };
            let mut names = Vec::new();
            let mut cursor = parent.as_deref();
            for _ in 0..64 {
                let Some(node) = cursor else { break };
                let Some((up, title)) = by_id.get(node) else { break };
                names.push(*title);
                cursor = *up;
            }
            names.reverse();
            out.insert((names.join("/"), url.clone()));
        }
        Ok(out)
    }

    /// Write another browser's bookmarks into the tree.
    ///
    /// Returns what was written and what `Replace` dropped.
    ///
    /// # What "already here" means, and why merging twice is a no-op
    ///
    /// The same rule `import::fold` gives for pages, applied to a tree: a
    /// source bookmark is new when no row here has that address in that folder.
    /// Importing the same profile a second time therefore writes nothing —
    /// which is what makes the wizard's `Merge` safe to press twice, and it
    /// costs no second table recording what has been imported.
    ///
    /// What it does *not* do is update a bookmark that is already here. A
    /// bookmark's title is the user's (see [`Ledger::rename_bookmark`]), and a
    /// re-import that renamed his rows back to what Vivaldi calls them would be
    /// undoing the one edit this store exists to keep.
    pub fn apply_bookmark_import(
        &mut self,
        flat: &[crate::import::FlatBookmark],
        mode: crate::import::ImportMode,
        now_ms: i64,
    ) -> Result<(u32, u32)> {
        let existing = if mode == crate::import::ImportMode::Replace {
            self.bookmark_count()?
        } else {
            0
        };
        let known = match mode {
            crate::import::ImportMode::Merge => self.bookmark_placements()?,
            crate::import::ImportMode::Replace => std::collections::HashSet::new(),
        };
        let mut inserted = 0u32;
        self.transaction(|tx| {
            if mode == crate::import::ImportMode::Replace {
                tx.execute("DELETE FROM bookmark", [])?;
            }
            // Folder path -> id, seeded from what is already here so that a
            // merge files Vivaldi's `Work/Rust` into the `Work/Rust` the user
            // already has instead of making a second one beside it.
            let mut folders: std::collections::HashMap<String, String> =
                std::collections::HashMap::new();
            if mode == crate::import::ImportMode::Merge {
                let mut stmt =
                    tx.prepare("SELECT id, parent_id, title FROM bookmark WHERE is_folder = 1")?;
                let rows: Vec<(String, Option<String>, String)> = stmt
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<rusqlite::Result<_>>()?;
                let by_id: std::collections::HashMap<&str, (Option<&str>, &str)> = rows
                    .iter()
                    .map(|(id, p, t)| (id.as_str(), (p.as_deref(), t.as_str())))
                    .collect();
                for (id, parent, _) in &rows {
                    let mut names = Vec::new();
                    let mut cursor = parent.as_deref();
                    for _ in 0..64 {
                        let Some(node) = cursor else { break };
                        let Some((up, title)) = by_id.get(node) else { break };
                        names.push(*title);
                        cursor = *up;
                    }
                    names.reverse();
                    names.push(by_id[id.as_str()].1);
                    folders.insert(names.join("/"), id.clone());
                }
            }

            let mut next_position: std::collections::HashMap<Option<String>, i64> =
                std::collections::HashMap::new();
            let mut append = |tx: &rusqlite::Transaction<'_>,
                              parent: Option<&str>,
                              is_folder: bool,
                              url: Option<&str>,
                              title: &str,
                              added_at: i64|
             -> Result<String> {
                let key = parent.map(str::to_string);
                let position = match next_position.get(&key) {
                    Some(n) => *n,
                    None => tx.query_row(
                        "SELECT COALESCE(MAX(position), -1) + 1 FROM bookmark WHERE parent_id IS ?1",
                        params![parent],
                        |r| r.get::<_, i64>(0),
                    )?,
                };
                next_position.insert(key, position + 1);
                let id = crate::new_id();
                tx.execute(
                    "INSERT INTO bookmark (id, parent_id, is_folder, url, title, position, added_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![id, parent, is_folder as i64, url, title, position, added_at],
                )?;
                Ok(id)
            };

            for item in flat {
                if known.contains(&(item.folder.join("/"), item.url.clone())) {
                    continue;
                }
                // Every ancestor, in order, so `Work/Rust` under a `Work` this
                // pass has just created lands inside it rather than beside it.
                let mut parent: Option<String> = None;
                let mut path = String::new();
                for name in &item.folder {
                    if !path.is_empty() {
                        path.push('/');
                    }
                    path.push_str(name);
                    parent = Some(match folders.get(&path) {
                        Some(id) => id.clone(),
                        None => {
                            let id =
                                append(tx, parent.as_deref(), true, None, name, item.added_at)?;
                            folders.insert(path.clone(), id.clone());
                            inserted += 1;
                            id
                        }
                    });
                }
                let added_at = if item.added_at > 0 { item.added_at } else { now_ms };
                append(
                    tx,
                    parent.as_deref(),
                    false,
                    Some(&item.url),
                    &item.title,
                    added_at,
                )?;
                inserted += 1;
            }
            Ok(())
        })?;
        Ok((inserted, existing))
    }

    pub fn clear_bookmarks(&self) -> Result<()> {
        self.conn.execute("DELETE FROM bookmark", [])?;
        Ok(())
    }

    /// Copy the whole ledger to `dest`, through SQLite rather than the file
    /// system.
    ///
    /// `cp` is the wrong tool and the repo has already paid for learning it: a
    /// WAL is not part of the `.db` file, and the live one held 4 MB the day
    /// the profile migration was written. Same reason here, with a worse
    /// consequence — this backup is the only way back from a `Replace`.
    pub fn backup_to(&self, dest: &Path) -> Result<()> {
        let mut out = Connection::open(dest)?;
        let backup = rusqlite::backup::Backup::new(&self.conn, &mut out)?;
        backup.run_to_completion(1024, std::time::Duration::from_millis(50), None)?;
        Ok(())
    }

    /// How many of `pages` the ledger already has, by normalized URL.
    ///
    /// Staged into a temp table rather than asked one URL at a time: the
    /// count, the upsert and the report all want the same 112 000 rows, and
    /// three passes over one temp table is one `INSERT … SELECT` each instead
    /// of a third of a million round trips through rusqlite.
    fn stage_import(&self, pages: &[crate::import::SourcePage]) -> Result<u32> {
        self.conn.execute_batch(
            "DROP TABLE IF EXISTS temp.import_page;
             CREATE TEMP TABLE import_page (
               url TEXT PRIMARY KEY, title TEXT,
               first_visit_at INTEGER NOT NULL, last_visit_at INTEGER NOT NULL,
               visit_count INTEGER NOT NULL
             );",
        )?;
        {
            let mut stmt = self.conn.prepare(
                "INSERT INTO temp.import_page (url, title, first_visit_at, last_visit_at, visit_count)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(url) DO NOTHING",
            )?;
            for p in pages {
                stmt.execute(params![
                    p.url,
                    p.title,
                    p.first_visit_at,
                    p.last_visit_at,
                    p.visit_count as i64
                ])?;
            }
        }
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM temp.import_page i JOIN visit v ON v.url = i.url",
            [],
            |r| r.get::<_, i64>(0),
        )? as u32)
    }

    /// Count the overlap without writing anything. The wizard's dry run.
    pub fn preview_import(&self, pages: &[crate::import::SourcePage]) -> Result<u32> {
        let known = self.stage_import(pages)?;
        self.conn.execute_batch("DROP TABLE IF EXISTS temp.import_page;")?;
        Ok(known)
    }

    /// Fold `pages` in, or stand them in place of what is there.
    ///
    /// Returns `(inserted, updated, discarded)`. One transaction: an import is
    /// a hundred thousand rows, a total re-`seq` and a rebuilt index, and a
    /// ledger holding two of those three is not a ledger.
    pub fn apply_import(
        &mut self,
        pages: &[crate::import::SourcePage],
        mode: crate::import::ImportMode,
    ) -> Result<(u32, u32, u32)> {
        let known = self.stage_import(pages)?;
        let existing = self.history_count()?;
        let tx = self.conn.transaction()?;

        let discarded = match mode {
            crate::import::ImportMode::Merge => 0,
            crate::import::ImportMode::Replace => {
                tx.execute("DELETE FROM visit_search", [])?;
                // `visit_alias` goes with it by CASCADE, which is why the
                // ledger opens with `foreign_keys = ON`.
                tx.execute("DELETE FROM visit", [])?;
                existing
            }
        };

        // `seq` goes in as 0 and is assigned below, because the value it should
        // have depends on rows that are not written yet. Nothing ever observes
        // the 0: this is inside the transaction.
        tx.execute(
            "INSERT INTO visit (url, title, seq, first_visit_at, last_visit_at, visit_count)
             SELECT i.url, i.title, 0, i.first_visit_at, i.last_visit_at, i.visit_count
               FROM temp.import_page i
             -- Not decorative. With a `FROM` in the SELECT, SQLite's parser
             -- reads the next `ON` as a join constraint and the upsert is a
             -- syntax error; `WHERE true` is the disambiguator its own
             -- documentation prescribes.
             WHERE true
             ON CONFLICT(url) DO UPDATE SET
                 first_visit_at = MIN(visit.first_visit_at, excluded.first_visit_at),
                 last_visit_at  = MAX(visit.last_visit_at,  excluded.last_visit_at),
                 visit_count    = MAX(visit.visit_count,    excluded.visit_count),
                 -- The rule `record_visit` already follows, with the source's
                 -- clock deciding which name is later: a title may be replaced
                 -- by a title, never by nothing, and a page you last read in
                 -- Max Pane today keeps the name it had today rather than the
                 -- one Vivaldi saw in 2024.
                 title = CASE
                     WHEN visit.title IS NULL OR visit.title = '' THEN excluded.title
                     WHEN excluded.title IS NOT NULL AND excluded.title != ''
                          AND excluded.last_visit_at > visit.last_visit_at THEN excluded.title
                     ELSE visit.title END",
            [],
        )?;

        Self::reseq(&tx)?;
        Self::rebuild_search(&tx)?;
        tx.commit()?;
        self.conn.execute_batch("DROP TABLE IF EXISTS temp.import_page;")?;
        // Fold the import back into the database file.
        //
        // Every other write here is a lane moving and fits in the WAL's automatic
        // 1 000-page checkpoint; this one is a hundred thousand rows and a rebuilt
        // index, and measured against the owner's Vivaldi profile it left 320 MB
        // of WAL beside a 41 MB ledger. That is not wrong — it is what WAL is —
        // but it doubles the footprint until something else happens to trigger a
        // checkpoint, and the next launch is what pays. TRUNCATE rather than
        // PASSIVE so the file actually shrinks.
        //
        // Best-effort: a checkpoint that cannot run because a reader is mid-query
        // is a tidiness problem, and the import it would be failing has already
        // committed.
        let _ = self
            .conn
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));

        let (inserted, updated) = match mode {
            crate::import::ImportMode::Merge => (pages.len() as u32 - known, known),
            crate::import::ImportMode::Replace => (pages.len() as u32, 0),
        };
        Ok((inserted, updated, discarded))
    }

    /// Renumber every `seq` in the table by when the page was actually last
    /// seen.
    ///
    /// # This is the decision the feature turns on
    ///
    /// `seq` is a counter, not a clock (migration 0004), and an import that
    /// simply appended would take the top 112 840 values — so every page from
    /// the owner's 2024 would outrank everything he did this morning, and the
    /// MRU list ⌘O opens with would be a list from two years ago. The feature
    /// would be worse than not having it.
    ///
    /// Two ways out: interleave the import by its real timestamps, or stop
    /// making `seq` the only ordering key. The second is a migration, a new
    /// index, and a rewrite of `history_newest`, `Ranking`'s tie-break and the
    /// `seq UNINDEXED` column of the trigram index — to arrive at ordering by
    /// a wall clock, which 0004 rejected for the reason it gave: two settles
    /// inside one millisecond come back in whatever order SQLite feels like.
    ///
    /// So: interleave. And the way to interleave without a second ordering key
    /// is to re-derive the first one. `ORDER BY last_visit_at, seq` reproduces
    /// the existing rows' order *exactly* — for a row this app wrote, `seq` and
    /// `last_visit_at` were stamped by the same statement and both increase, so
    /// sorting by the clock and breaking ties on the old counter is the
    /// identity — while slotting imported rows into their real places. `seq`
    /// stays what 0004 made it: unique, total, and never ambiguous.
    ///
    /// The whole table, not just the new rows, because a merged row's
    /// `last_visit_at` can move: a page the source saw more recently than we
    /// did has genuinely changed position.
    fn reseq(tx: &rusqlite::Transaction<'_>) -> Result<()> {
        tx.execute(
            "UPDATE visit SET seq = o.n
               FROM (SELECT rowid AS rid,
                            ROW_NUMBER() OVER (ORDER BY last_visit_at ASC, seq ASC, rowid ASC) AS n
                       FROM visit) o
              WHERE visit.rowid = o.rid",
            [],
        )?;
        Ok(())
    }

    /// Rebuild the trigram index from the table.
    ///
    /// Wholesale rather than per row, because [`Self::reseq`] just changed the
    /// `seq` that rides along in every entry — a per-row reindex would be
    /// 112 000 delete-and-insert pairs to do what one pass does, and would
    /// leave the rows it had not reached yet carrying a `seq` that no longer
    /// exists. Measured at 543 ms for 112 840 rows when migration 0009 did the
    /// same thing.
    fn rebuild_search(tx: &rusqlite::Transaction<'_>) -> Result<()> {
        tx.execute("DELETE FROM visit_search", [])?;
        tx.execute(
            &format!(
                "INSERT INTO visit_search (rowid, haystack, edges, seq)
                 SELECT rid, hay, maxpane_edges(hay), sq
                   FROM (SELECT v.rowid AS rid, {} AS hay, v.seq AS sq FROM visit v)",
                Self::HAYSTACK_SQL
            ),
            [],
        )?;
        Ok(())
    }

    pub fn set_pane_evicted(
        &self,
        pane_id: &str,
        snapshot_path: Option<&str>,
        scroll_y: Option<f64>,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE pane SET state = 'evicted', kind = 'placeholder',
                             snapshot_path = ?2,
                             scroll_y = COALESCE(?3, scroll_y)
             WHERE id = ?1",
            params![pane_id, snapshot_path, scroll_y],
        )?;
        Ok(())
    }

    pub fn set_pane_live(&self, pane_id: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE pane SET state = 'live', kind = 'web', snapshot_path = NULL WHERE id = ?1",
            [pane_id],
        )?;
        Ok(())
    }

    pub fn set_pane_data_store(&self, pane_id: &str, data_store_id: &str) -> Result<()> {
        self.conn
            .execute("UPDATE pane SET data_store_id = ?2 WHERE id = ?1", params![pane_id, data_store_id])?;
        Ok(())
    }

    pub fn next_position(&self, lane_id: &str) -> Result<u32> {
        let max: Option<i64> =
            self.conn
                .query_row("SELECT MAX(position) FROM pane WHERE lane_id = ?1", [lane_id], |r| r.get(0))?;
        Ok(max.map(|m| m as u32 + 1).unwrap_or(0))
    }

    /// The weights already in a lane's stack, in stack order.
    /// Scale for one pane. Rejected at the boundary rather than clamped: a
    /// zero or a NaN here is a bug in the caller, and silently storing 1.0
    /// would hide it until someone wondered why their zoom never stuck.
    pub fn update_pane_zoom(&self, pane_id: &str, zoom: f64) -> Result<()> {
        if !zoom.is_finite() || zoom <= 0.0 {
            return Err(CoreError::Ledger { message: format!("zoom must be positive and finite, got {zoom}") });
        }
        self.conn.execute("UPDATE pane SET zoom = ?2 WHERE id = ?1", params![pane_id, zoom])?;
        Ok(())
    }

    pub fn height_weights(&self, lane_id: &str) -> Result<Vec<f64>> {
        let mut stmt = self
            .conn
            .prepare("SELECT height_weight FROM pane WHERE lane_id = ?1 ORDER BY position ASC")?;
        let weights = stmt.query_map([lane_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(weights)
    }

    /// Write a whole lane's worth of weights at once.
    ///
    /// One transaction, because a divider drag is one decision about *two*
    /// panes. Committing the pane that grew without the pane that shrank leaves
    /// a stack claiming more height than the lane has, and a `kill -9` inside
    /// that window is exactly what PRD §6's commit-before-you-animate rule is
    /// there to make impossible.
    pub fn set_height_weights(&mut self, weights: &[(String, f64)]) -> Result<()> {
        let tx = self.conn.transaction()?;
        for (pane_id, weight) in weights {
            tx.execute("UPDATE pane SET height_weight = ?2 WHERE id = ?1", params![pane_id, weight])?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn pair(&self, pty_pane_id: &str, web_pane_id: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO pairing (pty_pane_id, web_pane_id) VALUES (?1, ?2)",
            params![pty_pane_id, web_pane_id],
        )?;
        Ok(())
    }

    pub fn unpair(&self, pty_pane_id: &str, web_pane_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM pairing WHERE pty_pane_id = ?1 AND web_pane_id = ?2",
            params![pty_pane_id, web_pane_id],
        )?;
        Ok(())
    }

    pub fn pairs_of(&self, pane_id: &str) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT web_pane_id FROM pairing WHERE pty_pane_id = ?1
             UNION SELECT pty_pane_id FROM pairing WHERE web_pane_id = ?1",
        )?;
        let ids = stmt.query_map([pane_id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(ids)
    }

    /// Run `f` inside a transaction so a multi-row mutation is all-or-nothing.
    pub fn transaction<T>(&mut self, f: impl FnOnce(&rusqlite::Transaction) -> Result<T>) -> Result<T> {
        let tx = self.conn.transaction()?;
        let out = f(&tx)?;
        tx.commit()?;
        Ok(out)
    }
}

// ---- row mapping -----------------------------------------------------------

fn row_to_lane(r: &Row) -> rusqlite::Result<Lane> {
    Ok(Lane {
        id: r.get(0)?,
        ordinal: r.get(1)?,
        width_pt: r.get::<_, i64>(2)? as u32,
        title: r.get(3)?,
        project_root: r.get(4)?,
        project_source: parse_project_source(&r.get::<_, String>(5)?),
        created_at: r.get(6)?,
        last_focus_at: r.get(7)?,
        keep_live: r.get::<_, i64>(8)? != 0,
        span: r.get::<_, i64>(9)? as u32,
        // `dock_side` alone decides whether there is a dock; the other two
        // columns are read only once it says yes. A row someone hand-edited to
        // carry a side and nothing else therefore gets the defaults a fresh
        // dock would, rather than a strip that refuses to load.
        dock: r.get::<_, Option<String>>(10)?.and_then(|side| {
            parse_dock_side(&side).map(|side| Dock {
                side,
                mode: r
                    .get::<_, Option<String>>(11)
                    .ok()
                    .flatten()
                    .map(|m| parse_dock_mode(&m))
                    .unwrap_or(DockMode::Inset),
                width_pt: r
                    .get::<_, Option<i64>>(12)
                    .ok()
                    .flatten()
                    .map(|w| w as u32)
                    .unwrap_or(crate::LANE_MIN_PT),
            })
        }),
        panes: Vec::new(),
    })
}

fn row_to_pane(r: &Row) -> rusqlite::Result<Pane> {
    Ok(Pane {
        id: r.get(0)?,
        lane_id: r.get(1)?,
        position: r.get::<_, i64>(2)? as u32,
        kind: parse_kind(&r.get::<_, String>(3)?),
        relay_session_id: r.get(4)?,
        url: r.get(5)?,
        scroll_y: r.get(6)?,
        data_store_id: r.get(7)?,
        snapshot_path: r.get(8)?,
        state: parse_state(&r.get::<_, String>(9)?),
        height_weight: r.get(10)?,
        zoom: r.get(11)?,
    })
}

fn row_to_recent(r: &Row) -> rusqlite::Result<Recent> {
    Ok(Recent {
        kind: parse_recent_kind(&r.get::<_, String>(0)?),
        value: r.get(1)?,
        cwd: r.get(2)?,
        last_used_at: r.get(3)?,
        use_count: r.get::<_, i64>(4)? as u32,
    })
}

pub fn site_feature_str(f: SiteFeature) -> &'static str {
    match f {
        SiteFeature::Camera => "camera",
        SiteFeature::Microphone => "microphone",
    }
}

pub fn recent_kind_str(k: RecentKind) -> &'static str {
    match k {
        RecentKind::Command => "command",
        RecentKind::Url => "url",
    }
}

fn parse_recent_kind(s: &str) -> RecentKind {
    match s {
        "url" => RecentKind::Url,
        _ => RecentKind::Command,
    }
}

pub fn kind_str(k: PaneKind) -> &'static str {
    match k {
        PaneKind::Pty => "pty",
        PaneKind::Web => "web",
        PaneKind::Placeholder => "placeholder",
    }
}

fn parse_kind(s: &str) -> PaneKind {
    match s {
        "pty" => PaneKind::Pty,
        "placeholder" => PaneKind::Placeholder,
        _ => PaneKind::Web,
    }
}

pub fn state_str(s: PaneState) -> &'static str {
    match s {
        PaneState::Live => "live",
        PaneState::Evicted => "evicted",
    }
}

fn parse_state(s: &str) -> PaneState {
    match s {
        "evicted" => PaneState::Evicted,
        _ => PaneState::Live,
    }
}

pub fn project_source_str(s: ProjectSource) -> &'static str {
    match s {
        ProjectSource::Cwd => "cwd",
        ProjectSource::Inherited => "inherited",
        ProjectSource::Manual => "manual",
    }
}

pub fn dock_side_str(s: DockSide) -> &'static str {
    match s {
        DockSide::Left => "left",
        DockSide::Right => "right",
    }
}

/// `None` for anything this build does not recognise, which makes an
/// unreadable value an undocked lane rather than a strip that will not open.
fn parse_dock_side(s: &str) -> Option<DockSide> {
    match s {
        "left" => Some(DockSide::Left),
        "right" => Some(DockSide::Right),
        _ => None,
    }
}

pub fn dock_mode_str(m: DockMode) -> &'static str {
    match m {
        DockMode::Overlay => "overlay",
        DockMode::Inset => "inset",
    }
}

/// Inset is the fallback, not overlay. An unreadable mode should not silently
/// start covering a lane the user cannot see is there.
pub fn parse_dock_mode(s: &str) -> DockMode {
    match s {
        "overlay" => DockMode::Overlay,
        _ => DockMode::Inset,
    }
}

fn parse_project_source(s: &str) -> ProjectSource {
    match s {
        "cwd" => ProjectSource::Cwd,
        "manual" => ProjectSource::Manual,
        _ => ProjectSource::Inherited,
    }
}
