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
pub mod history;
pub mod ledger;
pub mod model;
pub mod ordinal;
pub mod portable;
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
/// Width a lane is born with when no shell has said otherwise.
///
/// 656 because spike M2 measured a 13 pt monospace cell at 8 pt wide: 80
/// columns — what almost every agent TUI assumes — needs 640 pt of grid plus
/// 16 pt of lane chrome. A narrower default opens the common case already
/// clipped, and ADR-0007 means the lane may not resize the PTY to fix it.
///
/// This used to carry a "**must match `Config.laneDefaultPt`**" note, and the
/// two did match — which made `laneDefaultPt` decorative, because `create_lane`
/// read *this* one. Editing the config file changed nothing about a new lane,
/// and the day someone edited one constant and not the other the app would have
/// disagreed with itself in a way no test could see. There is one source of
/// truth now: the shell states the width once, through
/// [`Core::set_default_lane_width`], and this is only what a caller that never
/// says anything — the tests, a future shell mid-boot — gets.
pub const LANE_DEFAULT_PT: u32 = 656;

/// Both ends of the allowed *dock* width, in points.
///
/// Deliberately not `LANE_MIN_PT`/`LANE_MAX_PT`. §8's 420 pt floor exists so a
/// terminal lane still holds a readable grid — 656 pt is 80 columns at a 13 pt
/// monospace cell, and 420 is about 50. A dock is not that: the owner's stated
/// case is *"a page that's for background music"*, which is a player, and a
/// player forced to 420 pt takes a third of a portrait window to show a
/// play button.
///
/// The floor is 240 rather than nothing because a dock you have dragged down to
/// a sliver is a dock you cannot grab to drag back. The ceiling is the lane
/// ceiling, since past that the thing at the edge of the screen has stopped
/// being a dock and become the window.
///
/// Neither bound knows how wide the window is, and neither should: the core
/// clamps the number the user chose, and the *view* clamps again against the
/// viewport at layout time without ever writing that back. A dock is not
/// permanently narrowed by having once been opened on a small screen — the same
/// rule ADR-0007 settled for lanes and session sizes.
pub const DOCK_MIN_PT: u32 = 240;
pub const DOCK_MAX_PT: u32 = LANE_MAX_PT;

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

/// The weight a pane joining a stack should be given.
///
/// The mean, so the newcomer takes an equal share of the enlarged lane and the
/// panes already there give up height in proportion to what they had. 1.0 for
/// an empty stack, which is the same number the migration defaults to, so the
/// first pane of a lane is never a special case anywhere.
fn mean_weight(existing: &[f64]) -> f64 {
    if existing.is_empty() {
        return 1.0;
    }
    let sum: f64 = existing.iter().filter(|w| w.is_finite() && **w > 0.0).sum();
    if sum <= 0.0 {
        return 1.0;
    }
    sum / existing.len() as f64
}

