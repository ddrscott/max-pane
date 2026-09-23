# PRD — Max Pane for macOS

**Status:** Draft 1 · 2026-09-12 — Phase 0 complete, Phases 1–3 built.
See [`docs/decisions/`](decisions/) for the eight ADRs and
[`docs/acceptance.md`](acceptance.md) for where this document and reality
disagree. Amendments below are marked **[AMENDED]** with the ADR that made them.
**Owner:** Scott Pierce
**Audience:** Claude Code (planning + implementation), future-Scott.
**Scope:** A fullscreen macOS app. Nothing in this document concerns Linux, Wayland, or compositors. A separate PRD covers that later; ignore it.

---

## 0. Instructions for the implementing agent

1. Read this whole document before writing code.
2. Run the **Phase 0 spikes** (§12) first. Write results with numbers to `docs/spikes/`. Phase 1 is gated on them.
3. **RelayTTY's PTY host is a stable external dependency.** Do not modify its wire protocol. If the app needs something the protocol doesn't offer, write a proposal in `docs/proposals/` and stop.
4. Everything durable lives in `laned-core` (Rust). The Swift app is a view. If a piece of state would be lost when the app quits, it is in the wrong place.
5. Every phase ends with something Scott can daily-drive. Do not leave the app in a state he can't use for real work.
6. When reality contradicts a requirement, surface the conflict. Do not silently reinterpret.
7. Write ADRs in `docs/decisions/` for every open decision in §14 before implementing the affected component.

---

## 1. What this is

A fullscreen macOS app where **terminals and web views are peer panes** arranged as **portrait-bounded columns ("lanes") on an infinite horizontal strip**. Lanes are organized only by where the user left them and by the directory they were launched from. It is a supervision surface for agentic CLI work: watch several agents run while reading what they cite, in columns, not overlapping windows.

**Design invariant:** *A lane is a portrait-bounded column.* Wide content scrolls inside the lane; the lane never widens past its max.

### Why macOS first
To find out whether Scott will live in this layout for weeks, using only the two pane types that make up ~90% of his work, before investing in anything platform-heavy. The macOS app supports **terminal and web lanes only**; other macOS apps stay on the normal desktop and are reached via Cmd-Tab.

---

## 2. Goals

1. Fullscreen app: horizontal strip of lanes, vertical pane stacks inside lanes.
2. **Terminal panes** attached to existing RelayTTY sessions; **web panes** as embedded WebKit views sharing one process pool.
3. **Organic organization**: new panes appear next to the pane that spawned them; the user reorders freely; the system never reorders.
4. **Directory-keyed identity**: every pane self-tags with a project (git root of cwd) with no user declaration; tags drive search and a temporary "gather" view, never layout.
5. **Search-to-scroll** over titles, project tags, URLs, and recent terminal output.
6. **Persistence**: lane order, pane metadata, and URLs survive app quit, app crash, sleep, and reboot. Terminal content survives because RelayTTY owns it.
7. **Scale**: 150 lanes live, most of them web, on a 32–64 GB Mac, with eviction to placeholders beyond that.
8. A **sidebar** listing lanes in strip order.

## 3. Non-goals

- Hosting other macOS apps' windows as lanes (impossible on macOS; do not attempt via Accessibility hacks).
- Building a terminal emulator or a browser. Use SwiftTerm and WKWebView.
- Remote/mobile streaming. RelayTTY's existing mobile client continues to reach the same terminal sessions; nothing new here.
- Multi-window, multi-display (single fullscreen window on one display for v1).
- Theming beyond a config file. Extensions/plugins.

---

## 4. Definitions

| Term | Meaning |
|---|---|
| **Strip** | Horizontal, ordered sequence of lanes. Scrolls left/right. Infinite to the right. |
| **Lane** | One column. Has an ordinal, width, project tag, and 1..N panes stacked vertically. |
| **Pane** | One terminal or one web view. |
| **Kind** | `pty` · `web` · `placeholder` (evicted web pane: snapshot + URL). |
| **Project tag** | Git root of the pane's cwd (pty) or inherited from the spawning pane (web). |
| **Ledger** | SQLite database in `laned-core`. Source of truth for layout and pane metadata. |
| **Gather** | Temporary view showing all lanes with a given tag adjacent. Never writes ordinals. |

---

## 5. Architecture

