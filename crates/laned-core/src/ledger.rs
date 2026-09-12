//! SQLite persistence. Every layout mutation commits here before the shell is
//! allowed to animate it, so a `kill -9` can only ever lose the frame in flight.

use crate::error::{CoreError, Result};
use crate::model::*;
use rusqlite::{params, Connection, OptionalExtension, Row};
use std::path::Path;

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
];

pub struct Ledger {
    conn: Connection,
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
        let mut l = Ledger { conn };
        l.migrate()?;
        Ok(l)
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
                    created_at, last_focus_at, pinned, span
             FROM lane ORDER BY ordinal ASC",
        )?;
        let mut lanes: Vec<Lane> = stmt.query_map([], row_to_lane)?.collect::<rusqlite::Result<_>>()?;

        // One pass over every pane beats one query per lane at 150 lanes.
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state, height_weight
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
                        created_at, last_focus_at, pinned, span FROM lane WHERE id = ?1",
                [id],
                row_to_lane,
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound { kind: "lane".into(), id: id.into() })?;
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state, height_weight
             FROM pane WHERE lane_id = ?1 ORDER BY position ASC",
        )?;
        lane.panes = stmt.query_map([id], row_to_pane)?.collect::<rusqlite::Result<_>>()?;
        Ok(lane)
    }

    pub fn pane(&self, id: &str) -> Result<Pane> {
        self.conn
            .query_row(
                "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                        data_store_id, snapshot_path, state, height_weight FROM pane WHERE id = ?1",
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
                               created_at, last_focus_at, pinned, span)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                lane.id,
                lane.ordinal,
                lane.width_pt,
                lane.title,
                lane.project_root,
                project_source_str(lane.project_source),
                lane.created_at,
                lane.last_focus_at,
                lane.pinned as i32,
                lane.span,
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
                               data_store_id, snapshot_path, state, height_weight)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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

    pub fn set_pinned(&self, lane_id: &str, pinned: bool) -> Result<()> {
        self.conn.execute("UPDATE lane SET pinned = ?2 WHERE id = ?1", params![lane_id, pinned as i32])?;
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

    // ---- history -----------------------------------------------------------

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
        Ok(())
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
        self.conn
            .execute("UPDATE visit SET title = ?2 WHERE url = ?1", params![url, title])?;
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
        self.conn.execute(
            "INSERT INTO visit_alias (alias_url, url)
             SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM visit WHERE url = ?2)
             ON CONFLICT(alias_url) DO UPDATE SET url = excluded.url",
            params![alias, url],
        )?;
        Ok(())
    }

    /// The newest `scan` entries with their redirect sources attached, newest
    /// first — the input [`crate::history::rank`] scores.
    ///
    /// One query rather than one per row: at a 2 000-row scan the per-row
    /// version is 2 000 round trips per keystroke, which is the same mistake
    /// `lanes()` avoids for panes.
    pub fn history_candidates(&self, scan: u32) -> Result<Vec<crate::history::Candidate>> {
        let mut stmt = self.conn.prepare(
            "SELECT v.url, v.title, v.first_visit_at, v.last_visit_at, v.visit_count,
                    (SELECT group_concat(a.alias_url, char(10))
                       FROM visit_alias a WHERE a.url = v.url)
             FROM visit v ORDER BY v.seq DESC LIMIT ?1",
        )?;
        let rows = stmt
            .query_map([scan], |r| {
                Ok(crate::history::Candidate {
                    url: r.get(0)?,
                    title: r.get(1)?,
                    first_visit_at: r.get(2)?,
                    last_visit_at: r.get(3)?,
                    visit_count: r.get::<_, i64>(4)? as u32,
                    aliases: r
                        .get::<_, Option<String>>(5)?
                        .map(|s| s.split('\n').map(str::to_string).collect())
                        .unwrap_or_default(),
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Drop one entry and every alias pointing at it.
    pub fn forget_visit(&self, url: &str) -> Result<()> {
        self.conn.execute("DELETE FROM visit WHERE url = ?1", [url])?;
        Ok(())
    }

    pub fn clear_history(&self) -> Result<()> {
        self.conn.execute("DELETE FROM visit", [])?;
        Ok(())
    }

    /// Enforce the caps. Returns how many entries went.
    ///
    /// Age first, then count: doing it the other way round makes the row cap
    /// decide which of the doomed rows to delete, which is wasted work on the
    /// only call that runs while the user is navigating.
    ///
    /// Aliases go with their entry through the foreign key's `ON DELETE
    /// CASCADE`, which is enforced because `open` sets `foreign_keys = ON` —
    /// worth knowing, because the same schema in a connection without that
    /// pragma leaks an alias table that grows forever.
    pub fn prune_history(&self, max_rows: u32, oldest_allowed_ms: i64) -> Result<usize> {
        let by_age = self
            .conn
            .execute("DELETE FROM visit WHERE last_visit_at < ?1", params![oldest_allowed_ms])?;
        let by_count = self.conn.execute(
            "DELETE FROM visit WHERE url NOT IN
                 (SELECT url FROM visit ORDER BY seq DESC LIMIT ?1)",
            params![max_rows],
        )?;
        Ok(by_age + by_count)
    }

    /// How many entries are on record. For the palette's footer, and for tests.
    pub fn history_count(&self) -> Result<u32> {
        Ok(self
            .conn
            .query_row("SELECT COUNT(*) FROM visit", [], |r| r.get::<_, i64>(0))? as u32)
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
        pinned: r.get::<_, i64>(8)? != 0,
        span: r.get::<_, i64>(9)? as u32,
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

fn parse_project_source(s: &str) -> ProjectSource {
    match s {
        "cwd" => ProjectSource::Cwd,
        "manual" => ProjectSource::Manual,
        _ => ProjectSource::Inherited,
    }
}
