//! SQLite persistence. Every layout mutation commits here before the shell is
//! allowed to animate it, so a `kill -9` can only ever lose the frame in flight.

use crate::error::{CoreError, Result};
use crate::model::*;
use rusqlite::{params, Connection, OptionalExtension, Row};
use std::path::Path;

/// Applied in order on open. Never edit a file that has shipped.
const MIGRATIONS: &[(&str, &str)] = &[("0001_initial", include_str!("../migrations/0001_initial.sql"))];

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
                    std::fs::create_dir_all(dir)
                        .map_err(|e| CoreError::Ledger { message: format!("create {}: {e}", dir.display()) })?;
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
                    created_at, last_focus_at, pinned
             FROM lane ORDER BY ordinal ASC",
        )?;
        let mut lanes: Vec<Lane> = stmt.query_map([], row_to_lane)?.collect::<rusqlite::Result<_>>()?;

        // One pass over every pane beats one query per lane at 150 lanes.
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state
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
                        created_at, last_focus_at, pinned FROM lane WHERE id = ?1",
                [id],
                row_to_lane,
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound { kind: "lane".into(), id: id.into() })?;
        let mut stmt = self.conn.prepare(
            "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                    data_store_id, snapshot_path, state
             FROM pane WHERE lane_id = ?1 ORDER BY position ASC",
        )?;
        lane.panes = stmt.query_map([id], row_to_pane)?.collect::<rusqlite::Result<_>>()?;
        Ok(lane)
    }

    pub fn pane(&self, id: &str) -> Result<Pane> {
        self.conn
            .query_row(
                "SELECT id, lane_id, position, kind, relay_session_id, url, scroll_y,
                        data_store_id, snapshot_path, state FROM pane WHERE id = ?1",
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
                let next: Option<f64> = self
                    .conn
                    .query_row("SELECT MIN(ordinal) FROM lane WHERE ordinal > ?1", [o], |r| r.get(0))?;
                (Some(o), next)
            }
            Placement::LeftOf { lane_id } => {
                let o = self.ordinal_of(lane_id)?;
                let prev: Option<f64> = self
                    .conn
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
                               created_at, last_focus_at, pinned)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
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
            ],
        )?;
        Ok(())
    }

    pub fn insert_pane(&self, pane: &Pane) -> Result<()> {
        self.conn.execute(
            "INSERT INTO pane (id, lane_id, position, kind, relay_session_id, url, scroll_y,
                               data_store_id, snapshot_path, state)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
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
            ],
        )?;
        Ok(())
    }

    pub fn set_ordinal(&self, lane_id: &str, ordinal: f64) -> Result<()> {
        let n = self
            .conn
            .execute("UPDATE lane SET ordinal = ?2 WHERE id = ?1", params![lane_id, ordinal])?;
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
        self.conn
            .execute("UPDATE lane SET title = ?2 WHERE id = ?1", params![lane_id, title])?;
        Ok(())
    }

    pub fn update_lane_width(&self, lane_id: &str, width_pt: u32) -> Result<()> {
        self.conn
            .execute("UPDATE lane SET width_pt = ?2 WHERE id = ?1", params![lane_id, width_pt])?;
        Ok(())
    }

    pub fn set_pinned(&self, lane_id: &str, pinned: bool) -> Result<()> {
        self.conn
            .execute("UPDATE lane SET pinned = ?2 WHERE id = ?1", params![lane_id, pinned as i32])?;
        Ok(())
    }

    pub fn touch_focus(&self, lane_id: &str, at: i64) -> Result<()> {
        self.conn
            .execute("UPDATE lane SET last_focus_at = ?2 WHERE id = ?1", params![lane_id, at])?;
        Ok(())
    }

    pub fn update_pane_url(&self, pane_id: &str, url: &str) -> Result<()> {
        self.conn
            .execute("UPDATE pane SET url = ?2 WHERE id = ?1", params![pane_id, url])?;
        Ok(())
    }

    pub fn update_pane_scroll(&self, pane_id: &str, scroll_y: f64) -> Result<()> {
        self.conn
            .execute("UPDATE pane SET scroll_y = ?2 WHERE id = ?1", params![pane_id, scroll_y])?;
        Ok(())
    }

    pub fn set_pane_evicted(&self, pane_id: &str, snapshot_path: Option<&str>, scroll_y: Option<f64>) -> Result<()> {
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
        self.conn.execute(
            "UPDATE pane SET data_store_id = ?2 WHERE id = ?1",
            params![pane_id, data_store_id],
        )?;
        Ok(())
    }

    pub fn next_position(&self, lane_id: &str) -> Result<u32> {
        let max: Option<i64> = self
            .conn
            .query_row("SELECT MAX(position) FROM pane WHERE lane_id = ?1", [lane_id], |r| r.get(0))?;
        Ok(max.map(|m| m as u32 + 1).unwrap_or(0))
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
    })
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