```
┌────────────────────────────────────────────────┐
│  MaxPane.app  (Swift / AppKit)                 │
│  StripView · LaneView · PaneView · Sidebar     │
│  SearchPalette · PlaceholderView               │
└───────────────┬────────────────────────────────┘
                │ C FFI (uniffi)
┌───────────────▼────────────────────────────────┐
│  laned-core  (Rust crate, platform-agnostic)   │
│  Ledger (SQLite) · ordinals · project tagging   │
│  search index · eviction policy · spawn rules  │
└───────┬───────────────────────────┬────────────┘
        │                           │
┌───────▼──────────┐       ┌────────▼──────────┐
│ RelayTTY PTY host│       │ WebKit process    │
│ (existing)       │       │ pool (in-app)     │
└──────────────────┘       └───────────────────┘
```

### 5.1 `laned-core` (Rust)
- Owns the ledger, all mutation, search, tagging, eviction decisions.
- No platform code. No UI. Exposed via `uniffi` to Swift.
- Emits a single observable `StripState` snapshot after every mutation; Swift diff-renders it.
- Designed to be reused unchanged by a future non-macOS shell. Do not leak AppKit concepts into it.

### 5.2 `MaxPane.app` (Swift/AppKit)
- Owns exactly: rendering, input, `WKWebView`/SwiftTerm lifecycle, snapshots, scroll position.
- Owns **no** durable state. On launch it calls `laned_core.load()` and renders whatever it gets.
- Fullscreen `NSWindow` (`.fullScreen` collection behavior). Menu bar auto-hides.
  **[AMENDED — [ADR-0036](decisions/0036-the-window-comes-back-where-you-left-it.md)]**
  Fullscreen on the first launch; after that, the window comes back the way it
  was left — fullscreen, or its frame on its display, remembered in the ledger's
  `app_state` and clamped onto a screen that still exists.

### 5.3 Process lifecycle
- App crash → relaunch → strip identical, terminals reattach to Relay, web panes reload from URL.
- `laned-core` runs in-process (it's a library). Durability comes from synchronous SQLite writes, not from a separate daemon.

---

## 6. Data model (ledger)

SQLite, WAL mode, `~/Library/Application Support/MaxPane/ledger.db`. **Every layout mutation is committed before the UI animates it.**

```sql
CREATE TABLE lane (
  id TEXT PRIMARY KEY,           -- ulid
  ordinal REAL NOT NULL,         -- fractional; insert = midpoint; renormalize when gap < 1e-6
  width_pt INTEGER NOT NULL,     -- clamped to [LANE_MIN, LANE_MAX]
  title TEXT,
  project_root TEXT,
  project_source TEXT NOT NULL,  -- 'cwd' | 'inherited' | 'manual'
  created_at INTEGER NOT NULL,
  last_focus_at INTEGER NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX lane_ordinal ON lane(ordinal);

CREATE TABLE pane (
  id TEXT PRIMARY KEY,
  lane_id TEXT NOT NULL REFERENCES lane(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,     -- 0 = top
  kind TEXT NOT NULL,            -- 'pty' | 'web' | 'placeholder'
  relay_session_id TEXT,         -- pty
  url TEXT,                      -- web; kept current on navigation
  scroll_y REAL,                 -- web; restored on rehydrate
  data_store_id TEXT,            -- web; which WKWebsiteDataStore ("shard")
  snapshot_path TEXT,            -- placeholder
  state TEXT NOT NULL            -- 'live' | 'evicted'
);
CREATE INDEX pane_lane ON pane(lane_id, position);

CREATE TABLE pairing (           -- explicit terminal<->web link (optional)
  pty_pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
  web_pane_id TEXT NOT NULL REFERENCES pane(id) ON DELETE CASCADE,
  PRIMARY KEY (pty_pane_id, web_pane_id)
);

CREATE TABLE app_state (
  key TEXT PRIMARY KEY,          -- 'strip_scroll_x', 'focused_pane_id', ...
  value TEXT NOT NULL
);
```

Versioned migrations in `laned-core/migrations/`. Never edit a shipped migration.

---

## 7. Lane and pane semantics

### 7.1 Creation
| Action | Result |
|---|---|
| New terminal (⌘T) | New lane immediately right of the focused lane; pty pane attached to a **new** Relay session started in the focused pane's cwd; tag inherited then refreshed from cwd. |
| New web pane (⌘L, then URL) | New lane immediately right of focused lane; tag inherited. |
| Split down (⌘D) | New pane appended to the focused lane's stack (same kind as focused, or prompt). |
| Open URL from a terminal | Terminal panes run with a custom `BROWSER`/`open` shim that posts to the app; the URL becomes a web pane right of that terminal, tagged with the terminal's project. |
| Attach existing Relay session | Picker lists Relay sessions not currently attached; attaching creates a lane at the end of the strip. |

### 7.2 Ordering
- Ordinal persisted on every move, synchronously.
- User reorders by drag or ⌘⇧←/→. System never reorders.
- Unattributed new lanes append at the end.

### 7.3 Project tagging
- **pty:** poll the foreground process cwd of the attached Relay session every 5 s. On macOS, resolve via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on the local pid if the session is local; if the session is remote, use whatever cwd Relay already reports (observation only; do not extend the protocol). Resolve to git root (`git rev-parse --show-toplevel`, cached).
  **[AMENDED — [ADR-0005](decisions/0005-cwd-for-relay-sessions.md)]** RelayTTY's
  pty-host **already runs exactly this poll**, on the same syscall and cadence,
  and writes the answer to the session file — so MaxPane observes rather than
  duplicating it, and remote sessions get the same answer. It also does not strip
  **OSC 7** from the output stream, which gives a sub-second path three orders of
  magnitude fresher than the 5 s file.
- **web:** inherit from spawning pane. `project_source='inherited'`.
- **manual:** user override via sidebar; sticky.
- Tag never moves a lane.

### 7.4 Gather view
⌘G on a project → strip renders only that project's lanes, in true ordinal order, contiguous. Esc restores. Read-only over the ledger; implemented as a filter in `StripState`, never a mutation.

### 7.5 Search (⌘P)
- Fuzzy over `lane.title`, `project_root`, `pane.url`, and the last 200 lines of each pty pane's scrollback (fetched lazily from SwiftTerm's buffer, not from Relay).
- Select → focus pane, animate strip so its lane is centered, flash the lane border 300 ms.
- Index maintained in `laned-core`; scrollback contributions pushed from Swift on a debounce.

