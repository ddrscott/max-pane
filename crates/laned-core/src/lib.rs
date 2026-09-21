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

pub mod clips;
pub mod error;
pub mod eviction;
pub mod history;
pub mod import;
pub mod ledger;
pub mod logins;
pub mod model;
pub mod ordinal;
pub mod portable;
pub mod project;
pub mod search;

use error::{CoreError, Result};
use ledger::Ledger;
use model::*;
use parking_lot::Mutex;
use std::collections::BTreeSet;
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

/// The narrowest a lane may be when it is put there by a size preset rather
/// than dragged.
///
/// Deliberately below `LANE_MIN_PT`. The `s` preset keeps a terminal's columns
/// and shrinks its font to 60%, so its width is *computed* from the cell metric
/// — about 412 pt for 80 columns of 13 pt JetBrains Mono — and clamping that to
/// 420 would give it a column it did not ask for. The preset is the point, so
/// it is honoured; dragging still stops at `LANE_MIN_PT`. 240 rather than
/// nothing for the same reason a dock's floor is 240: below it there is no lane
/// left to read.
pub const LANE_PRESET_MIN_PT: u32 = 240;

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
const KEY_LAYOUT: &str = "strip_layout";
/// The lanes a collapsed sidebar group hides, as a JSON array of lane ids.
const KEY_HIDDEN_LANES: &str = "hidden_lane_ids";
/// The sidebar's collapsed groups and sections, as a JSON array of their keys.
const KEY_SIDEBAR_COLLAPSED: &str = "sidebar_collapsed";

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
    /// `Some(project_root)` while the user is in a gather view. View-only.
    gather: Option<String>,
    /// Lanes a collapsed sidebar group hides (ADR-0024). The second reason a
    /// lane can be narrowed out of the snapshot, and like the first it is
    /// view-only: no ordinal, width or pane is written because of it. Unlike
    /// the first it is persisted, because a collapse is — a relaunch comes
    /// back with the same lanes out of the way.
    ///
    /// Lane ids rather than project tags: a sidebar group is a session's
    /// *cwd*, which only the shell hears about, so the shell says which lanes
    /// and this says what being hidden means.
    hidden: BTreeSet<String>,
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
/// Which secret shape `text` has, by name, or `None` ([`clips::secret_shape`]).
/// For the shell to ask *before* a transform that would hide the shape:
/// base64 of a token looks like nothing, so the pane asks about the source.
#[uniffi::export]
pub fn clip_secret_shape(text: String) -> Option<String> {
    clips::secret_shape(&text).map(str::to_string)
}

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
        // A private lane is gone on close, and "close" includes the app
        // quitting with the lane still up, or dying. This is the only place
        // that can promise it: before the first `state()` the shell will
        // render, whatever was left in the file from the last run goes.
        if ledger.purge_private_lanes()? > 0 {
            // The keyboard may have been in the lane that just went. Hand it
            // to the first pane left, the way `close_pane` would have.
            let focused = ledger.app_state(KEY_FOCUSED_PANE)?;
            if focused.as_deref().is_some_and(|f| ledger.pane(f).is_err()) {
                if let Some(first) = ledger.lanes()?.iter().flat_map(|l| &l.panes).next() {
                    ledger.set_app_state(KEY_FOCUSED_PANE, &first.id)?;
                }
            }
        }
        // Before the first `state()`: the strip the shell draws first is the
        // strip as it was left, hidden lanes and all.
        let hidden = Self::stored_set(&ledger, KEY_HIDDEN_LANES)?;
        Ok(std::sync::Arc::new(Core {
            inner: Mutex::new(Inner {
                ledger,
                index: search::Index::default(),
                visits: history::VisitMemo::default(),
                gather: None,
                hidden,
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
                gather: None,
                hidden: BTreeSet::new(),
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
        self.create_lane_impl(
            placement,
            kind,
            relay_session_id,
            None,
            url,
            inherit_tag_from_lane,
            false,
            None,
        )
    }

    /// A lane for a session that is already running on a remote relay-tty
    /// server (ADR-0020). `create_lane` for a pty pane, with the server named,
    /// which is the one thing the local door cannot say. Not a parameter on
    /// `create_lane` because that door has forty callers that all mean
    /// "this Mac", and `None` in every one of them would be the field's
    /// meaning stated forty times.
    pub fn attach_remote_session(
        &self,
        placement: Placement,
        relay_server: String,
        relay_session_id: String,
        inherit_tag_from_lane: Option<String>,
    ) -> Result<StripState> {
        self.create_lane_impl(
            placement,
            PaneKind::Pty,
            Some(relay_session_id),
            Some(relay_server),
            None,
            inherit_tag_from_lane,
            false,
            None,
        )
    }

    /// A private web lane (⇧⌘N): one pane on `url`, in a lane the ledger will
    /// forget at the next open (migration 0014). Web only, because a
    /// terminal's session is relay-tty's and outlives any lane; "private" is a
    /// statement about cookie jars and history, which only a page has.
    ///
    /// Otherwise `create_lane` exactly: same placement, same tag inheritance,
    /// same focus. The pane's `data_store_id` names the non-persistent
    /// `WKWebsiteDataStore` the shell keeps for it — `private:<lane id>` for a
    /// fresh one, or `data_store_id` to join the jar of the private pane that
    /// ⌘-clicked this lane into being, so a sign-in there is a sign-in here.
    /// The shell drops the store when no lane names it any more;
    /// `record_visit` and `set_pane_interaction_state` refuse its panes.
    pub fn create_private_web_lane(
        &self,
        placement: Placement,
        url: String,
        inherit_tag_from_lane: Option<String>,
        data_store_id: Option<String>,
    ) -> Result<StripState> {
        self.create_lane_impl(
            placement,
            PaneKind::Web,
            None,
            None,
            Some(url),
            inherit_tag_from_lane,
            true,
            data_store_id,
        )
    }

    /// Append a pane to the bottom of an existing lane's stack (⌘D).
    pub fn add_pane(
        &self,
        lane_id: String,
        kind: PaneKind,
        relay_session_id: Option<String>,
        url: Option<String>,
    ) -> Result<StripState> {
        self.add_pane_impl(lane_id, kind, relay_session_id, None, url)
    }

    /// `add_pane` for a session on a remote server; see `attach_remote_session`.
    pub fn add_remote_pane(
        &self,
        lane_id: String,
        relay_server: String,
        relay_session_id: String,
    ) -> Result<StripState> {
        self.add_pane_impl(lane_id, PaneKind::Pty, Some(relay_session_id), Some(relay_server), None)
    }

    /// A server was renamed in `config.toml`: every pane on it, and every
    /// lane tagged `old:path` by `observe_cwd`, follows the new name, so the
    /// lanes keep attaching and keep gathering with each other. A manual
    /// tag is the user's own words and is left alone. Returns how many panes
    /// moved. Nothing to do when the two names are the same.
    pub fn rename_relay_server(&self, old: String, new: String) -> Result<u32> {
        if old == new {
            return Ok(0);
        }
        let mut inner = self.inner.lock();
        let moved = inner.ledger.rename_relay_server(&old, &new)?;
        if moved > 0 {
            Self::bump(&mut inner);
        }
        Ok(moved)
    }


    /// Every lane in the ledger, in ordinal order, **ignoring a gather filter**.
    ///
    /// `state()` narrows to the gathered project, which is right for the strip
    /// and wrong for every question of the form "is this session already on the
    /// strip?". The sidebar and the ⌘O picker asked it of the narrowed list, so
    /// under a gather every session tagged elsewhere looked unattached, a click
    /// attached it again, and the new lane was hidden by the same gather — which
    /// is how the owner's ledger came to hold five lanes on one session, all
    /// created inside three seconds.
    pub fn all_lanes(&self) -> Result<Vec<Lane>> {
        let inner = self.inner.lock();
        inner.ledger.lanes()
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

    // ---- moving a pane between lanes ---------------------------------------

    /// Move a pane into another lane's stack — or to a different place in its
    /// own — landing at `index` among the panes already there, counted
    /// **without** this one.
    ///
    /// The drop half of a pane drag. One level of nesting is preserved by
    /// construction: a pane's new home is a lane, and a lane holds panes, so
    /// there is no shape here that could become a tree.
    ///
    /// # What happens to a lane left empty
    ///
    /// It is deleted, and this is `close_pane`'s rule rather than a new one:
    /// *an empty column is not a thing the user can do anything with*. Leaving
    /// it would put a lane on the strip with a header, a width and nothing
    /// under it — reachable by ⌘[ and ⌘], counted by the edge rails, offered by
    /// ⌘P, and impossible to remove except by a ⋯ menu nobody would think to
    /// look in. The alternative that was considered and rejected is keeping the
    /// lane so an undo could put the pane back; there is no undo in this app
    /// yet, and a ghost column waiting for one that does not exist is a lie on
    /// screen today.
    ///
    /// # What happens to the pane's height
    ///
    /// A pane joining a *different* lane arrives at the mean of that lane's
    /// weights — the same rule `add_pane` follows, and for the same reason: the
    /// newcomer takes an equal share of the enlarged stack and everyone already
    /// there gives up height in proportion to what they had. A reorder inside
    /// one lane changes no weight at all. Heights are shares of a column, and
    /// a share is only meaningful against the column it was measured in.
    pub fn move_pane(&self, pane_id: String, lane_id: String, index: u32) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let pane = inner.ledger.pane(&pane_id)?;
        let target = inner.ledger.lane(&lane_id)?;

        let weight = if pane.lane_id == lane_id {
            None
        } else {
            Some(mean_weight(&target.panes.iter().map(|p| p.height_weight).collect::<Vec<_>>()))
        };
        let from = inner.ledger.move_pane_to(&pane_id, &lane_id, index, weight)?;
        if from != lane_id && inner.ledger.lane(&from)?.panes.is_empty() {
            inner.ledger.delete_lane(&from)?;
        }
        // The pane the user just picked up and put down is the pane they are
        // now working in. Without this the keyboard stays wherever it was,
        // which after a drag that dissolved the source lane is a pane that no
        // longer exists.
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane_id)?;
        inner.ledger.touch_focus(&lane_id, now_ms())?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Pull a pane out into a lane of its own, placed by `placement`.
    ///
    /// The other half of the drop: between two lanes, or off either end of the
    /// strip.
    ///
    /// # A lane that is only this pane is *moved*, not rebuilt
    ///
    /// Pulling the single pane of a lane into a new lane and deleting the old
    /// one is the same strip, one lane at a time — except that it would throw
    /// away everything the lane carries and the pane does not: the width the
    /// user dragged it to, its title, its project tag, and `keep_live`. So that
    /// case is a `move_lane`, and the only thing that makes it look different
    /// from ⌘⇧→ is where the pointer was. A lane dragged into the strip stops
    /// holding an edge, because a dock that has visibly been dropped between
    /// two lanes and is still at the wall is a gesture that did nothing.
    pub fn move_pane_to_new_lane(
        &self,
        pane_id: String,
        placement: Placement,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let pane = inner.ledger.pane(&pane_id)?;
        let source = inner.ledger.lane(&pane.lane_id)?;

        if source.panes.len() == 1 {
            // Placed against the lane it is already in: it is already there.
            if let Placement::RightOf { lane_id } | Placement::LeftOf { lane_id } = &placement {
                if lane_id == &source.id {
                    return Self::snapshot(&inner);
                }
            }
            let ordinal = Self::place(&mut inner.ledger, &placement)?;
            inner.ledger.set_ordinal(&source.id, ordinal)?;
            if source.dock.is_some() {
                inner.ledger.set_dock(&source.id, None)?;
            }
            inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane_id)?;
            inner.ledger.touch_focus(&source.id, now_ms())?;
            Self::bump(&mut inner);
            return Self::snapshot(&inner);
        }

        let ordinal = Self::place(&mut inner.ledger, &placement)?;
        let now = now_ms();
        let lane = Lane {
            id: new_id(),
            // The width the pane was already being drawn at. A terminal's grid
            // is derived from it (ADR-0007 forbids reshaping the PTY), so a
            // pane that came out of a 900 pt column into a 656 pt one would
            // reflow every line of scrollback as a side effect of being moved.
            width_pt: source.width_pt,
            ordinal,
            title: None,
            project_root: source.project_root.clone(),
            project_source: ProjectSource::Inherited,
            created_at: now,
            last_focus_at: now,
            keep_live: false,
            dock: None,
            span: 1,
            is_private: false,
            panes: Vec::new(),
        };
        inner.ledger.insert_lane(&lane)?;
        // 1.0, the weight a lane's first pane is born with everywhere else:
        // the only ratio in a stack of one is a share of the whole.
        inner.ledger.move_pane_to(&pane_id, &lane.id, 0, Some(1.0))?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane_id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// Drop a whole lane into another lane's stack: every pane it holds joins
    /// `into_lane_id` at `index`, top to bottom in the order they already
    /// stood, and the lane they came from is gone.
    ///
    /// The drop half of dragging a lane by its **header** onto the top or the
    /// bottom of a pane. A lane of one is the common case and is exactly
    /// `move_pane`; a lane of several stays one flat stack, because a pane's
    /// only parent is a lane and there is no shape a nested split could be
    /// written into.
    ///
    /// # Heights
    ///
    /// The arrivals keep their split *with each other* and, between them, take
    /// one mean share of the target per pane — `add_pane`'s rule, applied to the
    /// group rather than pane by pane. Pane by pane would flatten a 3:1 split
    /// the user dragged into 1:1 on the way in; the group rule carries it.
    ///
    /// # Focus
    ///
    /// The pane with the keyboard keeps it if it was one of the arrivals;
    /// otherwise the top arrival takes it, for `move_pane`'s reason — the thing
    /// you just put down is the thing you are working in.
    pub fn move_lane_into(
        &self,
        lane_id: String,
        into_lane_id: String,
        index: u32,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        if lane_id == into_lane_id {
            return Err(CoreError::Invalid { message: "a lane cannot be dropped into itself".into() });
        }
        let source = inner.ledger.lane(&lane_id)?;
        let target = inner.ledger.lane(&into_lane_id)?;
        let Some(first) = source.panes.first().map(|p| p.id.clone()) else {
            return Self::snapshot(&inner);
        };

        let mean = mean_weight(&target.panes.iter().map(|p| p.height_weight).collect::<Vec<_>>());
        let sane: Vec<f64> = source
            .panes
            .iter()
            .map(|p| if p.height_weight.is_finite() && p.height_weight > 0.0 { p.height_weight } else { 1.0 })
            .collect();
        let total: f64 = sane.iter().sum();
        let share = mean * source.panes.len() as f64;
        let weights: Vec<(String, f64)> = source
            .panes
            .iter()
            .zip(&sane)
            .map(|(p, w)| (p.id.clone(), share * w / total))
            .collect();
        inner.ledger.merge_lane_into(&lane_id, &into_lane_id, index, &weights)?;

        let focused = inner.ledger.app_state(KEY_FOCUSED_PANE)?;
        let keeps = focused.as_ref().is_some_and(|f| source.panes.iter().any(|p| &p.id == f));
        if !keeps {
            inner.ledger.set_app_state(KEY_FOCUSED_PANE, &first)?;
        }
        inner.ledger.touch_focus(&into_lane_id, now_ms())?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    // ---- ordering ----------------------------------------------------------

    /// Move a lane to a new place in the strip. The only thing that ever writes
    /// an ordinal outside of creation — and only ever because the user asked.
    ///
    /// A docked lane placed this way stops holding its edge, which is
    /// `move_pane_to_new_lane`'s rule for a lane of one: the only caller is a
    /// header dropped beside another lane, and a dock visibly put down between
    /// two columns that is still at the wall is a gesture that did nothing.
    pub fn move_lane(&self, lane_id: String, placement: Placement) -> Result<StripState> {
        let mut inner = self.inner.lock();
        if let Placement::RightOf { lane_id: t } | Placement::LeftOf { lane_id: t } = &placement {
            if t == &lane_id {
                return Err(CoreError::Invalid {
                    message: "a lane cannot be placed relative to itself".into(),
                });
            }
        }
        let docked = inner.ledger.lane(&lane_id)?.dock.is_some();
        let ordinal = Self::place(&mut inner.ledger, &placement)?;
        inner.ledger.set_ordinal(&lane_id, ordinal)?;
        if docked {
            inner.ledger.set_dock(&lane_id, None)?;
        }
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

    /// Put a lane at a size preset (`s | m | xl`): its width, its span and its
    /// panes' zoom, as **one** revision.
    ///
    /// One call rather than three because the shell animates the difference
    /// between two snapshots. Span, then width, then zoom as separate writes is
    /// three snapshots, three diffs and a lane that visibly steps through a
    /// shape nobody chose on its way to the one they did.
    ///
    /// The width floor is `LANE_PRESET_MIN_PT`, not `LANE_MIN_PT`: see the
    /// constant. The ceiling is the span's, as in `set_lane_width`. Every zoom is
    /// checked before anything is written, so a bad one leaves the lane exactly
    /// as it was rather than half-resized.
    ///
    /// This is the only way to set `span`. Span Lane (⌘\, 1800 pt) was a second
    /// way to make a lane wide, at a different width from `xl`; it is gone, and
    /// `span` is now whatever the preset says (1, or 2 for `xl`). A lane stored
    /// at span 2 by the old command keeps its span and its width.
    ///
    /// On a **docked** lane the width is the dock's, clamped into
    /// [`DOCK_MIN_PT`]..=[`DOCK_MAX_PT`], and the lane's own width and span are
    /// left alone, the same as `set_dock_width`: they are what the lane goes back
    /// to in the strip. So `xl` on a dock is 900 pt, not 1312.
    pub fn set_lane_size(
        &self,
        lane_id: String,
        width_pt: u32,
        span: u32,
        zooms: Vec<PaneZoomSetting>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let lane = inner.ledger.lane(&lane_id)?;
        for z in &zooms {
            if !z.zoom.is_finite() || z.zoom <= 0.0 {
                return Err(CoreError::Invalid {
                    message: format!("pane zoom must be finite and positive, got {}", z.zoom),
                });
            }
        }
        if let Some(dock) = lane.dock {
            let width_pt = width_pt.clamp(DOCK_MIN_PT, DOCK_MAX_PT);
            inner.ledger.set_dock(&lane_id, Some(Dock { width_pt, ..dock }))?;
        } else {
            let span = span.clamp(1, 2);
            inner.ledger.set_span(&lane_id, span)?;
            inner.ledger.update_lane_width(&lane_id, width_pt.clamp(LANE_PRESET_MIN_PT, LANE_MAX_PT * span))?;
        }
        for z in &zooms {
            inner.ledger.update_pane_zoom(&z.pane_id, z.zoom)?;
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
    ///
    /// A lane whose terminal is on a remote server is tagged `host:path` from
    /// the cwd as given, with no walk: the path is only a path on that
    /// machine, and walking this Mac's tree for it would tag the lane with
    /// whatever local repository happened to share a prefix (ADR-0020). A
    /// remote project therefore gathers with itself and never with a local
    /// path that happens to match.
    pub fn observe_cwd(&self, lane_id: String, cwd: String) -> Result<bool> {
        let mut inner = self.inner.lock();
        let lane = inner.ledger.lane(&lane_id)?;
        let remote = lane.panes.iter().find_map(|p| p.relay_server.as_deref());
        let root = match remote {
            Some(server) if !cwd.is_empty() => Some(format!("{server}:{cwd}")),
            Some(_) => None,
            None => self.projects.root_of(&cwd),
        };
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
        // A private pane's history, scroll and form state are exactly what a
        // private lane exists not to keep. Refused here rather than trusted to
        // the shell, so no caller can write one by forgetting to check.
        if state.is_some() && inner.ledger.pane_is_private(&pane_id)? {
            return Ok(());
        }
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

    /// Every remembered answer about `feature` in one cookie jar, so a pane can
    /// hand the page its `Notification.permission` before the page asks.
    pub fn site_permissions(
        &self,
        data_store_id: String,
        feature: SiteFeature,
    ) -> Result<Vec<SiteGrant>> {
        let inner = self.inner.lock();
        inner.ledger.site_permissions(&data_store_id, feature)
    }

    pub fn forget_site_permissions(&self, data_store_id: String, origin: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.forget_site_permissions(&data_store_id, &origin)
    }

    // ---- paste history (ADR-0031) ------------------------------------------

    /// Remember `text` as pasted into, or copied out of, the terminal pane
    /// `pane_id`. True when it was kept. `keep` and `days` are the settings
    /// `paste_history_keep` and `paste_history_days` as they are now; `keep`
    /// of 0 is off. What is refused and what is redacted is decided in the
    /// ledger and in [`clips`], not by the caller: a private lane's pane, an
    /// unknown pane, blank text and anything over 64 KB are never written,
    /// and text shaped like a secret is written as four characters and `•••`.
    pub fn record_clip(
        &self,
        pane_id: String,
        kind: ClipKind,
        text: String,
        keep: u32,
        days: u32,
    ) -> Result<bool> {
        let inner = self.inner.lock();
        inner
            .ledger
            .record_clip(&pane_id, kind, &text, keep, days, now_ms())
    }

    /// Paste history, newest first, after ageing it by the settings.
    pub fn clip_history(&self, keep: u32, days: u32) -> Result<Vec<ClipEntry>> {
        let inner = self.inner.lock();
        inner.ledger.prune_clips(keep, days, now_ms())?;
        inner.ledger.clips()
    }

    pub fn delete_clip(&self, id: i64) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.delete_clip(id)
    }

    /// Clear Paste History, and what `paste_history = false` does: the rows
    /// go. Returns how many there were.
    pub fn clear_clip_history(&self) -> Result<u64> {
        let inner = self.inner.lock();
        inner.ledger.clear_clips()
    }

    // ---- content blocking ------------------------------------------------

    /// The sites the ad and tracker blocker is switched off for: registrable
    /// domains, lowercased. The shell reads this once and applies it on every
    /// navigation itself; the rule list the blocker compiles is the shell's
    /// own cache and never reaches the ledger.
    pub fn blocking_exempt_domains(&self) -> Result<Vec<String>> {
        let inner = self.inner.lock();
        inner.ledger.blocking_exempt_domains()
    }

    /// Switch the blocker off for one site, or back on. A person's decision,
    /// like a site permission; nothing infers one. No snapshot is published:
    /// the strip's shape is untouched, and the pane that flipped it reloads.
    pub fn set_blocking_exempt(&self, domain: String, exempt: bool) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.set_blocking_exempt(&domain, exempt, now_ms())
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
        redirect_chain: Vec<String>,
    ) -> Result<()> {
        let Some(url) = history::normalize_url(&url) else { return Ok(()) };
        let now = now_ms();
        let mut inner = self.inner.lock();
        // A visit from a private lane is not history. Before the memo, so a
        // private pane leaves no trace even in the per-launch burst filter.
        if inner.ledger.pane_is_private(&pane_id)? {
            return Ok(());
        }
        if !inner.visits.accept(&pane_id, &url, now) {
            // Still a chance to learn the name: the duplicate settle is often
            // the one that finally has a <title>.
            if let Some(t) = title.as_deref() {
                inner.ledger.name_visit(&url, t)?;
            }
            return Ok(());
        }
        inner.ledger.record_visit(&url, title.as_deref(), now)?;
        for hop in &redirect_chain {
            let Some(hop) = history::normalize_url(hop) else { continue };
            // `demote_to_alias` rather than `note_visit_alias`, because a hop
            // may already be an entry in its own right: a client-side redirect
            // finishes loading before it redirects, so the interstitial has
            // been through `didFinish` and has a row. Server hops never do, and
            // for those this is the same thing `note_visit_alias` was.
            inner.ledger.demote_to_alias(&hop, &url)?;
        }
        Ok(())
    }

    /// The page's `<title>`, which usually lands after the navigation finished.
    ///
    /// Separate from [`Core::record_visit`] because it is a correction to a
    /// visit rather than another one: it never inserts and never counts.
    pub fn name_visit(&self, url: String, title: String) -> Result<()> {
        let Some(url) = history::normalize_url(&url) else { return Ok(()) };
        let inner = self.inner.lock();
        inner.ledger.name_visit(&url, &title)
    }

    /// History, best match first — or most recent first for an empty query,
    /// which is what the palette shows before anything is typed.
    ///
    /// The corpus is narrowed in SQLite and ranked in Rust, and nothing is held
    /// between calls. Round 1 cached the scanned rows because every keystroke
    /// re-read the same 2 000 of them; now the index reads only the rows that
    /// contain what was typed, so the read shrinks as the query grows and a
    /// cache would mostly be a way to serve a page that has just been visited
    /// from before it was.
    pub fn history(&self, query: String, limit: u32) -> Result<Vec<HistoryEntry>> {
        let inner = self.inner.lock();
        let needle = history::needle(&query);
        if needle.is_empty() {
            return inner.ledger.history_newest(limit);
        }
        inner.ledger.history_search(&needle, 0, limit)
    }

    /// The same corpus, for a window with room in it: paged, and ordered by the
    /// calendar rather than by `seq` when nothing is typed.
    ///
    /// # Why the history view does not simply call `history` with an offset
    ///
    /// Two differences, and both of them are the window's, not the palette's.
    ///
    /// *Paging.* The palette shows what fits over a text field and is finished;
    /// it has never asked for row 61 and an `offset` argument it always passes
    /// `0` to is a parameter that exists in order to be wrong one day.
    ///
    /// *Order.* An empty query here is answered by
    /// [`crate::ledger::Ledger::history_by_date`], which orders by
    /// `last_visit_at` so that the window's day headers are true — see that
    /// method for why `seq` is still right for the palette. A query is ranked by
    /// the same [`crate::history::Ranking`] the palette uses and comes back in
    /// score order, so ⌘Y and this window never disagree about which of two
    /// pages matches better. That is also why the window shows no day headers
    /// while something is typed: relevance order scatters the days, and a header
    /// over rows that are not all from that day is the kind of label this round
    /// exists to stop printing.
    pub fn history_page(
        &self,
        query: String,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<HistoryEntry>> {
        let inner = self.inner.lock();
        let needle = history::needle(&query);
        if needle.is_empty() {
            return inner.ledger.history_by_date(offset, limit);
        }
        inner.ledger.history_search(&needle, offset, limit)
    }

    /// How many pages were last visited in `[start_ms, end_ms)` — the number on
    /// a day header, and the number the clear dialog quotes before it acts.
    ///
    /// The caller owns the calendar: it passes the boundaries its own timezone
    /// produced rather than a day index this crate would have to interpret.
    pub fn history_day_count(&self, start_ms: i64, end_ms: i64) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.history_count_between(start_ms, end_ms)
    }

    /// How many pages are on record, for the palette's footer.
    pub fn history_count(&self) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.history_count()
    }

    /// How many pages a query can actually reach.
    ///
    /// Every one of them, now — which is the whole of this round's first item,
    /// and why this method still exists rather than being deleted along with
    /// the caps. It used to be `min(count, HISTORY_SCAN_ROWS)`: the table held
    /// 5 000 rows and a query scored the newest 2 000, so the palette's footer
    /// read "0 of 5013 pages" over a corpus in which row 2 499 was unfindable.
    /// A label that is wrong about the thing it labels is worse than no label,
    /// so the picker asks this instead of assuming, and if a reach limit ever
    /// comes back it will be this number that says so.
    pub fn history_searchable_count(&self) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.history_count()
    }

    /// Drop one page, and every redirect that pointed at it. The palette's ⌘⌫.
    pub fn forget_visit(&self, url: String) -> Result<()> {
        let url = history::normalize_url(&url).unwrap_or(url);
        let inner = self.inner.lock();
        inner.ledger.forget_visit(&url)
    }

    /// Forget everything. There is no undo, which is the point of it.
    pub fn clear_history(&self) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.clear_history()
    }

    /// Forget every page last visited at or after `cutoff_ms`, and report how
    /// many went. `0` is everything.
    ///
    /// The cutoff is an instant rather than a named range ("last hour") because
    /// naming the ranges is the window's job and this should not have an opinion
    /// about which of them exist. What it does have an opinion about is the
    /// unit: pages, not visits — see
    /// [`crate::ledger::Ledger::clear_history_since`] for why a page first seen
    /// a year ago can be inside "the last hour".
    pub fn clear_history_since(&self, cutoff_ms: i64) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.clear_history_since(cutoff_ms)
    }

    /// Every browser on this machine we could import history from — found by
    /// looking for the files, so the wizard offers what is installed rather
    /// than a list of browsers the user does not have.
    ///
    /// A source we are not allowed to read is still returned, carrying the
    /// sentence that says why. Safari's history is behind Full Disk Access and
    /// the failure without it reads exactly like a corrupt database; a row that
    /// says so is the difference between a checkbox and a bug report.
    pub fn history_sources(&self) -> Vec<import::HistorySource> {
        import::detect()
    }

    /// What importing `source` would do, without doing any of it.
    ///
    /// The wizard's dry run, and the only screen between the user and a
    /// `Replace`. It costs one snapshot of the source — 1.1 s for the owner's
    /// 642 MB Vivaldi profile, because APFS copies by reference — so the import
    /// that follows takes a second one rather than this holding 642 MB of his
    /// browsing history open across however long he reads the report for.
    pub fn plan_history_import(
        &self,
        source: import::HistorySource,
        mode: import::ImportMode,
    ) -> Result<import::ImportPlan> {
        let inner = self.inner.lock();
        let (pages, skipped) = Self::read_source(&inner.ledger, &source)?;
        let known = inner.ledger.preview_import(&pages)?;
        let bookmarks = Self::read_source_bookmarks(&inner.ledger, &source)?;
        Ok(Self::plan(&inner.ledger, &pages, skipped, known, bookmarks.as_ref(), mode)?)
    }

    /// Import `source`, for real.
    ///
    /// `Replace` backs the ledger up first and names the file in the outcome —
    /// the whole strip, not only history, because the ledger is one file and a
    /// backup of part of it is not a way back.
    pub fn import_history(
        &self,
        source: import::HistorySource,
        mode: import::ImportMode,
    ) -> Result<import::ImportOutcome> {
        let started = now_ms();
        let mut inner = self.inner.lock();
        let (pages, skipped) = Self::read_source(&inner.ledger, &source)?;
        let known = inner.ledger.preview_import(&pages)?;
        let bookmarks = Self::read_source_bookmarks(&inner.ledger, &source)?;
        let plan = Self::plan(&inner.ledger, &pages, skipped, known, bookmarks.as_ref(), mode)?;

        // Before either half is written, and it covers both: the ledger is one
        // file, so the way back from a `Replace` that took the wrong browser's
        // bookmarks is the same file as the way back from its history.
        let backup_path = match mode {
            import::ImportMode::Replace => Self::back_up_ledger(&inner.ledger)?,
            import::ImportMode::Merge => None,
        };
        let (inserted, updated, discarded) = inner.ledger.apply_import(&pages, mode)?;
        let (bookmarks_inserted, bookmarks_discarded) = match &bookmarks {
            Some((flat, _)) => inner.ledger.apply_bookmark_import(flat, mode, now_ms())?,
            None => (0, 0),
        };
        Ok(import::ImportOutcome {
            plan,
            inserted,
            updated,
            discarded,
            bookmarks_inserted,
            bookmarks_discarded,
            backup_path,
            elapsed_ms: now_ms() - started,
        })
    }

    // ---- passwords ---------------------------------------------------------

    /// Every Chromium profile on this Mac that has saved passwords.
    ///
    /// Chromium only, and the list is shorter than `history_sources` on
    /// purpose: Safari's passwords are already Keychain items, so there is
    /// nothing to import from it, and Firefox's are behind NSS. See
    /// [`crate::logins`] for why that is a different record rather than two
    /// more fields on `HistorySource`.
    pub fn login_sources(&self) -> Vec<logins::LoginSource> {
        logins::detect()
    }

    /// Every saved login in `source`, **still encrypted**.
    ///
    /// This is the whole of what the platform-agnostic half of the app can do
    /// with a password: copy the file, read the rows, hand back ciphertext.
    /// The key is a macOS Keychain item and the decryption happens in the app
    /// process; nothing here can read one, which is the point.
    ///
    /// Not behind the mutex's ledger work for any reason but consistency with
    /// its neighbours — it writes nothing. The copy it takes is deleted before
    /// this returns.
    pub fn browser_logins(&self, source: logins::LoginSource) -> Result<Vec<logins::SourceLogin>> {
        let inner = self.inner.lock();
        logins::read(&source, inner.ledger.path())
    }

    // ---- bookmarks ---------------------------------------------------------

    /// The whole tree, in the order it is drawn.
    ///
    /// Everything, in one call, on every change — which would be indefensible
    /// for history and is the obvious thing here. The corpus is what the user
    /// curated by hand: the owner's Vivaldi bar is eight folders, and a
    /// bookmark file an order of magnitude larger than anyone's is still four
    /// figures. Paging it would be a parameter that exists to be passed `0`.
    pub fn bookmarks(&self) -> Result<Vec<Bookmark>> {
        let inner = self.inner.lock();
        inner.ledger.bookmarks()
    }

    /// The folders alone — what a "file this somewhere" control offers.
    pub fn bookmark_folders(&self) -> Result<Vec<Bookmark>> {
        let inner = self.inner.lock();
        inner.ledger.bookmark_folders()
    }

    /// Every placement of one address, or empty when the page is not kept.
    ///
    /// The star's question. A list because the same page may be kept in two
    /// folders, and the star is lit by there being any.
    pub fn bookmarks_for_url(&self, url: String) -> Result<Vec<Bookmark>> {
        let Some(url) = history::normalize_url(&url) else { return Ok(Vec::new()) };
        let inner = self.inner.lock();
        inner.ledger.bookmarks_for_url(&url)
    }

    /// Keep a page, or make a folder. `url` is `None` for a folder.
    ///
    /// The address is normalized by the same function history uses, so that
    /// `example.com/` and `example.com` are the same bookmark and the star over
    /// a page you kept yesterday is lit today.
    ///
    /// An empty title is filled in with the address rather than refused. A page
    /// with no `<title>` is a real thing to want to keep — a JSON endpoint, a
    /// local dev server — and the alternative is a dialog that will not let you
    /// leave until you have named `localhost:3000/api/users` something else.
    pub fn add_bookmark(
        &self,
        parent_id: Option<String>,
        url: Option<String>,
        title: String,
    ) -> Result<Bookmark> {
        let url = match url {
            Some(raw) => Some(history::normalize_url(&raw).ok_or_else(|| CoreError::Ledger {
                message: format!("{raw} is not an address that can be kept"),
            })?),
            None => None,
        };
        let title = title.trim();
        let title = if title.is_empty() {
            url.as_deref().map(history::search_handle).unwrap_or("Folder")
        } else {
            title
        };
        let inner = self.inner.lock();
        inner.ledger.insert_bookmark(
            parent_id.as_deref(),
            url.is_none(),
            url.as_deref(),
            title,
            now_ms(),
        )
    }

    /// A bookmark's title is the user's, not the page's: nothing the page says
    /// later overwrites it. That is the difference between this and
    /// [`Core::name_visit`], which exists so a history row learns its name.
    pub fn rename_bookmark(&self, id: String, title: String) -> Result<()> {
        let title = title.trim();
        if title.is_empty() {
            return Ok(());
        }
        let inner = self.inner.lock();
        inner.ledger.rename_bookmark(&id, title)
    }

    /// File a row under a different folder — `None` for the bar — at `index`
    /// among what is already there, or at the end when `index` is `None`.
    ///
    /// `index` counts the siblings **without** this row, so it is where the row
    /// ends up rather than a gap in the list it is leaving. That matters only
    /// for a move within one folder, where the two differ by one; the caller
    /// that has table rows rather than siblings converts before calling.
    ///
    /// The drop half of a drag, and the folder popup in the editor, which passes
    /// no index because a popup has no place in it to point at.
    pub fn move_bookmark(
        &self,
        id: String,
        parent_id: Option<String>,
        index: Option<u32>,
    ) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.move_bookmark_to(&id, parent_id.as_deref(), index)
    }

    /// Move a row one place up or down among its siblings.
    ///
    /// The sidebar's **Move Up** / **Move Down**, and the reason the drag is not
    /// the only way: the move actually wanted here is "this folder belongs
    /// second, not eighth", eight times over, and a drag is the wrong instrument
    /// for a list being ordered deliberately rather than rearranged by eye.
    ///
    /// Stops at the ends rather than wrapping, and never changes folder. Both
    /// of those are the same rule: a nudge that moved a row out of the folder
    /// you were looking at would be a keystroke whose result is off screen.
    pub fn nudge_bookmark(&self, id: String, down: bool) -> Result<()> {
        let inner = self.inner.lock();
        let Some(row) = inner.ledger.bookmark(&id)? else { return Ok(()) };
        let siblings = inner.ledger.bookmark_siblings(row.parent_id.as_deref())?;
        let Some(at) = siblings.iter().position(|s| s == &id) else { return Ok(()) };
        let to = if down { at + 1 } else { at.checked_sub(1).unwrap_or(at) };
        if to == at || to >= siblings.len() {
            return Ok(());
        }
        inner.ledger.move_bookmark_to(&id, row.parent_id.as_deref(), Some(to as u32))
    }

    /// Drop a bookmark, or a folder and everything in it.
    pub fn remove_bookmark(&self, id: String) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.remove_bookmark(&id)
    }

    /// How many rows the tree holds, folders included.
    pub fn bookmark_count(&self) -> Result<u32> {
        let inner = self.inner.lock();
        inner.ledger.bookmark_count()
    }

    /// Bookmarks for the one door, best first — or in bar order for an empty
    /// query.
    ///
    /// # Why this ranks in Rust and history's palette also does
    ///
    /// Because it is the same ranker. [`crate::history::Ranking`] takes rows one
    /// at a time from wherever they come from, so the tiers ⌘O already applies
    /// to a page you visited apply unchanged to a page you kept — `hop` finds
    /// `hoppers` and not *Launchd notes*, in both lists, because it is one
    /// implementation and not two that agree today.
    ///
    /// What is not the same is the narrowing. History reaches its 112 840 rows
    /// through the trigram index of migration 0009; this reads the table. See
    /// 0010 for why: a hand-curated corpus is small enough that an index costs
    /// more to keep in step than it saves.
    pub fn search_bookmarks(&self, query: String, limit: u32) -> Result<Vec<BookmarkHit>> {
        let inner = self.inner.lock();
        let all = inner.ledger.bookmarks()?;
        let pages: Vec<Bookmark> = all.into_iter().filter(|b| !b.is_folder).collect();
        let needle = history::needle(&query);

        let chosen: Vec<(Bookmark, SearchField, i32)> = if needle.is_empty() {
            // Bar order, and no score: with nothing typed every row matches
            // equally, which is the same answer `history_newest` gives. The
            // picker sorts these in among everything else by when they were
            // kept, so a folder saved two years ago does not push this
            // morning's browsing off the list.
            pages
                .into_iter()
                .take(limit as usize)
                .map(|b| (b, SearchField::Url, 0))
                .collect()
        } else {
            // The haystack `Ranking` expects: address without its scheme, then
            // title, lowercase, newline-separated — exactly what migration 0009
            // writes for a visit. Built here rather than stored, because the
            // whole point of not having an index is not keeping a second copy
            // of the text in step.
            let hays: Vec<String> = pages
                .iter()
                .map(|b| {
                    format!(
                        "{}\n{}",
                        b.url.as_deref().map(history::search_handle).unwrap_or("").to_lowercase(),
                        b.title.to_lowercase()
                    )
                })
                .collect();
            let mut ranking = history::Ranking::new(&needle);
            for (i, hay) in hays.iter().enumerate() {
                // `seq` is the tie-break, and for a bookmark the closest thing
                // to it is when it was kept. Position in the bar would be the
                // other candidate and it is worse: it would make the first
                // folder's contents win every tie for ever.
                ranking.offer(i as i64, pages[i].added_at, history::Haystack::new(hay));
            }
            ranking
                .finish(limit as usize)
                .into_iter()
                .map(|h| (pages[h.rowid as usize].clone(), h.field, h.score))
                .collect()
        };

        let mut out = Vec::with_capacity(chosen.len());
        for (bookmark, matched_field, score) in chosen {
            let folder_path = inner.ledger.folder_path(&bookmark.id)?;
            out.push(BookmarkHit { bookmark, folder_path, matched_field, score });
        }
        Ok(out)
    }

    /// Remember how far a pane's contents are scaled. No snapshot is
    /// published: zoom changes what a pane draws, not the shape of the strip.
    pub fn set_pane_zoom(&self, pane_id: String, zoom: f64) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_zoom(&pane_id, zoom)
    }

    /// Remember whether a pane asks sites for their phone layout. No snapshot
    /// is published, as with zoom: the shell that flipped it reloads the page
    /// itself, and the strip's shape is untouched.
    pub fn set_pane_mobile(&self, pane_id: String, mobile: bool) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.update_pane_mobile(&pane_id, mobile)
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

    // ---- layout ------------------------------------------------------------

    /// Which layout the window was last showing: the strip, or the gallery.
    /// A ledger that has never been told reads as the strip.
    pub fn layout(&self) -> Result<crate::model::StripLayout> {
        let inner = self.inner.lock();
        Ok(inner
            .ledger
            .app_state(KEY_LAYOUT)?
            .map(|stored| crate::model::StripLayout::parse(&stored))
            .unwrap_or(crate::model::StripLayout::Lanes))
    }

    /// Switch layouts. Committed before the shell moves anything, like every
    /// other layout change — and it is the *only* write the switch makes: no
    /// ordinal, width or focus changes, and no revision bump, because the
    /// shape of the strip is exactly what it was.
    pub fn set_layout(&self, layout: crate::model::StripLayout) -> Result<()> {
        let inner = self.inner.lock();
        inner.ledger.set_app_state(KEY_LAYOUT, layout.as_str())
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

    // ---- hidden lanes (ADR-0024) ------------------------------------------

    /// Hide exactly these lanes from the snapshot: the lanes of the sidebar
    /// groups the user has collapsed. The gather filter's sibling, through
    /// the same door (`snapshot`), so everything that already copes with a
    /// lane the snapshot leaves out — `all_lanes`, search, export, the
    /// eviction plan — copes with these.
    ///
    /// Nothing about a lane is written: not its ordinal, its width, its
    /// panes or its state. The set itself is, so a relaunch agrees.
    ///
    /// A docked lane is never hidden, for gather's reason: it is not in the
    /// strip, and dropping it from the snapshot is how the shell destroys it.
    ///
    /// `hand_off_focus` is for the collapse itself: when the lane with the
    /// keyboard is one of those going, focus moves to the nearest lane still
    /// on the strip to its right, else to its left — the rule closing a lane
    /// follows. Without it (a recount after a session moved directory) focus
    /// is left alone, and the shell is expected not to hide the focused lane.
    pub fn set_hidden_lanes(&self, lane_ids: Vec<String>, hand_off_focus: bool) -> Result<StripState> {
        let mut inner = self.inner.lock();
        let next: BTreeSet<String> = lane_ids.into_iter().collect();
        if next == inner.hidden {
            return Self::snapshot(&inner);
        }
        if hand_off_focus {
            let lanes = inner.ledger.lanes()?;
            let focused = inner.ledger.app_state(KEY_FOCUSED_PANE)?;
            let visible = |l: &Lane| {
                l.dock.is_none()
                    && !next.contains(&l.id)
                    && inner.gather.as_deref().is_none_or(|root| l.project_root.as_deref() == Some(root))
            };
            let at = focused
                .as_deref()
                .and_then(|pane| lanes.iter().position(|l| l.panes.iter().any(|p| p.id == pane)));
            if let Some(at) = at.filter(|&at| lanes[at].dock.is_none() && next.contains(&lanes[at].id)) {
                let heir = lanes[at + 1..].iter().find(|l| visible(l)).or_else(|| lanes[..at].iter().rev().find(|l| visible(l)));
                if let Some(pane) = heir.and_then(|l| l.panes.first()) {
                    inner.ledger.touch_focus(&pane.lane_id, now_ms())?;
                    inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane.id)?;
                }
            }
        }
        let stored = serde_json::to_string(&next.iter().collect::<Vec<_>>()).unwrap_or_else(|_| "[]".into());
        inner.ledger.set_app_state(KEY_HIDDEN_LANES, &stored)?;
        inner.hidden = next;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// The sidebar's collapsed groups and sections, as the shell last stored
    /// them. Opaque here: the keys are the sidebar's (a directory, `host:path`,
    /// `host:`, the local section), and only the shell can say which lanes a
    /// key covers.
    pub fn sidebar_collapsed(&self) -> Result<Vec<String>> {
        let inner = self.inner.lock();
        Ok(Self::stored_set(&inner.ledger, KEY_SIDEBAR_COLLAPSED)?.into_iter().collect())
    }

    /// Store the sidebar's collapsed groups. No revision bump: the strip's
    /// shape changes only through [`Core::set_hidden_lanes`].
    pub fn set_sidebar_collapsed(&self, groups: Vec<String>) -> Result<()> {
        let inner = self.inner.lock();
        let set: BTreeSet<String> = groups.into_iter().collect();
        let stored = serde_json::to_string(&set.iter().collect::<Vec<_>>()).unwrap_or_else(|_| "[]".into());
        inner.ledger.set_app_state(KEY_SIDEBAR_COLLAPSED, &stored)
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
        //
        // A lane a collapsed group hides is the exception, and is handed over
        // with the rest: it is on no screen, so it is planned for as a lane
        // further away than any the strip holds — unparented, first in line
        // under memory pressure, never rehydrated until it is back. Leaving it
        // out would make a hidden page the one thing the budget cannot reach.
        let mut lanes = inner.ledger.lanes()?;
        if let Some(root) = &inner.gather {
            lanes.retain(|l| l.dock.is_some() || l.project_root.as_deref() == Some(root.as_str()));
        }
        let hidden = inner.hidden.clone();
        let now = now_ms();
        Ok(eviction::plan_with_hidden(&lanes, &hidden, &viewport, &memory, &mut inner.hysteresis, now))
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
                // The preset floor, so a lane at `s` exports and imports as
                // itself rather than coming back a column wider.
                width_pt: incoming.width_pt.clamp(LANE_PRESET_MIN_PT, LANE_MAX_PT * incoming.span.clamp(1, 2)),
                title: incoming.title,
                project_root: incoming.project_root,
                project_source: incoming.project_source,
                created_at: now,
                last_focus_at: now,
                keep_live: incoming.keep_live,
                dock,
                span: incoming.span.clamp(1, 2),
                // A strip file never carries a private lane: nothing about one
                // is meant to outlive its window, let alone a file.
                is_private: false,
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
                    relay_server: p.relay_server.clone(),
                    url: p.url.clone(),
                    scroll_y: p.scroll_y,
                    data_store_id: None,
                    snapshot_path: None,
                    state: PaneState::Live,
                    height_weight: p.height_weight,
                    zoom: p.zoom,
                    mobile: p.mobile,
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
    /// `add_pane` and `add_remote_pane`, which differ in one string. Not
    /// exported: uniffi would give the shell a third door.
    fn add_pane_impl(
        &self,
        lane_id: String,
        kind: PaneKind,
        relay_session_id: Option<String>,
        relay_server: Option<String>,
        url: Option<String>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        Self::refuse_second_pane(
            &inner.ledger,
            &kind,
            relay_session_id.as_deref(),
            relay_server.as_deref(),
        )?;
        let position = inner.ledger.next_position(&lane_id)?;
        // A split in a private lane is private: same jar as the pane above it,
        // so the stack is one session and not one sign-in per pane.
        let lane = inner.ledger.lane(&lane_id)?;
        let data_store_id = if lane.is_private {
            lane.panes.first().and_then(|p| p.data_store_id.clone())
        } else {
            None
        };
        let pane = Pane {
            id: new_id(),
            lane_id: lane_id.clone(),
            position,
            kind,
            relay_session_id,
            relay_server,
            url,
            scroll_y: None,
            data_store_id,
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
            mobile: false,
        };
        inner.ledger.insert_pane(&pane)?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane.id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// A session is on the strip once.
    ///
    /// Two panes on one Relay session are the same terminal drawn twice: both
    /// attached, both closing when it exits, neither one anything the shell
    /// wants. The shell looks for the lane first and reveals it; this is the
    /// backstop for a door that forgot to, and it reads the unfiltered ledger
    /// because a gather filter is precisely what made the doors forget. A pty
    /// pane with no session — one whose session could not start — holds nothing
    /// and is not counted.
    ///
    /// Keyed on `(server, id)`: ids are eight hex characters minted per
    /// machine, so the same id on two servers is two sessions (ADR-0020).
    fn refuse_second_pane(
        ledger: &Ledger,
        kind: &PaneKind,
        relay_session_id: Option<&str>,
        relay_server: Option<&str>,
    ) -> Result<()> {
        let (PaneKind::Pty, Some(id)) = (kind, relay_session_id) else { return Ok(()) };
        let holder = ledger.lanes()?.into_iter().find(|l| {
            l.panes.iter().any(|p| {
                p.relay_session_id.as_deref() == Some(id) && p.relay_server.as_deref() == relay_server
            })
        });
        match holder {
            Some(lane) => Err(CoreError::Invalid {
                message: match relay_server {
                    Some(server) => {
                        format!("session {id} on {server} is already on the strip, in lane {}", lane.id)
                    }
                    None => format!("session {id} is already on the strip, in lane {}", lane.id),
                },
            }),
            None => Ok(()),
        }
    }

    /// Snapshot a source history file and read every page out of it.
    ///
    /// The snapshot's lifetime is this function: it is taken, read and deleted
    /// before the pages are handed back, so nothing further up has to remember
    /// to clean up 642 MB of someone's browsing history.
    fn read_source(
        ledger: &Ledger,
        source: &import::HistorySource,
    ) -> Result<(Vec<import::SourcePage>, u32)> {
        if let Some(why) = &source.blocked {
            return Err(CoreError::Invalid { message: why.clone() });
        }
        let snapshot = import::Snapshot::take(std::path::Path::new(&source.path), ledger.path())?;
        let conn = snapshot.open()?;
        import::read_pages(&conn, source.kind)
    }

    /// Another browser's bookmarks, flattened, and how many of them are already
    /// kept here.
    ///
    /// `None` for a source whose bookmarks this crate does not read, which is a
    /// different answer from "none": the wizard prints one as a sentence and
    /// the other as a zero.
    fn read_source_bookmarks(
        ledger: &Ledger,
        source: &import::HistorySource,
    ) -> Result<Option<(Vec<import::FlatBookmark>, u32)>> {
        if source.bookmarks_path.is_none() {
            return Ok(None);
        }
        let tree = import::read_bookmarks(source, ledger.path())?;
        let flat = import::flatten(&tree);
        let here = ledger.bookmark_placements()?;
        let known = flat
            .iter()
            .filter(|b| here.contains(&(b.folder.join("/"), b.url.clone())))
            .count() as u32;
        Ok(Some((flat, known)))
    }

    fn plan(
        ledger: &Ledger,
        pages: &[import::SourcePage],
        skipped: u32,
        known: u32,
        bookmarks: Option<&(Vec<import::FlatBookmark>, u32)>,
        mode: import::ImportMode,
    ) -> Result<import::ImportPlan> {
        let existing = ledger.history_count()?;
        let source_pages = pages.len() as u32;
        let existing_bookmarks = ledger.bookmark_count()?;
        // Folders are counted in `resulting_bookmarks` and not in
        // `source_bookmarks`, which is not an inconsistency: the source number
        // answers "how many pages does Vivaldi keep", and the resulting number
        // is how many rows the tree will draw. A report that quoted folders in
        // the first would be answering a question nobody asked about a bar.
        let new_bookmarks = bookmarks.map(|(flat, known)| flat.len() as u32 - known).unwrap_or(0);
        Ok(import::ImportPlan {
            source_pages,
            skipped,
            already_known: known,
            new_pages: source_pages - known,
            earliest_visit_at: pages.iter().map(|p| p.first_visit_at).min(),
            latest_visit_at: pages.iter().map(|p| p.last_visit_at).max(),
            existing_pages: existing,
            resulting_pages: match mode {
                import::ImportMode::Merge => existing + (source_pages - known),
                import::ImportMode::Replace => source_pages,
            },
            source_bookmarks: bookmarks.map(|(flat, _)| flat.len() as u32),
            bookmarks_already_known: bookmarks.map(|(_, known)| *known).unwrap_or(0),
            existing_bookmarks,
            resulting_bookmarks: match mode {
                import::ImportMode::Merge => existing_bookmarks + new_bookmarks,
                // The folders the import is about to make are not knowable
                // without making them, so this is the floor rather than the
                // count — and it is labelled "at least" in the wizard for that
                // reason. Guessing by counting distinct folder paths would be a
                // number that is right until a source has two folders of the
                // same name in different places.
                import::ImportMode::Replace => new_bookmarks,
            },
        })
    }

    /// Put the ledger aside before `Replace` empties its history.
    ///
    /// Named with the epoch millisecond rather than a date, so a second
    /// `Replace` cannot quietly overwrite the way back from the first — the
    /// wizard prints the whole path, and a file name that is unique matters
    /// more there than a file name that is pretty.
    fn back_up_ledger(ledger: &Ledger) -> Result<Option<String>> {
        let Some(path) = ledger.path() else { return Ok(None) };
        let mut name = path.as_os_str().to_os_string();
        name.push(format!(".pre-import-{}", now_ms()));
        let dest = PathBuf::from(name);
        ledger.backup_to(&dest)?;
        Ok(Some(dest.to_string_lossy().into_owned()))
    }

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

    /// `create_lane` and `create_private_web_lane`, which differ in one flag
    /// and one string. Not exported: uniffi would give the shell a third door.
    #[allow(clippy::too_many_arguments)]
    fn create_lane_impl(
        &self,
        placement: Placement,
        kind: PaneKind,
        relay_session_id: Option<String>,
        relay_server: Option<String>,
        url: Option<String>,
        inherit_tag_from_lane: Option<String>,
        is_private: bool,
        private_store: Option<String>,
    ) -> Result<StripState> {
        let mut inner = self.inner.lock();
        Self::refuse_second_pane(
            &inner.ledger,
            &kind,
            relay_session_id.as_deref(),
            relay_server.as_deref(),
        )?;
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
            is_private,
            panes: Vec::new(),
        };
        let pane = Pane {
            id: new_id(),
            lane_id: lane.id.clone(),
            position: 0,
            kind,
            relay_session_id,
            relay_server,
            url,
            scroll_y: None,
            // A private pane is born knowing its jar, so a sibling can be put
            // in the same one and the shell never has to guess from the lane.
            data_store_id: if is_private {
                Some(private_store.unwrap_or_else(|| format!("private:{}", lane.id)))
            } else {
                None
            },
            snapshot_path: None,
            state: PaneState::Live,
            height_weight: 1.0,
            zoom: 1.0,
            mobile: false,
        };
        inner.ledger.insert_lane(&lane)?;
        inner.ledger.insert_pane(&pane)?;
        inner.ledger.set_app_state(KEY_FOCUSED_PANE, &pane.id)?;
        Self::bump(&mut inner);
        Self::snapshot(&inner)
    }

    /// A JSON array of strings out of `app_state`; anything unreadable is empty.
    fn stored_set(ledger: &Ledger, key: &str) -> Result<BTreeSet<String>> {
        Ok(ledger
            .app_state(key)?
            .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
            .map(|v| v.into_iter().collect())
            .unwrap_or_default())
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
        // The second narrowing, after the first: what is reported as hidden is
        // what a collapse took out of *this* view, so a lane a gather had
        // already left out is not counted twice.
        let mut hidden_lane_ids = Vec::new();
        if !inner.hidden.is_empty() {
            lanes.retain(|l| {
                let hide = l.dock.is_none() && inner.hidden.contains(&l.id);
                if hide {
                    hidden_lane_ids.push(l.id.clone());
                }
                !hide
            });
        }
        let scroll_x = inner.ledger.app_state(KEY_SCROLL_X)?.and_then(|s| s.parse().ok()).unwrap_or(0.0);
        Ok(StripState {
            lanes,
            scroll_x,
            focused_pane_id: inner.ledger.app_state(KEY_FOCUSED_PANE)?,
            gather_filter: inner.gather.clone(),
            hidden_lane_ids,
            revision: inner.revision,
        })
    }
}
