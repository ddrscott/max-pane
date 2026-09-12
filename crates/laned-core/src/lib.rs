//! `laned-core` — everything durable about a Max Pane strip.
//!
//! The shell (a macOS app today, something else later) owns pixels, input and
//! the lifetime of `WKWebView`/SwiftTerm objects. It owns no state. Every fact
//! that should survive a `kill -9` lives here, in SQLite, committed before the
//! shell is told to animate anything.
//!
//! The shell's whole contract is: call a mutation, get a [`StripState`] back,
//! diff it against the one on screen, render the difference.

uniffi::setup_scaffolding!();

pub mod error;
pub mod eviction;
pub mod ledger;
pub mod model;
pub mod ordinal;
pub mod project;
pub mod search;

use error::{CoreError, Result};
use ledger::Ledger;
use model::*;
use parking_lot::Mutex;
use std::path::PathBuf;

/// PRD §8. Both ends of the allowed lane width, in points.
pub const LANE_MIN_PT: u32 = 420;
pub const LANE_MAX_PT: u32 = 900;
/// Width a lane is born with.
pub const LANE_DEFAULT_PT: u32 = 560;

const KEY_SCROLL_X: &str = "strip_scroll_x";
const KEY_FOCUSED_PANE: &str = "focused_pane_id";

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn new_id() -> String {
    ulid::Ulid::new().to_string()
}

struct Inner {
    ledger: Ledger,
    index: search::Index,
    /// `Some(project_root)` while the user is in a gather view. View-only.
    gather: Option<String>,
    revision: u64,
}

/// The handle the shell holds for the whole run of the app.
#[derive(uniffi::Object)]
pub struct Core {
    inner: Mutex<Inner>,
    projects: project::ProjectResolver,
}