### 7.6 Sidebar
- Left-edge `NSOutlineView`, toggle ⌘B. Lists lanes in ordinal order: kind glyph, title, project tag, live/evicted state, pinned marker.
- Click → search-to-scroll. Right-click → pin/unpin, set manual tag, close.
- Past 50 lanes, sidebar may **visually** group by project tag. The strip never does.

---

## 8. Layout rules

- `LANE_MIN = 420pt`, `LANE_MAX = 900pt` (configurable). Lanes can be resized by dragging their right edge within these bounds. Wide content scrolls inside the lane.
- Web panes get a viewport width equal to their lane width so sites reflow to portrait layout natively.
- **Nesting depth is 1**: lanes contain panes; panes do not contain lanes. No tree layout.
- Opening a lane never resizes neighbors.
- Strip scroll position and focused pane persist in `app_state`.
- Keyboard-first: every action has a shortcut; the mouse is optional.

---

## 9. Web panes

- ~~One `WKProcessPool` for the whole app (WebKit does process-per-site under it).~~
  **[AMENDED — [ADR-0003](decisions/0003-website-data-store-sharding.md)]** Both
  halves are untrue on macOS 26. `WKProcessPool` has been a deprecated no-op
  since macOS 12, and spike M1 measured **one `WebContent` process per
  `WKWebView`** with no site coalescing — 100 views across 20 origins gave 100
  processes. The model is *one web pane, one OS process*, ≈27 MB for a light page
  and ≈95 MB for a real site.
- A small fixed number of `WKWebsiteDataStore`s (default 3), assigned by project root so a project's panes share cookies/logins. Assignment recorded in `pane.data_store_id`.
- Track navigation (`WKNavigationDelegate`) to keep `pane.url` and title current.
- `WKUIDelegate` popups/new-window requests → new web pane right of the requesting pane.
- User agent: default desktop. Do not spoof mobile; portrait-width desktop reflow is the point.

---

## 10. Scale, memory, eviction

### 10.1 Targets
| Metric | Target |
|---|---|
| Live lanes | 150 (≈20 pty / 130 web) on a 32 GB Mac before eviction engages |
| Idle CPU, nothing focused | < 2% of one core |
| App relaunch to interactive strip | < 3 s (web panes load lazily) |
| Sleep/wake | all panes intact; no reloads |

### 10.2 Off-screen behavior
- Web panes more than `RELEASE_DISTANCE` (default 6) lanes off-screen are **removed from the view hierarchy** but kept alive. Re-parent on scroll-in.
  **[AMENDED — [ADR-0003](decisions/0003-website-data-store-sharding.md)]** This
  is a CPU strategy, **not a memory strategy**. M1 measured unparenting at
  **3.5 MB per pane** regardless of page weight, against **24.7–90.8 MB** for
  eviction. On a real site, unparenting buys 4% of what eviction buys.