struct Inner {
    ledger: Ledger,
    index: search::Index,
    /// What each pane last settled on, so one navigation reported three times
    /// is one visit. Not persisted — a burst cannot straddle a launch.
    visits: history::VisitMemo,
    /// Visits since the last prune. The caps are enforced on a cadence rather
    /// than on every settle; see [`history::HISTORY_PRUNE_EVERY`].
    visits_since_prune: u32,
    /// The rows a history query scores, kept between writes.
    ///
    /// Measured: a keystroke over a full ledger costs ~1.1 ms of SQLite and
    /// ~1.0 ms of scoring. The scoring is the work; the read is the same 2 000
    /// rows fetched again for every character of the same query, and the
    /// palette is open for a second at a time during which nothing navigates.
    /// So it is read once and dropped by the next write — the same bargain
    /// `NewPanePicker` strikes when it reads `recents` once on open, moved down
    /// here because the corpus deliberately never reaches Swift.
    ///
    /// Bounded by [`history::HISTORY_SCAN_ROWS`], not by the size of the table.
    history_cache: Option<Vec<history::Candidate>>,
    /// `Some(project_root)` while the user is in a gather view. View-only.
    gather: Option<String>,
    /// The width a new lane is born with.
    ///
    /// Deliberately *not* persisted: the user's config file already persists it,
    /// and a copy in the ledger would be a second answer to the same question
    /// that survives the file being edited. The shell states it at launch; until
    /// it does, [`LANE_DEFAULT_PT`] stands.
    default_lane_width: u32,
    revision: u64,
    /// Eviction's memory of what it has already done. Not persisted: after a
    /// relaunch the strip is cold and a cooldown would have nothing to protect.
    hysteresis: eviction::Hysteresis,
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
            inner: Mutex::new(Inner {
                ledger,
                index: search::Index::default(),
                visits: history::VisitMemo::default(),
                visits_since_prune: 0,
                history_cache: None,
                gather: None,
                default_lane_width: LANE_DEFAULT_PT,
                revision: 0,
                hysteresis: eviction::Hysteresis::default(),
            }),
            projects: project::ProjectResolver::default(),
        }))
    }

    /// An ephemeral ledger. Tests and spikes only — nothing survives the process.
    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<std::sync::Arc<Self>> {
        let ledger = Ledger::open(None)?;
        Ok(std::sync::Arc::new(Core {
            inner: Mutex::new(Inner {
                ledger,
                index: search::Index::default(),
                visits: history::VisitMemo::default(),
                visits_since_prune: 0,
                history_cache: None,
                gather: None,
                default_lane_width: LANE_DEFAULT_PT,
                revision: 0,
                hysteresis: eviction::Hysteresis::default(),
            }),
            projects: project::ProjectResolver::default(),
        }))
    }

    /// The current strip. Call this on launch and render whatever comes back.
    pub fn state(&self) -> Result<StripState> {
        let inner = self.inner.lock();
        Self::snapshot(&inner)
    }

    // ---- creation ----------------------------------------------------------

    /// How wide a lane is born, in points. The shell's config file, arriving.
    ///
    /// Call it once at launch, before the first `create_lane`. Clamped to the
    /// same bounds a resize is, so a config file that says `40` or `4000` gets a
    /// lane it is still possible to read rather than a lane it is not.
    ///
    /// Existing lanes are untouched, deliberately and permanently: a width in
    /// the ledger is either the one the user dragged or the one the session
    /// asked for, and re-flowing the whole strip because a default changed would
    /// throw both away.
    pub fn set_default_lane_width(&self, width_pt: u32) {
        let mut inner = self.inner.lock();
        inner.default_lane_width = width_pt.clamp(LANE_MIN_PT, LANE_MAX_PT);
    }

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
            width_pt: inner.default_lane_width,
            title: None,
            project_root,
            project_source,
            created_at: now,
            last_focus_at: now,
            keep_live: false,
            // A lane is born in the strip. Docking is always something the user
            // did to a lane that already exists, which is what makes "where
            // does it go back to" answerable at all.
            dock: None,
            span: 1,
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
            height_weight: 1.0,
            zoom: 1.0,
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
            // The mean of what is already there, which is the one value that
            // gives the arrival an equal share of the *new* total while leaving
            // every existing ratio untouched. Splitting a lane you have already
            // tuned 70/30 therefore gives 47/20/33 — the two panes you arranged
            // still stand in the same relation to each other, and neither is
            // singled out to pay for the newcomer.
            height_weight: mean_weight(&inner.ledger.height_weights(&lane_id)?),
            zoom: 1.0,
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
            inner.visits.forget(&p.id);
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
        inner.visits.forget(&pane_id);
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
                return Err(CoreError::Invalid {
                    message: "a lane cannot be placed relative to itself".into(),
                });
            }
        }
        let ordinal = Self::place(&mut inner.ledger, &placement)?;
        inner.ledger.set_ordinal(&lane_id, ordinal)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Swap a lane with its neighbour (⌘⇧← / ⌘⇧→).
    ///
    /// Over the lanes the *strip* shows. A docked lane still holds an ordinal
    /// somewhere in the middle of the order — that is the whole mechanism by
    /// which it returns to the same spot — and swapping with it would move the
    /// lane past something invisible, twice, to no visible effect. The user
    /// would press ⌘⇧→ and watch nothing happen.
    ///
    /// Nudging a *docked* lane is a no-op for the same reason from the other
    /// side. It would move the spot the lane returns to when it is undocked,
    /// which is a real change with nothing on screen to show for it — and a
    /// keystroke that silently rearranges a strip you cannot see it rearrange
    /// is worse than a keystroke that does nothing.
    pub fn nudge_lane(&self, lane_id: String, right: bool) -> Result<StripState> {
        let lanes = {
            let inner = self.inner.lock();
            if inner.ledger.lane(&lane_id)?.dock.is_some() {
                return Self::snapshot(&inner);
            }
            let mut lanes = inner.ledger.lanes()?;
            lanes.retain(|l| l.dock.is_none());
            lanes
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
        let span = inner.ledger.lane(&lane_id)?.span.max(1);
        inner.ledger.update_lane_width(&lane_id, width_pt.clamp(LANE_MIN_PT, LANE_MAX_PT * span))?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Set the height weights of some or all of a lane's panes.
    ///
    /// A *list*, because the gesture that produces it moves two panes at once
    /// and they have to land together — see `Ledger::set_height_weights`. The
    /// caller sends only the panes it changed; a divider drag therefore writes
    /// exactly two rows however tall the stack is, and every other pane's
    /// weight stays bit-identical rather than being rewritten with a rounded
    /// version of itself.
    ///
    /// Weights are a ratio, so the only thing refused here is a value that
    /// cannot be one. A non-finite or non-positive weight would make `Σw`
    /// meaningless for the whole lane — one NaN and every sibling's height is
    /// NaN — so it is rejected at the boundary rather than clamped quietly: a
    /// caller sending it has a bug, and a lane that silently reshapes itself is
    /// a worse way to find out. The *point* floor a pane may not shrink past is
    /// not here on purpose; it depends on how tall the lane is right now, which
    /// is a fact about the window and not about the ledger.
    pub fn set_pane_heights(&self, weights: Vec<PaneHeight>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        for w in &weights {
            if !w.weight.is_finite() || w.weight <= 0.0 {
                return Err(CoreError::Invalid {
                    message: format!("pane height weight must be finite and positive, got {}", w.weight),
                });
            }
        }
        let rows: Vec<(String, f64)> =
            weights.into_iter().map(|w| (w.pane_id, w.weight)).collect();
        inner.ledger.set_height_weights(&rows)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// How many lane-widths a lane may occupy (PRD §13 Phase 3).
    ///
    /// Clamped to 1..=2. §1's invariant is that a lane is a portrait column, and
    /// "2× for the rare landscape site" is the whole of the exception — there is
    /// no span 3. Narrowing back to 1 brings the width back inside the normal
    /// bound at the same time, so a lane cannot be left wider than a lane is
    /// allowed to be.
    pub fn set_lane_span(&self, lane_id: String, span: u32) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let span = span.clamp(1, 2);
        inner.ledger.set_span(&lane_id, span)?;
        let current = inner.ledger.lane(&lane_id)?.width_pt;
        let allowed = LANE_MAX_PT * span;
        if current > allowed {
            inner.ledger.update_lane_width(&lane_id, allowed)?;
        }
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    pub fn set_lane_title(&self, lane_id: String, title: Option<String>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.update_lane_title(&lane_id, title.as_deref())?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Protect a lane's web panes from the eviction policy (⇧⌘P).
    ///
    /// This is `set_pinned` under the name the word "pinned" had to give up
    /// when the owner said docking is what he means by pinning. Same flag, same
    /// key, same behaviour; ADR-0010 records why it survived the rename instead
    /// of being folded into docking.
    ///
    /// Nothing needs to call this for a *docked* lane: protection is derived
    /// from the dock rather than written alongside it, so undocking cannot
    /// quietly clear a flag the user set by hand.
    pub fn set_keep_live(&self, lane_id: String, keep_live: bool) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.set_keep_live(&lane_id, keep_live)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    // ---- docking -----------------------------------------------------------

    /// Hold a lane at one edge of the window instead of letting it scroll with
    /// the strip.
    ///
    /// The unit is the lane, which the owner settled directly — *"when a lane
    /// is docked all its panes are inherently docked with it"* — so this takes
    /// a lane id and a stack of three docks as one thing. The brief argued both
    /// sides; it is not an open question any more, and nothing here should be
    /// rebuilt around panes without him saying so.
    ///
    /// **The lane keeps its ordinal and stays in `StripState.lanes`.** It is
    /// not removed from the order and re-inserted on undock, because a
    /// remembered ordinal is a fact that goes stale: lanes created either side
    /// of it, both its neighbours closed, or a [`Ledger::renormalize`] rewriting
    /// every ordinal underneath it, and the remembered number no longer names
    /// the place it came from. A lane that never left the order cannot be put
    /// back in the wrong place, so *"the order of the docked lane is remembered
    /// so it returns to the same spot"* costs nothing to guarantee and survives
    /// all four of those cases and a restart. The price is one filter in the
    /// strip's layout, which is stated in the contract and is one predicate.
    ///
    /// `width_pt` of `None` means "the width this lane already has", clamped
    /// into [`DOCK_MIN_PT`]..=[`DOCK_MAX_PT`]. Docking must not reflow the page:
    /// if the act of docking re-laid a running web app out at some default
    /// width, every dock would begin with the thing you docked jumping.
    ///
    /// Docking a lane to an edge another lane holds displaces the incumbent
    /// back into the strip. See [`Ledger::set_dock`] for why that is not an
    /// error.
    pub fn dock_lane(
        &self,
        lane_id: String,
        side: DockSide,
        mode: DockMode,
        width_pt: Option<u32>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let lane = inner.ledger.lane(&lane_id)?;
        let width = width_pt.unwrap_or(lane.width_pt).clamp(DOCK_MIN_PT, DOCK_MAX_PT);
        inner.ledger.set_dock(&lane_id, Some(Dock { side, mode, width_pt: width }))?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Give the edge back. The lane resumes scrolling with the strip between
    /// the same two neighbours it left, because its ordinal never moved.
    ///
    /// A no-op on a lane that is not docked, rather than an error: the one
    /// caller is a toggle, and a toggle that throws on the half of its range
    /// that is already correct is a toggle with a bug in every call site.
    ///
    /// The lane's own `width_pt` is untouched throughout, so it returns to the
    /// strip at the width it had there however narrow it was dragged while
    /// docked. `span` is the same: it describes how many lane-widths this lane
    /// may take *in the strip*, which is not a question while it is at an edge.
    pub fn undock_lane(&self, lane_id: String) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.lane(&lane_id)?;
        inner.ledger.set_dock(&lane_id, None)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Overlay ↔ inset for a lane that is already docked.
    ///
    /// Errors rather than docking the lane, so that a keystroke aimed at the
    /// wrong lane cannot silently take an edge of the screen.
    pub fn set_dock_mode(&self, lane_id: String, mode: DockMode) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let dock = Self::dock_of(&inner, &lane_id)?;
        inner.ledger.set_dock(&lane_id, Some(Dock { mode, ..dock }))?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// How wide the dock is, in points. Clamped; see [`DOCK_MIN_PT`].
    pub fn set_dock_width(&self, lane_id: String, width_pt: u32) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let dock = Self::dock_of(&inner, &lane_id)?;
        let width_pt = width_pt.clamp(DOCK_MIN_PT, DOCK_MAX_PT);
        inner.ledger.set_dock(&lane_id, Some(Dock { width_pt, ..dock }))?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Which lane holds an edge, if any.
    ///
    /// Cheap enough to call per frame — it is one lane, not the strip — but the
    /// shell should read `StripState.lanes` it already has instead. This exists
    /// for the CLI and for tests, which have no snapshot in hand.
    pub fn docked_lane(&self, side: DockSide) -> Result<Option<Lane>> {
        let inner = self.inner.lock();
        Ok(inner.ledger.lanes()?.into_iter().find(|l| l.dock.is_some_and(|d| d.side == side)))
    }

    /// The user's own tag. Sticky: the cwd tagger will not overwrite it.
    pub fn set_manual_tag(&self, lane_id: String, project_root: Option<String>) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.update_lane_tag(&lane_id, project_root.as_deref(), ProjectSource::Manual)?;
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

    /// Store (or clear, with `None`) a web pane's `WKWebView.interactionState`.
    ///
    /// No `StripState` is published: the blob is not part of the layout, and
    /// republishing on every navigation would redraw the strip for a scroll.
    pub fn set_pane_interaction_state(&self, pane_id: String, state: Option<Vec<u8>>) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_interaction_state(&pane_id, state.as_deref())
    }

    /// Read back what a web pane was doing, for the one call that rebuilds it.
    pub fn pane_interaction_state(&self, pane_id: String) -> Result<Option<Vec<u8>>> {
        let inner = self.inner.lock();
        inner.ledger.pane_interaction_state(&pane_id)
    }

    // ---- recents -----------------------------------------------------------

    /// Remember a launch for the new-pane picker.
    pub fn note_recent(
        &self,
        kind: RecentKind,
        value: String,
        cwd: Option<String>,
    ) -> Result<()> {
        let trimmed = value.trim();
        // An empty entry would take a numeric shortcut and launch nothing.
        if trimmed.is_empty() {
            return Ok(());
        }
        let inner = self.inner.lock();
        inner.ledger.note_recent(kind, trimmed, cwd.as_deref(), now_ms())
    }

    /// What to offer, most recent first.
    pub fn recents(&self, limit: u32) -> Result<Vec<Recent>> {
        let inner = self.inner.lock();
        inner.ledger.recents(limit)
    }

    /// Drop one entry — the picker's way of pruning a typo you will never run
    /// again but which keeps taking a numeric shortcut.
    pub fn forget_recent(&self, kind: RecentKind, value: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.forget_recent(kind, &value)
    }

    // ---- site permissions ---------------------------------------------------

    /// Has this site, in this cookie jar, already been answered about this
    /// feature? `None` is "never asked" — the only answer that may raise a
    /// prompt, so a page cannot make the prompt reappear by asking twice.
    ///
    /// Keyed by the data store as well as the origin because that is what the
    /// site actually sees of the user (ADR-0003): two projects sharded into
    /// different jars are two different people to `meet.google.com`, and a
    /// grant made as one of them was never a grant made as the other.
    pub fn site_permission(
        &self,
        data_store_id: String,
        origin: String,
        feature: SiteFeature,
    ) -> Result<Option<bool>> {
        let inner = self.inner.lock();
        inner
            .ledger
            .site_permission(&data_store_id, &origin, feature)
    }

    /// Remember an answer. Only ever called with a decision a person made —
    /// nothing here infers one from a dismissal, because a dialog dismissed by
    /// Esc is "not now", not "never".
    pub fn set_site_permission(
        &self,
        data_store_id: String,
        origin: String,
        feature: SiteFeature,
        allowed: bool,
    ) -> Result<()> {
        let inner = self.inner.lock();
        inner
            .ledger
            .set_site_permission(&data_store_id, &origin, feature, allowed, now_ms())
    }

    pub fn forget_site_permissions(&self, data_store_id: String, origin: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.forget_site_permissions(&data_store_id, &origin)
    }

    // ---- history -----------------------------------------------------------

    /// A web pane settled on a page. One call, from wherever the shell learns a
    /// navigation finished.
    ///
    /// `url` is the address that ended up on screen. `requested_url` is the one
    /// the navigation started from — `WKBackForwardListItem.initialURL`, which
    /// is the same string except when something redirected.
    ///
    /// # Which address is the history entry?
    ///
    /// You ask for `example.com` and land on `https://www.example.com/en`. The
    /// entry is where you landed: that is the page with the title, and it is
    /// the address that reopens to what you actually saw — an entry for the
    /// redirect source reopens to a bounce, which is a row that looks like a
    /// page and is not one. But an entry for *only* the destination means
    /// typing back the thing you asked for finds nothing, and "I typed
    /// example.com and history has never heard of it" is exactly the hole this
    /// piece exists to close. So the source is kept as an alias: searchable,
    /// never listed, dropped with the entry it points at. A chain of three
    /// redirects leaves one entry and, because the shell only ever knows where
    /// the navigation began, one alias — the address the user typed, which is
    /// the only hop they could ever search for.
    ///
    /// No `StripState`: a visit is not layout, and republishing the strip on
    /// every page load would redraw 150 lanes because one of them scrolled.
    pub fn record_visit(
        &self,
        pane_id: String,
        url: String,
        title: Option<String>,
        requested_url: Option<String>,
    ) -> Result<()> {
        let Some(url) = history::normalize_url(&url) else { return Ok(()) };
        let now = now_ms();
        let mut inner = self.inner.lock();
        if !inner.visits.accept(&pane_id, &url, now) {
            // Still a chance to learn the name: the duplicate settle is often
            // the one that finally has a <title>.
            if let Some(t) = title.as_deref() {
                inner.ledger.name_visit(&url, t)?;
                inner.history_cache = None;
            }
            return Ok(());
        }
        inner.ledger.record_visit(&url, title.as_deref(), now)?;
        inner.history_cache = None;
        if let Some(alias) = requested_url.as_deref().and_then(history::normalize_url) {
            inner.ledger.note_visit_alias(&alias, &url)?;
        }
        inner.visits_since_prune += 1;
        if inner.visits_since_prune >= history::HISTORY_PRUNE_EVERY {
            inner.visits_since_prune = 0;
            inner
                .ledger
                .prune_history(history::HISTORY_MAX_ROWS, now - history::HISTORY_MAX_AGE_MS)?;
        }
        Ok(())
    }

    /// The page's `<title>`, which usually lands after the navigation finished.
    ///
    /// Separate from [`Core::record_visit`] because it is a correction to a
    /// visit rather than another one: it never inserts and never counts.
    pub fn name_visit(&self, url: String, title: String) -> Result<()> {
        let Some(url) = history::normalize_url(&url) else { return Ok(()) };
        let mut inner = self.inner.lock();
        inner.ledger.name_visit(&url, &title)?;
        inner.history_cache = None;
        Ok(())
    }

    /// History, best match first — or most recent first for an empty query,
    /// which is what the palette shows before anything is typed.
    pub fn history(&self, query: String, limit: u32) -> Result<Vec<HistoryEntry>> {
        let mut inner = self.inner.lock();
        if inner.history_cache.is_none() {
            inner.history_cache = Some(inner.ledger.history_candidates(history::HISTORY_SCAN_ROWS)?);
        }
        let candidates = inner.history_cache.as_deref().unwrap_or_default();
        Ok(history::rank(candidates, &query, limit as usize))
    }

    /// How many pages are on record, for the palette's footer.
    pub fn history_count(&self) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.history_count()
    }

    /// How many pages a query can actually reach.
    ///
    /// Not the same number as [`Core::history_count`], and the gap is the
    /// point: the table holds [`history::HISTORY_MAX_ROWS`] and one query scores
    /// the newest [`history::HISTORY_SCAN_ROWS`] of them. A footer that prints
    /// the table's size while describing a search that cannot see all of it —
    /// "0 of 5013 pages" over a corpus where row 2 499 is unfindable — is a
    /// label that lies about the thing it labels. Whatever the caps become, a
    /// picker asking this question gets the truthful answer.
    pub fn history_searchable_count(&self) -> Result<u32> {
        let inner = self.inner.lock();
        Ok(inner.ledger.history_count()?.min(history::HISTORY_SCAN_ROWS))
    }

    /// Drop one page, and every redirect that pointed at it. The palette's ⌘⌫.
    pub fn forget_visit(&self, url: String) -> Result<()> {
        let url = history::normalize_url(&url).unwrap_or(url);
        let mut inner = self.inner.lock();
        inner.ledger.forget_visit(&url)?;
        inner.history_cache = None;
        Ok(())
    }

    /// Forget everything. There is no undo, which is the point of it.
    pub fn clear_history(&self) -> Result<()> {
        let mut inner = self.inner.lock();
        inner.ledger.clear_history()?;
        inner.history_cache = None;
        Ok(())
    }

    /// Enforce the caps now rather than on the next cadence. The shell has no
    /// reason to call this; tests and `maxpane` housekeeping do.
    pub fn prune_history(&self) -> Result<u32> {
        let now = now_ms();
        let mut inner = self.inner.lock();
        let gone = inner
            .ledger
            .prune_history(history::HISTORY_MAX_ROWS, now - history::HISTORY_MAX_AGE_MS)?;
        inner.history_cache = None;
        Ok(gone as u32)
    }

    /// Remember how far a pane's contents are scaled. No snapshot is
    /// published: zoom changes what a pane draws, not the shape of the strip.
    pub fn set_pane_zoom(&self, pane_id: String, zoom: f64) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_zoom(&pane_id, zoom)
    }

    pub fn set_pane_data_store(&self, pane_id: String, data_store_id: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.set_pane_data_store(&pane_id, &data_store_id)
    }

    /// The shell has taken a snapshot and destroyed the `WKWebView`.
    pub fn mark_evicted(
        &self,
        pane_id: String,
        snapshot_path: Option<String>,
        scroll_y: Option<f64>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        inner.ledger.set_pane_evicted(&pane_id, snapshot_path.as_deref(), scroll_y)?;
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

    /// The current revision, without marshalling a snapshot.
    ///
    /// Spike M3 measured a 300-lane `state()` at 2.4 ms, 88% of it uniffi
    /// copying records into Swift. The shell holds the last snapshot and calls
    /// this first: unchanged revision means there is nothing to re-render and
    /// the 2.4 ms is not spent.
    pub fn revision(&self) -> u64 {
        self.inner.lock().revision
    }

    /// One lane, for when the shell knows exactly what changed. Costs what a
    /// single lane costs rather than what the strip costs.
    pub fn lane(&self, lane_id: String) -> Result<Lane> {
        let inner = self.inner.lock();
        inner.ledger.lane(&lane_id)
    }

    /// Record focus without building a snapshot.
    ///
    /// Focus changes on every ⌘-arrow and every click, and it moves exactly two
    /// rows — `lane.last_focus_at` and one `app_state` key. Neither changes the
    /// shape of the strip, so the shell already knows how to draw the result.
    pub fn note_focus(&self, pane_id: String) -> Result<()> {
        let mut inner = self.inner.lock();
        let pane = inner.ledger.pane(&pane_id)?;
        inner.ledger.touch_focus(&pane.lane_id, now_ms())?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane_id)?;
        Self::bump(&mut inner);
        Ok(())
    }

    /// [`Core::note_focus`], plus the snapshot. Use it when focus was a side
    /// effect of something structural, like search-to-scroll.
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
    pub fn plan_eviction(
        &self,
        viewport: eviction::Viewport,
        memory: eviction::MemoryReport,
    ) -> Result<Vec<eviction::PaneDirective>> {
        let mut inner = self.inner.lock();
        // The viewport is expressed as indices into the lanes the *shell* is
        // showing, so this has to see the same list — including the gather
        // filter. Planning against the unfiltered strip while the shell is
        // gathered would evict whatever happens to sit at those indices.
        let lanes = Self::snapshot(&inner)?.lanes;
        let now = now_ms();
        Ok(eviction::plan(&lanes, &viewport, &memory, &mut inner.hysteresis, now))
    }

    // ---- housekeeping ------------------------------------------------------

    // ---- export / import (§13 Phase 3) -------------------------------------

    /// The whole strip as JSON. Order, widths, titles, tags, URLs, and which
    /// Relay session each terminal was on.
    ///
    /// Not a ledger backup: ids are not exported, so importing into a machine
    /// that already has a strip merges rather than collides.
    pub fn export_strip(&self) -> Result<String> {
        let inner = self.inner.lock();
        // Deliberately the unfiltered strip: exporting while gathered should
        // give the whole thing, not the view.
        Ok(portable::export(&inner.ledger.lanes()?))
    }

    /// Append an exported strip to the right-hand end of this one.
    ///
    /// Appends rather than replaces, because the destructive version of this is
    /// a thing the user can build out of it (export, close everything, import)
    /// and the safe version is not recoverable from the destructive one.
    ///
    /// pty panes come back attached to whatever session id they had. On another
    /// machine that session will not exist, and the lane renders "reconnecting"
    /// with its ordinal and tag intact — which is the same thing that happens
    /// when Relay is down (PRD §11).
    ///
    /// **Import never displaces a dock.** An imported lane takes an edge only
    /// if that edge is free — including free of an earlier lane in the same
    /// file, so a hand-edited strip with two left docks in it is merged rather
    /// than refused. Import is a merge by its own definition above, and kicking
    /// the user's music player off the screen to install one from a file is the
    /// destructive version of it: the lane arrives in the strip instead, where
    /// it is one keystroke from being docked on purpose.
    pub fn import_strip(&self, json: String) -> Result<StripState> {
        let lanes = portable::import(&json)?;
        let mut inner = self.inner.lock();
        let now = now_ms();
        let mut taken: Vec<DockSide> = inner
            .ledger
            .lanes()?
            .iter()
            .filter_map(|l| l.dock.map(|d| d.side))
            .collect();

        for incoming in lanes {
            let ordinal = Self::place(&mut inner.ledger, &Placement::End)?;
            let dock = incoming.dock.filter(|d| !taken.contains(&d.side)).map(|d| Dock {
                width_pt: d.width_pt.clamp(DOCK_MIN_PT, DOCK_MAX_PT),
                ..d
            });
            if let Some(d) = dock {
                taken.push(d.side);
            }
            let lane = Lane {
                id: new_id(),
                ordinal,
                width_pt: incoming.width_pt.clamp(LANE_MIN_PT, LANE_MAX_PT * incoming.span.clamp(1, 2)),
                title: incoming.title,
                project_root: incoming.project_root,
                project_source: incoming.project_source,
                created_at: now,
                last_focus_at: now,
                keep_live: incoming.keep_live,
                dock,
                span: incoming.span.clamp(1, 2),
                panes: Vec::new(),
            };
            inner.ledger.insert_lane(&lane)?;

            for (position, p) in incoming.panes.iter().enumerate() {
                inner.ledger.insert_pane(&Pane {
                    id: new_id(),
                    lane_id: lane.id.clone(),
                    position: position as u32,
                    kind: p.kind,
                    relay_session_id: p.relay_session_id.clone(),
                    url: p.url.clone(),
                    scroll_y: p.scroll_y,
                    data_store_id: None,
                    snapshot_path: None,
                    state: PaneState::Live,
                    height_weight: p.height_weight,
                    zoom: p.zoom,
                })?;
            }
        }
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

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
        ordinal::between(before, after)
            .ok_or_else(|| CoreError::Invalid { message: "ordinal space exhausted after renormalize".into() })
    }

    /// The dock a lane is currently in, or an error naming the lane that is not
    /// docked. Both `set_dock_mode` and `set_dock_width` are edits to a dock
    /// that exists, never a way to create one.
    fn dock_of(inner: &Inner, lane_id: &str) -> Result<Dock> {
        inner.ledger.lane(lane_id)?.dock.ok_or_else(|| CoreError::Invalid {
            message: format!("lane {lane_id} is not docked"),
        })
    }

    fn bump(inner: &mut Inner) {
        inner.revision += 1;
    }

    fn snapshot(inner: &Inner) -> Result<StripState> {
        let mut lanes = inner.ledger.lanes()?;
        if let Some(root) = &inner.gather {
            // Docked lanes survive the filter. Gather narrows *the strip* — and
            // a docked lane is not in the strip, it is held at an edge of the
            // window beside it. Filtering one out would take it out of the
            // snapshot, which is what the shell retires lane views from: press
            // ⌘G on a project your music player is not tagged with, and the
            // player is destroyed. Nothing about that is what the user asked
            // for, and no amount of care in the layout can put it back, because
            // the layout would be doing exactly what it is told.
            lanes.retain(|l| l.dock.is_some() || l.project_root.as_deref() == Some(root.as_str()));
        }
        let scroll_x = inner.ledger.app_state(KEY_SCROLL_X)?.and_then(|s| s.parse().ok()).unwrap_or(0.0);
        Ok(StripState {
            lanes,
            scroll_x,
            focused_pane_id: inner.ledger.app_state(KEY_FOCUSED_PANE)?,
            gather_filter: inner.gather.clone(),
            revision: inner.revision,
        })
    }
}
