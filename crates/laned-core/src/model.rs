//! Wire types handed to the shell. These are snapshots: the shell never holds a
//! reference into the ledger, only a copy it can diff against the previous one.

/// What a pane renders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PaneKind {
    /// A terminal attached to a RelayTTY session.
    Pty,
    /// A live `WKWebView`.
    Web,
    /// An evicted web pane: snapshot image plus the URL needed to rehydrate.
    Placeholder,
}

/// Where a lane's project tag came from. Determines whether the tagger may
/// overwrite it: `Manual` is sticky, the others are not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProjectSource {
    /// Resolved from the attached session's working directory.
    Cwd,
    /// Copied from the pane that spawned this one.
    Inherited,
    /// Set by the user. Never overwritten by the tagger.
    Manual,
}

/// What a remembered entry launches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecentKind {
    /// A command line, run in a terminal lane.
    Command,
    /// A URL, opened in a web lane.
    Url,
}

/// Something the user launched before, for the new-pane picker.
///
/// The picker's whole value is that the thing you want is usually the thing you
/// ran last, so this is ordered by `last_used_at` and nothing else. `use_count`
/// is carried for display, not for ranking: a frecency score would keep a
/// command you ran fifty times last week above the one you ran a minute ago,
/// which is the opposite of what a strip full of half-finished work needs.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Recent {
    pub kind: RecentKind,
    /// The command line, or the URL.
    pub value: String,
    /// `Command` only: the directory it last ran in.
    pub cwd: Option<String>,
    /// Epoch ms.
    pub last_used_at: i64,
    pub use_count: u32,
}

/// One page in the browsing history — a URL, what it was called, when, and how
/// many times.
///
/// Aggregated per URL by the ledger rather than per navigation, so this is one
/// line in a palette and not one line per time you pressed Return. The
/// addresses that redirected here are deliberately *not* carried: they exist
/// only so that typing what you asked for finds where you landed, they have no
/// titles of their own, and putting a `Vec<String>` on a record that comes back
/// fifty at a time per keystroke would marshal a list nothing renders.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryEntry {
    /// Normalized. The address that was actually on screen, after redirects.
    pub url: String,
    /// `None` for a page that never produced a `<title>`.
    pub title: Option<String>,
    /// Epoch ms. Never moves.
    pub first_visit_at: i64,
    /// Epoch ms.
    pub last_visit_at: i64,
    pub visit_count: u32,
    /// Why this row survived the query, for the palette's row glyph. A match on
    /// a redirect source reports [`SearchField::Url`]: it is a URL in every
    /// sense the reader cares about.
    pub matched_field: SearchField,
    /// Higher is better. Zero, and meaningless, for an empty query.
    pub score: i32,
}

/// Whether the shell should be holding a live view for this pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PaneState {
    Live,
    Evicted,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Pane {
    pub id: String,
    pub lane_id: String,
    /// 0 is the top of the lane's stack.
    pub position: u32,
    pub kind: PaneKind,
    /// `pty` only: the RelayTTY session this pane is attached to.
    pub relay_session_id: Option<String>,
    /// `web`/`placeholder` only: kept current as the user navigates.
    pub url: Option<String>,
    /// `web` only: restored on rehydrate.
    pub scroll_y: Option<f64>,
    /// `web` only: which `WKWebsiteDataStore` shard this pane's cookies live in.
    pub data_store_id: Option<String>,
    /// `placeholder` only: on-disk snapshot rendered while evicted.
    pub snapshot_path: Option<String>,
    pub state: PaneState,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Lane {
    pub id: String,
    /// Fractional. Order is by this value alone; the shell never sorts by anything else.
    pub ordinal: f64,
    pub width_pt: u32,
    pub title: Option<String>,
    /// Git root, when one was resolvable.
    pub project_root: Option<String>,
    pub project_source: ProjectSource,
    /// Epoch milliseconds.
    pub created_at: i64,
    /// Epoch milliseconds. Drives eviction ranking.
    pub last_focus_at: i64,
    /// Pinned lanes are never evicted.
    pub pinned: bool,
    /// How many lane-widths this lane may occupy. 1 almost always.
    ///
    /// PRD §13 Phase 3's escape hatch for "the rare landscape site" — a wide
    /// dashboard or a diff that genuinely cannot be read in portrait. It
    /// multiplies the maximum width for this lane and nothing else, and the
    /// default of 1 is what keeps §1's invariant true everywhere the user has
    /// not deliberately opted out.
    pub span: u32,
    /// Top-to-bottom stack.
    pub panes: Vec<Pane>,
}

/// Everything the shell needs to render one frame of the strip.
///
/// Emitted after every mutation. The shell diffs it against the snapshot it is
/// currently showing and touches only what changed.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StripState {
    /// In ordinal order. Already filtered when a gather filter is active.
    pub lanes: Vec<Lane>,
    /// Horizontal scroll offset in points, restored across launches.
    pub scroll_x: f64,
    pub focused_pane_id: Option<String>,
    /// `Some(project_root)` while a gather view is active. Purely a view filter:
    /// no ordinal is ever written because of it.
    pub gather_filter: Option<String>,
    /// Bumped on every mutation so the shell can cheaply reject stale snapshots.
    pub revision: u64,
}

/// One hit from the search index.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub lane_id: String,
    pub pane_id: String,
    /// The text that matched.
    pub text: String,
    /// Which field the match came from, for the palette's row icon.
    pub field: SearchField,
    /// Higher is better.
    pub score: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchField {
    Title,
    ProjectRoot,
    Url,
    Scrollback,
}

/// Where a newly created lane goes.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Placement {
    /// Immediately right of the given lane. Used by every spawn that has a parent.
    RightOf { lane_id: String },
    /// Immediately left of the given lane.
    LeftOf { lane_id: String },
    /// The far right of the strip. Used for unattributed lanes.
    End,
}
