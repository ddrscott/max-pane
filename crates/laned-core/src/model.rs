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

/// A capability a page can ask a person for, and be remembered about.
///
/// One variant per thing WebKit asks separately. `getUserMedia({audio, video})`
/// arrives as one callback naming both, and it is stored as two rows on
/// purpose: "yes to the microphone, no to the camera" is a real answer, and a
/// combined `CameraAndMicrophone` row could not express it — nor could it
/// answer a later audio-only call without asking again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SiteFeature {
    Camera,
    Microphone,
    /// The Notification API. WebKit does not implement it on macOS, so the
    /// shell does, and this is the answer to its `requestPermission()`.
    Notifications,
    /// `navigator.geolocation`. WebKit on macOS has no public way to grant it,
    /// so the shell answers the page itself; this is the per-site yes or no
    /// that comes before CoreLocation is ever asked.
    Geolocation,
}

/// One remembered answer, for the listing a pane embeds into its page so
/// `Notification.permission` can be read synchronously before the page runs.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SiteGrant {
    pub origin: String,
    pub allowed: bool,
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

/// One pane's new share of its lane's height.
///
/// Its own record rather than two parallel `Vec`s across the FFI: a pane id and
/// a weight that disagree in length is a silent mis-assignment, and the one
/// caller is a mouse drag that must never put the top pane's height on the
/// bottom one.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PaneHeight {
    pub pane_id: String,
    /// Relative to the pane's siblings. Finite and > 0.
    pub weight: f64,
}

/// One pane's zoom, as part of a lane size preset. A record for the same reason
/// `PaneHeight` is one: a pane id and a zoom that could fall out of step across
/// the FFI is a terminal at the wrong font size.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PaneZoomSetting {
    pub pane_id: String,
    /// 1.0 is actual size. Finite and > 0.
    pub zoom: f64,
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
    /// `pty` only: which relay-tty server that session lives on. `None` is
    /// this Mac — the socket under `~/.relay-tty`, as before this field
    /// existed; a name is one of the shell's configured remote servers. A
    /// session is identified by the pair, never by the id alone (ADR-0020).
    pub relay_server: Option<String>,
    /// `web`/`placeholder` only: kept current as the user navigates.
    pub url: Option<String>,
    /// `web` only: restored on rehydrate.
    pub scroll_y: Option<f64>,
    /// `web` only: which `WKWebsiteDataStore` shard this pane's cookies live in.
    pub data_store_id: Option<String>,
    /// `placeholder` only: on-disk snapshot rendered while evicted.
    pub snapshot_path: Option<String>,
    pub state: PaneState,
    /// This pane's share of its lane's height, relative to its siblings.
    ///
    /// A weight and not a point height: the lane is as tall as the window, and
    /// the window changes. Only the ratio between siblings is ever read, so
    /// nothing normalizes these — 1 everywhere is the equal split that was the
    /// only thing a lane could do before this existed.
    pub height_weight: f64,
    /// How far the pane's contents are scaled; 1.0 is actual size. A terminal
    /// reads it as a font size and a page as a page zoom.
    pub zoom: f64,
    /// `web` only: ask sites for the layout an iPhone would get, because a
    /// portrait lane is a phone's shape. The shell sends a mobile user agent
    /// and WebKit's mobile content mode; a terminal ignores it.
    pub mobile: bool,
}

/// Which edge of the window a docked lane holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DockSide {
    Left,
    Right,
}

/// What a docked lane does to the strip beside it. The owner asked for both:
/// *"another option should allow the pinned pane to hover over the strip, or
/// reduce the space of the strip."*
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DockMode {
    /// The dock floats above the strip. The strip keeps the whole window's
    /// width, so nothing about its arithmetic changes — and the lane beneath
    /// the dock is *occluded*, which is the one thing the edge-peek work exists
    /// to prevent. The shell owes the reader some other evidence that the strip
    /// continues under there; see `docs/work/docked-panes-contract.md`.
    Overlay,
    /// The dock takes its width out of the strip's viewport. Nothing is ever
    /// hidden, at the price of every viewport computation in the shell having
    /// to agree about what the viewport now is.
    Inset,
}

/// Where a docked lane sits, and how wide.
///
/// `Option<Dock>` on the lane rather than a `docked: bool` beside three fields:
/// "docked with no side" is a lane the layout cannot place, and the cheapest
/// way to never handle that case is to make it unrepresentable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Dock {
    pub side: DockSide,
    pub mode: DockMode,
    /// Points. Bounded by `DOCK_MIN_PT`/`DOCK_MAX_PT`, which are not the lane
    /// bounds — a dock is not a reading column.
    pub width_pt: u32,
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
    /// Never destroy this lane's web panes to reclaim memory.
    ///
    /// This is the flag that used to be called `pinned`, before the owner said
    /// plainly that pinning means docking. It kept its meaning and its key
    /// (⇧⌘P) and lost only the word; ADR-0010 is why it was not
    /// simply folded into `dock` instead.
    pub keep_live: bool,
    /// `Some` while this lane is held at an edge of the window instead of
    /// scrolling with the strip. Every pane in the lane is docked with it — the
    /// unit is the lane, which the owner settled directly: *"when a lane is
    /// docked all its panes are inherently docked with it."*
    ///
    /// A docked lane keeps its `ordinal` and stays in `StripState.lanes`, so
    /// undocking returns it to the same place in the order it left. It is *not*
    /// laid out by the strip; the shell filters on this field. See the contract.
    pub dock: Option<Dock>,
    /// How many lane-widths this lane may occupy. 1 almost always.
    ///
    /// PRD §13 Phase 3's escape hatch for "the rare landscape site" — a wide
    /// dashboard or a diff that genuinely cannot be read in portrait. It
    /// multiplies the maximum width for this lane and nothing else, and the
    /// default of 1 is what keeps §1's invariant true everywhere the user has
    /// not deliberately opted out.
    pub span: u32,
    /// A lane whose pages live in a cookie jar that is never written to disk,
    /// and whose visits, titles and session are never recorded. The row is
    /// deleted at the next `Core::open`, so a relaunch never brings it back.
    /// Defaults to `false` on both sides of the FFI: nothing that builds a
    /// `Lane` by hand has to know the flag exists.
    #[uniffi(default = false)]
    pub is_private: bool,
    /// Top-to-bottom stack.
    pub panes: Vec<Pane>,
}