- pty panes stay parented; SwiftTerm is cheap.

### 10.3 Eviction
- Policy in `laned-core`, inputs: process-pool memory (via `task_info`/`proc_pid_rusage` of WebKit content processes), distance from viewport, `last_focus_at`, `pinned`.
  **[AMENDED — [ADR-0003](decisions/0003-website-data-store-sharding.md)]** The
  budget is a **fraction of physical RAM**, not a pane count, because per-pane
  cost varies 3.4× by page type: soft 0.25×, hard 0.35×, evict down to 0.20×. It
  also has **hysteresis** — three consecutive over-budget samples and a 120 s
  cooldown — because M1 watched the same 100 panes measure 5 275 MB and then
  2 274 MB three and a half minutes later with nobody touching anything.
- Evict = `takeSnapshot` → record `url`, `scroll_y` → destroy `WKWebView` → `state='evicted'`. Lane renders the snapshot dimmed with a kind glyph.
- Rehydrate on focus, on scroll within `REHYDRATE_DISTANCE` (default 2), or on search selection.
- Pinned panes are never evicted. pty panes are never evicted.
- Lazy load on app launch: only panes within the viewport ±2 lanes are instantiated; the rest render as placeholders until scrolled to.

---

## 11. Terminal panes

- SwiftTerm view attached to a RelayTTY session via Relay's existing client library/protocol.
- ~~Resize → propagate to Relay; verify cell-accurate reflow.~~
  **[AMENDED — [ADR-0007](decisions/0007-terminal-panes-never-resize-the-pty.md)]**
  RelayTTY's PTY resize is **global last-writer-wins**, so a narrow lane
  propagating its size reshapes the terminal for every other client — M2 measured
  **6 671 bytes of forced redraw** on every attached client per flip for `htop`.
  MaxPane **never sends `RESIZE`** and **sizes the lane to the session** instead.
  One explicit "claim this session" command is the only path that resizes a PTY.
- Local scrollback from SwiftTerm's buffer for search; Relay remains the source of truth for the session.
- If Relay is unreachable at launch, pty panes render a "reconnecting" state and retry with backoff; the lane and ordinal are unaffected.

---

## 12. Phase 0 — Spikes (gating)

One evening each; report in `docs/spikes/NN-name.md` with measured numbers.

| # | Question | Pass criterion |
|---|---|---|
| M1 | 100 `WKWebView`s in one process pool, 5 parented, 95 unparented: RSS, idle CPU, scroll smoothness when re-parenting | numbers recorded; re-parent < 100 ms; idle CPU < 2% |
| M2 | SwiftTerm ↔ Relay attach: latency, resize correctness, 30 concurrent sessions | usable; no protocol changes needed |
| M3 | `laned-core` via uniffi: `StripState` round-trip at 300 lanes / 400 panes | < 5 ms |
| M4 | Fullscreen `NSWindow` + horizontal `NSScrollView` with 150 lane views: scroll at 120 Hz, no layout thrash | measured; lane views virtualized if needed — **120 Hz unverifiable on this hardware, see [ADR-0004](decisions/0004-strip-view-strategy.md)** |
| M5 | Sleep/wake with 100 web panes + 20 terminals | nothing reloads; Relay sessions reattached |

If M1 fails on memory, revisit §10.3 thresholds and the data-store count before Phase 1.

---

## 13. Phases

### Phase 1 — Live in it
- `laned-core` with ledger, ordinals, spawn adjacency, cwd tagging, search index.
- App: strip, lanes, pty + web panes, sidebar, search-to-scroll, drag reorder, keyboard shortcuts.
- Persistence: quit/relaunch and `kill -9` restore the strip exactly.
- Off-screen unparenting; lazy launch.
**Exit:** Scott uses it as primary environment for two weeks. Record which §7/§8 decisions changed; update this PRD.

### Phase 2 — Scale and polish
- Eviction/rehydration with snapshots.
- Gather view. Pairing UI. Manual tags.
- Multiple data stores by project.
- Memory dashboard (per-lane cost, evicted count).
**Exit:** 150 lanes for one week within targets.

### Phase 3 — Nice-to-haves (only if Phase 2 holds)
- Multi-display (one strip per display).
- Lane spanning (2× width) for the rare landscape site.
- Export/import of a strip (JSON) for machine migration.

---

## 14. Open decisions — **all closed**

Every one has an ADR in [`docs/decisions/`](decisions/), and every ADR names the
measurement that decided it.