#[uniffi::export]
impl Core {
    /// Open the ledger at `path`, creating it if this is the first launch.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<std::sync::Arc<Self>> {
        let ledger = Ledger::open(Some(&PathBuf::from(path)))?;
        Ok(std::sync::Arc::new(Core {
            inner: Mutex::new(Inner { ledger, index: search::Index::default(), gather: None, revision: 0 }),
            projects: project::ProjectResolver::default(),
        }))
    }

    /// An ephemeral ledger. Tests and spikes only — nothing survives the process.
    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<std::sync::Arc<Self>> {
        let ledger = Ledger::open(None)?;
        Ok(std::sync::Arc::new(Core {
            inner: Mutex::new(Inner { ledger, index: search::Index::default(), gather: None, revision: 0 }),
            projects: project::ProjectResolver::default(),
        }))
    }

    /// The current strip. Call this on launch and render whatever comes back.
    pub fn state(&self) -> Result<StripState> {
        let inner = self.inner.lock();
        Self::snapshot(&inner)
    }

    // ---- creation ----------------------------------------------------------

    /// A new lane holding one pane.
    ///
    /// `placement` decides where it lands; the tag is inherited from
    /// `inherit_tag_from_lane` when given, which is how a spawned lane arrives
    /// already labelled before its cwd has been polled.
    pub fn create_lane(
        &self,
        placement: Placement,
        kind: PaneKind,
        relay_session_id: Option<String>,
        url: Option<String>,
        inherit_tag_from_lane: Option<String>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let ordinal = Self::place(&mut inner.ledger, &placement)?;

        let (project_root, project_source) = match inherit_tag_from_lane {
            Some(src) => {
                let l = inner.ledger.lane(&src)?;
                (l.project_root, ProjectSource::Inherited)
            }
            None => (None, ProjectSource::Inherited),
        };

        let now = now_ms();
        let lane = Lane {
            id: new_id(),
            ordinal,
            width_pt: LANE_DEFAULT_PT,
            title: None,
            project_root,
            project_source,
            created_at: now,
            last_focus_at: now,
            pinned: false,
            panes: Vec::new(),
        };
        let pane = Pane {
            id: new_id(),
            lane_id: lane.id.clone(),
            position: 0,
            kind,
            relay_session_id,
            url,
            scroll_y: None,
            data_store_id: None,
            snapshot_path: None,
            state: PaneState::Live,
        };
        inner.ledger.insert_lane(&lane)?;
        inner.ledger.insert_pane(&pane)?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane.id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Append a pane to the bottom of an existing lane's stack (⌘D).
    pub fn add_pane(
        &self,
        lane_id: String,
        kind: PaneKind,
        relay_session_id: Option<String>,
        url: Option<String>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let position = inner.ledger.next_position(&lane_id)?;
        let pane = Pane {
            id: new_id(),
            lane_id: lane_id.clone(),
            position,
            kind,
            relay_session_id,
            url,
            scroll_y: None,
            data_store_id: None,
            snapshot_path: None,
            state: PaneState::Live,
        };
        inner.ledger.insert_pane(&pane)?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane.id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    // ---- removal -----------------------------------------------------------

    pub fn close_lane(&self, lane_id: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let lane = inner.ledger.lane(&lane_id)?;
        for p in &lane.panes {
            inner.index.forget(&p.id);
        }
        inner.ledger.delete_lane(&lane_id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Close one pane. Closing a lane's last pane closes the lane: an empty
    /// column is not a thing the user can do anything with.
    pub fn close_pane(&self, pane_id: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.index.forget(&pane_id);
        let lane_id = inner.ledger.delete_pane(&pane_id)?;
        if inner.ledger.lane(&lane_id)?.panes.is_empty() {
            inner.ledger.delete_lane(&lane_id)?;
        }
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    // ---- ordering ----------------------------------------------------------

    /// Move a lane to a new place in the strip. The only thing that ever writes
    /// an ordinal outside of creation — and only ever because the user asked.
    pub fn move_lane(&self, lane_id: String, placement: Placement) -> Result<StripState> {
        let mut inner = self.inner.lock();
        if let Placement::RightOf { lane_id: t } | Placement::LeftOf { lane_id: t } = &placement {
            if t == &lane_id {
                return Err(CoreError::Invalid { message: "a lane cannot be placed relative to itself".into() });
            }
        }
        let ordinal = Self::place(&mut inner.ledger, &placement)?;
        inner.ledger.set_ordinal(&lane_id, ordinal)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Swap a lane with its neighbour (⌘⇧← / ⌘⇧→).
    pub fn nudge_lane(&self, lane_id: String, right: bool) -> Result<StripState> {
        let lanes = {
            let inner = self.inner.lock();
            inner.ledger.lanes()?
        };
        let i = lanes
            .iter()
            .position(|l| l.id == lane_id)
            .ok_or_else(|| CoreError::NotFound { kind: "lane".into(), id: lane_id.clone() })?;
        let target = if right {
            if i + 1 >= lanes.len() {
                return self.state();
            }
            Placement::RightOf { lane_id: lanes[i + 1].id.clone() }
        } else {
            if i == 0 {
                return self.state();
            }
            Placement::LeftOf { lane_id: lanes[i - 1].id.clone() }
        };
        self.move_lane(lane_id, target)
    }

    // ---- lane attributes ---------------------------------------------------

    pub fn set_lane_width(&self, lane_id: String, width_pt: u32) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner
            .ledger
            .update_lane_width(&lane_id, width_pt.clamp(LANE_MIN_PT, LANE_MAX_PT))?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    pub fn set_lane_title(&self, lane_id: String, title: Option<String>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.update_lane_title(&lane_id, title.as_deref())?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    pub fn set_pinned(&self, lane_id: String, pinned: bool) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.set_pinned(&lane_id, pinned)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// The user's own tag. Sticky: the cwd tagger will not overwrite it.
    pub fn set_manual_tag(&self, lane_id: String, project_root: Option<String>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner
            .ledger
            .update_lane_tag(&lane_id, project_root.as_deref(), ProjectSource::Manual)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Report a pty pane's current working directory. Resolves it to a git root
    /// and retags the lane — unless the user set the tag by hand.
    ///
    /// Returns `true` when the tag actually changed, so the shell can skip a
    /// render on the overwhelmingly common no-op. **Never moves the lane.**
    pub fn observe_cwd(&self, lane_id: String, cwd: String) -> Result<bool> {
        let root = self.projects.root_of(&cwd);
        let mut inner = self.inner.lock();
        let lane = inner.ledger.lane(&lane_id)?;
        if lane.project_source == ProjectSource::Manual {
            return Ok(false);
        }
        if lane.project_root.as_deref() == root.as_deref() && lane.project_source == ProjectSource::Cwd {
            return Ok(false);
        }
        inner.ledger.update_lane_tag(&lane_id, root.as_deref(), ProjectSource::Cwd)?;
        Self::bump(&mut inner);
        Ok(true)
    }

    // ---- pane attributes ---------------------------------------------------

    /// Called from `WKNavigationDelegate` as the user navigates.
    pub fn set_pane_url(&self, pane_id: String, url: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_url(&pane_id, &url)
    }

    pub fn set_pane_scroll(&self, pane_id: String, scroll_y: f64) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_scroll(&pane_id, scroll_y)
    }

    pub fn set_pane_data_store(&self, pane_id: String, data_store_id: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.set_pane_data_store(&pane_id, &data_store_id)
    }

    /// The shell has taken a snapshot and destroyed the `WKWebView`.
    pub fn mark_evicted(&self, pane_id: String, snapshot_path: Option<String>, scroll_y: Option<f64>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner
            .ledger
            .set_pane_evicted(&pane_id, snapshot_path.as_deref(), scroll_y)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// The shell has recreated the `WKWebView` and restored its URL and scroll.
    pub fn mark_live(&self, pane_id: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.set_pane_live(&pane_id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    // ---- focus and viewport ------------------------------------------------

    pub fn focus_pane(&self, pane_id: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let pane = inner.ledger.pane(&pane_id)?;
        inner.ledger.touch_focus(&pane.lane_id, now_ms())?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane_id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Persist the strip's horizontal scroll. Called on a debounce, not per
    /// frame: it is a write, and 120 Hz of writes would be absurd.
    pub fn set_scroll_x(&self, scroll_x: f64) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.set_app_state(KEY_SCROLL_X, &scroll_x.to_string())
    }

    // ---- gather ------------------------------------------------------------

    /// Show only lanes tagged with `project_root`, in true ordinal order (⌘G).
    /// A filter over the snapshot; it writes nothing.
    pub fn gather(&self, project_root: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.gather = Some(project_root);
        Self::snapshot(&inner)
    }

    /// Leave the gather view (Esc). The strip is exactly as it was.
    pub fn ungather(&self) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.gather = None;
        Self::snapshot(&inner)
    }

    // ---- search ------------------------------------------------------------

    /// Hand `laned-core` a pty pane's recent scrollback so ⌘P can find it.
    /// Pushed from the shell on a debounce; capped at 200 lines per pane.
    pub fn push_scrollback(&self, pane_id: String, lines: Vec<String>) {
        let mut inner = self.inner.lock();
        inner.index.set_scrollback(&pane_id, lines);
    }

    pub fn search(&self, query: String, limit: u32) -> Result<Vec<SearchHit>> {
        let inner = self.inner.lock();
        // Search ignores the gather filter: ⌘P is how you leave a gather view
        // for something you suddenly remembered.
        let lanes = inner.ledger.lanes()?;
        Ok(inner.index.search(&lanes, &query, limit as usize))
    }

    // ---- pairing -----------------------------------------------------------

    pub fn pair(&self, pty_pane_id: String, web_pane_id: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.pair(&pty_pane_id, &web_pane_id)
    }

    pub fn unpair(&self, pty_pane_id: String, web_pane_id: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.unpair(&pty_pane_id, &web_pane_id)
    }

    pub fn pairs_of(&self, pane_id: String) -> Result<Vec<String>> {
        let inner = self.inner.lock();
        inner.ledger.pairs_of(&pane_id)
    }

    // ---- eviction ----------------------------------------------------------

    /// What the shell should do with every pane, given what it just measured.
    /// Pure: calling it changes nothing. The shell reports back with
    /// [`Core::mark_evicted`] / [`Core::mark_live`] once it has acted.
    pub fn plan_eviction(&self, viewport: eviction::Viewport, memory: eviction::MemoryReport) -> Result<Vec<eviction::PaneDirective>> {
        let inner = self.inner.lock();
        let lanes = inner.ledger.lanes()?;
        Ok(eviction::plan(&lanes, &viewport, &memory))
    }

    // ---- housekeeping ------------------------------------------------------

    /// Resolve a working directory to a git root without touching the ledger.
    /// The shell uses it to label things that aren't lanes yet, like the
    /// "attach existing session" picker.
    pub fn project_root_of(&self, cwd: String) -> Option<String> {
        self.projects.root_of(&cwd)
    }
}

// ---- internals (not exported over FFI) -------------------------------------

impl Core {
    /// The ordinal for a new or moved lane, renormalizing the strip if the gap
    /// has been subdivided past what f64 can carry.
    fn place(ledger: &mut Ledger, placement: &Placement) -> Result<f64> {
        let (before, after) = ledger.neighbours(placement)?;
        if let Some(o) = ordinal::between(before, after) {
            return Ok(o);
        }
        ledger.renormalize()?;
        let (before, after) = ledger.neighbours(placement)?;
        ordinal::between(before, after).ok_or_else(|| CoreError::Invalid {
            message: "ordinal space exhausted after renormalize".into(),
        })
    }

    fn bump(inner: &mut Inner) {
        inner.revision += 1;
    }

    fn snapshot(inner: &Inner) -> Result<StripState> {
        let mut lanes = inner.ledger.lanes()?;
        if let Some(root) = &inner.gather {
            lanes.retain(|l| l.project_root.as_deref() == Some(root.as_str()));
        }
        let scroll_x = inner
            .ledger
            .app_state(KEY_SCROLL_X)?
            .and_then(|s| s.parse().ok())
            .unwrap_or(0.0);
        Ok(StripState {
            lanes,
            scroll_x,
            focused_pane_id: inner.ledger.app_state(KEY_FOCUSED_PANE)?,
            gather_filter: inner.gather.clone(),
            revision: inner.revision,
        })
    }
}