/// Everything the shell needs to render one frame of the strip.
///
/// Which of the two layouts the window is showing.
///
/// Sticky, not a temporary view: whichever one was up comes back after a quit
/// and after a `kill -9`, which is why it is a key in `app_state` rather than
/// something the shell remembers. Neither layout owns anything else — the
/// gallery is a view over the same ordinals the strip lays out, so switching
/// between them writes this and nothing more.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StripLayout {
    /// The strip: lanes side by side, scrolling.
    Lanes,
    /// Every lane on one screen at once, each drawn as a live thumbnail.
    Gallery,
}

impl StripLayout {
    /// How it is spelled in `app_state`.
    pub fn as_str(self) -> &'static str {
        match self {
            StripLayout::Lanes => "lanes",
            StripLayout::Gallery => "gallery",
        }
    }

    /// Anything that is not a layout this build knows reads as the strip. A
    /// ledger written by a newer build that grew a third layout should open on
    /// something that works, not refuse to open.
    pub fn parse(stored: &str) -> Self {
        match stored {
            "gallery" => StripLayout::Gallery,
            _ => StripLayout::Lanes,
        }
    }
}

/// Emitted after every mutation. The shell diffs it against the snapshot it is
/// currently showing and touches only what changed.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StripState {
    /// In ordinal order, **docked lanes included**. Already filtered when a
    /// gather filter is active.
    ///
    /// Docked lanes stay in this list rather than being split into one of their
    /// own, because everything that is not the strip's layout — ⌘P, gather,
    /// the sidebar, `maxpane ls`, export — wants them. A lane drawn twice
    /// because a view forgot to filter is a bug you see the instant it happens;
    /// a lane missing from search because a list forgot to union is a hole
    /// nobody notices. The strip's layout is the one consumer that must skip
    /// them, and it is the one consumer that is told to, loudly.
    pub lanes: Vec<Lane>,
    /// Horizontal scroll offset in points, restored across launches.
    pub scroll_x: f64,
    pub focused_pane_id: Option<String>,
    /// `Some(project_root)` while a gather view is active. Purely a view filter:
    /// no ordinal is ever written because of it.
    pub gather_filter: Option<String>,
    /// The lanes a collapsed sidebar group has taken out of `lanes`, in
    /// ordinal order (ADR-0024). Empty nearly always. They are in the ledger,
    /// running and unchanged; they are only not drawn.
    pub hidden_lane_ids: Vec<String>,
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

/// One node of the bookmarks tree — a kept page, or a folder of them.
///
/// Flat, in tree order, with the depth already worked out. The tempting shape
/// is a nested record with `children: Vec<Bookmark>`, and it is the wrong one
/// here for two reasons. uniffi has no recursive records, so the nesting would
/// have to be hand-rolled either side of the FFI; and the one consumer is an
/// `NSTableView` — the sidebar is a flat list by construction (see
/// `SidebarModel.Row`) — which would immediately flatten it back, sorting the
/// tree a second time in Swift to do it. The ledger already has to walk the
/// tree to order it, so it walks it once and says how deep each row was.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Bookmark {
    pub id: String,
    /// `None` for a row on the bar itself. The bar has no row of its own.
    pub parent_id: Option<String>,
    pub is_folder: bool,
    /// Normalized, and `None` exactly when `is_folder`.
    pub url: Option<String>,
    /// Never empty: a page with no `<title>` is kept under its address.
    pub title: String,
    /// Among its siblings.
    pub position: u32,
    pub added_at: i64,
    /// 0 on the bar, 1 inside a folder, and so on. Derived when the tree is
    /// read rather than stored, because it is a fact about the row's ancestry
    /// and a stored copy is one a move would have to rewrite for every
    /// descendant.
    pub depth: u32,
}

/// A bookmark that matched what was typed, for the one door.
///
/// Carries the folder it is in rather than only its parent's id: the row it
/// becomes has to say *which* `notes` this is, and a picker that had to resolve
/// eight parent ids per keystroke to render eight rows would be doing the tree
/// walk the ledger just did.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BookmarkHit {
    pub bookmark: Bookmark,
    /// `Documentation/Rust`, or `None` on the bar.
    pub folder_path: Option<String>,
    /// Why it survived the query, for the row glyph.
    pub matched_field: SearchField,
    /// Higher is better.
    pub score: i32,
}