| Decision | Answer | ADR | Decided by |
|---|---|---|---|
| SwiftTerm vs. Relay's web client in a `WKWebView` | **SwiftTerm** | [0001](decisions/0001-swiftterm-over-web-terminal.md) | M2 — 1.17 MB a pane vs ≥27 MB, and three better reasons than memory |
| uniffi vs. cbindgen | **uniffi**, plus snapshot-free hot paths | [0002](decisions/0002-uniffi-over-cbindgen.md) | M3 — 2.4 ms round-trip, 88% of it the boundary |
| 3 vs. N `WKWebsiteDataStore`s | **3**, hashed by project root | [0003](decisions/0003-website-data-store-sharding.md) | M1 — store count influenced nothing measurable |
| Virtualized strip vs. manual recycling | **`NSScrollView` + manual recycling** | [0004](decisions/0004-strip-view-strategy.md) | M4 — 0.00% vs 16.16% dropped frames; ties `NSCollectionView`, fights the app less |
| cwd for remote Relay sessions | **Observe pty-host**, OSC 7 first | [0005](decisions/0005-cwd-for-relay-sessions.md) | The pty-host source — it already does the poll §7.3 describes |
| Placeholder snapshot format | **JPEG at 1× lane width** | [0006](decisions/0006-placeholder-snapshots.md) | Measured — HEIC costs 22× the encode time to save disk nobody needs |

Two decisions were added that §14 did not anticipate:

| Decision | ADR | Why it exists |
|---|---|---|
| Terminal panes never resize the PTY | [0007](decisions/0007-terminal-panes-never-resize-the-pty.md) | §11 contradicts RelayTTY's global last-writer-wins resize |
| Multi-display is not built | [0008](decisions/0008-no-multi-display-yet.md) | Phase 3 is gated on Phase 2 holding, and that gate is a week of real use |

---

## 15. Acceptance tests

1. Create 20 lanes, reorder randomly, `kill -9` the app → order identical on relaunch.
2. In a pty pane in `~/src/foo`, run `open https://example.com` → web pane appears immediately right, tagged `foo`.
3. `cd ~/src/bar` in a pty pane → tag updates within 10 s; lane does not move.
4. Sleep, wake → no web pane reloads; terminals reattached; scroll position unchanged.
5. 150 lanes → idle CPU < 2%; RSS within target; scrolling stays smooth.
6. Evict a lane, then ⌘P search its URL → lane rehydrates, strip scrolls to it, border flashes.
7. ⌘G on a project shows only its lanes contiguous; Esc restores exact previous strip.
8. Quit with Relay host down → relaunch shows all lanes; pty panes show "reconnecting"; ordinals intact.

---

## 16. Risks

| Risk | Mitigation |
|---|---|
| WebKit content-process memory at 100+ panes | Unparent off-screen; evict beyond threshold; measure in M1 before building |
| SwiftTerm/Relay resize or scrollback mismatch | M2 before Phase 1; Relay remains source of truth |
| Search over scrollback becomes slow | Cap at 200 lines/pane; debounce; index in Rust |
| Scope creep toward a browser | §3: no tabs, no bookmarks, no extensions. A pane is a URL. |
| Scott can't reach native apps comfortably from fullscreen | Cmd-Tab and a "peek desktop" shortcut (exit fullscreen momentarily). Accept this as the v1 boundary. |

---

## 17. Definition of done (v1)

**Still open, and only Scott can close it.** Everything §13 lists is built and
tested; what remains is the part that is a fact about living in it rather than a
fact about the code. Phase 1's exit is two weeks as the primary environment;
Phase 2's is 150 lanes for one week within targets. Neither can be established by
building more.

Two measurements should be taken before that fortnight starts, both blocked on
things a running spike could not reach:

- **M1b — the process-count ceiling.** 130 web panes means ≥130 `WebContent`
  processes, and nothing has found where macOS or WebKit pushes back. Every
  threshold in §10.3 is irrelevant if the failure mode is "WebKit declines to
  spawn process 137" rather than "memory got tight".
- **M1 and M4, re-run unlocked.** Both ran with the screen locked, so macOS
  occluded the windows. M1's memory figures are a floor, and its central
  question — whether unparenting actually suspends rendering — is unanswered.
  `spikes/m1-webkit-memory/run_when_unlocked.sh` closes it in one command.

---

Scott lives in it for two weeks. Terminals and web views side by side in portrait columns, organized only by where he left them. When the app crashes, he loses pixels and nothing else. The Linux question can wait until this answer is in.
