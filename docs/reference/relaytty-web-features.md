# RelayTTY web client — functional inventory

Complete inventory of what the RelayTTY **web client** gives a user supervising many
terminal sessions at once. Written as the capability bar Max Pane must clear.

**Source of truth.** `/Users/spierce/code/relay-tty`, working tree at
`v1.21.0-64-ge8abfe4` — i.e. **64 commits past the v1.21.0 tag**. `package.json` still
says `1.21.0`, so the version string in the UI footer is misleading. A large share of the
capabilities below live in the `[Unreleased]` block of `CHANGELOG.md` and are tagged
**(post-1.21.0)** here. Citations are `path:line`, relative to the RelayTTY root.

**Companion document.** [`relay-integration.md`](relay-integration.md) covers the wire
protocol. This document covers the *product*: what a user can do and how it is triggered.

**Confidence.** Everything below was read in source. Claims that exist only in RelayTTY's
own docs and could not be found in code are marked **UNVERIFIED** and listed in §1.14.

---

## 1. Capability inventory

### 1.1 Routes and application shell

`app/routes.ts:3-14` registers exactly ten routes. There is no route-level code splitting
beyond React Router's own.

| URL | File | What it is |
|---|---|---|
| `/` | `app/routes/home.tsx` | Desktop: a single phone-frame live preview. Mobile: auto-redirects to a session. |
| `/activity` | `app/routes/activity.tsx` | Agent dashboard — one card per running session. |
| `/grid` | `app/routes/grid.tsx` | Gallery of natural-size live thumbnails, auto-packed. |
| `/lanes` | `app/routes/lanes.tsx` | Gallery of uniform W×H cells, centred. |
| `/tiles` | `app/routes/tiles.tsx` | iTerm-style workspace of **fully interactive** panes. (post-1.21.0 refinements) |
| `/desktop` | `app/routes/desktop.tsx` | VNC bridge to the host's screen. **(post-1.21.0)** |
| `/settings` | `app/routes/settings.tsx` | Five settings cards. |
| `/sessions/:id` | `app/routes/sessions.$id.tsx` | Single-session view. The biggest file in the app. |
| `/share/:token` | `app/routes/share.$token.tsx` | Read-only share viewer. Bypasses the sidebar. |
| `/pair` | `app/routes/pair.tsx` | Guest enters a 6-digit code. **(post-1.21.0)** |

**Shell.** `app/root.tsx:79-83` wraps every route except `/share/*` in `SidebarDrawer`.
The root loader (`app/root.tsx:30-34`) returns `sessions` (with `includeExited: true`),
`version`, `hostname`, `customCommands`, `desktopAvailable`. Live invalidation is
`useSessionEvents(revalidate)` (`app/root.tsx:73`).

**Dead code — do not port.** `app/routes/auth.callback.tsx` and `app/routes/auth.logout.tsx`
exist but are **not registered** in `app/routes.ts`; the live handlers are Express
(`server.js:96`, `server.js:113`). `app/components/session-card.tsx` has no importers.

**Layout switcher** (`app/components/layout-switcher.tsx:4-13`): six icon buttons —
List/Home, Activity, LayoutGrid/Grid, Columns/Lanes, PanelsTopLeft/Tiles, and
Monitor/Desktop (appended only when `desktopAvailable`). Click navigates. **No keyboard
shortcut switches layouts.** Wrapped in `hidden lg:block` everywhere — desktop only,
`lg` = 1024px.

---

### 1.2 Session list / sidebar

This is the left third of Scott's screenshot and the single most-used surface.

#### 1.2.1 Shell mechanics

| Capability | Behaviour | Trigger | Cite |
|---|---|---|---|
| Drawer | DaisyUI `drawer`; mobile open/close toggles `#sidebar-drawer` checkbox; auto-closes on route change | tap overlay / navigate | `app/components/sidebar-drawer.tsx:407-417`, `:401-404` |
| Collapse (desktop) | Flips `sidebarCollapsed`, persists `relay-tty-sidebar-collapsed`, dispatches `relay-sidebar-toggle` so the in-window sidebar re-reads | `X` in sidebar header, or the hamburger in every route toolbar | `app/lib/sidebar-toggle.ts:10-21`, `app/components/sidebar-drawer.tsx:203-218` |
| Resize | Drag handle `w-1.5` on the right edge. Min **200**, max **600**, default **288**. Live drag writes `--sidebar-w` straight to the DOM (no React re-render per pixel); commits to state + storage on mouseup. **Mouse only — no touch handler.** | drag | `app/components/sidebar-drawer.tsx:221-270`, `app/app.css:120-125` |
| Redundancy suppression | `.sidebar-redundant` is `display:none` when `[data-sidebar="open"]` ≥1024px, hiding the duplicate hostname in route toolbars | automatic | `app/app.css:113-118` |

**No keyboard shortcut collapses the sidebar.**

#### 1.2.2 Grouping

Grouped by exact `session.cwd` string (`app/lib/session-groups.ts:59-66`). Sessions are
sorted **first**, then bucketed, so within-group order is the sort order. Group label is
`displayPath(cwd)` = `cwd.replace(/^\/Users\/[^/]+/, "~")` (`:14-16`). Groups are ordered
**alphabetically by displayed label** (`:74`) — *not* by recency. When there is exactly one
group, headers are suppressed entirely (`app/components/sidebar-drawer.tsx:298`).

Group header (`app/components/sidebar-drawer.tsx:672-687`): a sticky `<button>` containing
a `▶` glyph (`rotate-90` when expanded), the `~`-shortened path, and
`"{runningCount} running"` — rendered only when the count is > 0. Click anywhere toggles.

**Collapse state is NOT persisted** — it is an in-memory `Set<string>` that resets on every
remount (`app/components/sidebar-drawer.tsx:163`). Collapse/expand-all button appears only
when there is more than one group (`:500-512`).

#### 1.2.3 Sort — exact comparators

Four modes, shown in a dropdown only when `sessions.length > 1`
(`app/components/sidebar-drawer.tsx:570`). Clicking the **active** key flips direction;
clicking a **new** key sets it and resets direction to `desc` (`:351-362`). Keys
`relay-tty-sort` (default `"recent"`) and `relay-tty-sort-dir` (default `"desc"`), shared
with `/grid` and `/lanes`; `/tiles` has its own pair.

`flip = dir === "asc" ? -1 : 1`. Source: `app/lib/session-groups.ts:33-56`.

| Key | Comparator | Tie-break |
|---|---|---|
| `recent` | `(bTime - aTime) * flip` where `time = lastActiveAt ? Date.parse(lastActiveAt) : lastActivity` | `tieBreak` |
| `created` | `(b.createdAt - a.createdAt) * flip` | `a.id.localeCompare(b.id)` only |
| `active` | 1. running before exited: `(a.status === "running" ? -1 : 1) * flip`  2. `agentStateRank(a) - agentStateRank(b)`, times `flip`  3. `((b.bytesPerSecond ?? 0) - (a.bytesPerSecond ?? 0)) * flip` | `tieBreak` |
| `name` | `nameKey(a).localeCompare(nameKey(b)) * flip` | `tieBreak` |

```ts
// app/lib/session-groups.ts:21-24 — leading non-alphanumerics stripped because AI tools
// animate a spinner glyph (⠋⠙⠹…/✳) at the start of the title; a volatile prefix would
// reorder rows on every frame.
nameKey(s) = (s.title || `${s.command} ${s.args.join(" ")}`)
               .toLowerCase().replace(/^[^\p{L}\p{N}]+/u, "")

// :28-30 — total order, so ties don't shift as the server list revalidates.
tieBreak(a, b) = b.createdAt - a.createdAt || a.id.localeCompare(b.id)
```

`agentStateRank` (`shared/client/agent-state.ts:11-19`): `blocked 0, working 1, done 2,
idle 3, everything else 4`. **This is what puts blocked agents at the top of the list.**

**Bug to not copy:** `active` sort reads the legacy `bytesPerSecond` while every row
*display* reads `bps1 ?? bytesPerSecond` (`app/components/sidebar-drawer.tsx:88`). A session
reporting only `bps1` sorts as zero throughput.

#### 1.2.4 Filters

| Filter | Where | Storage | Default | Cite |
|---|---|---|---|---|
| Running / Closed toggles | Sidebar `Filter` button → menu with two `toggle-xs` switches, each labelled with a live count | `relay-tty:session-filters` (JSON, window-prefs) | `{showRunning: true, showClosed: false}` | `app/components/sidebar-drawer.tsx:36-56`, `:279-295`, `:515-563` |
| Project (cwd) multi-select | `/grid`, `/lanes`, `/tiles` toolbars — **not the sidebar** | `relay-tty-project-filter` (plain localStorage, JSON array) | `[]` = all | `app/components/project-filter.tsx:6`, `:111-115` |
| Recency "Recent only" **(post-1.21.0)** | Top of the project-filter dropdown: a toggle plus a duration input | `relay-tty-recency-filter` (plain localStorage) | `{enabled: false, duration: "24h"}` | `app/components/project-filter.tsx:7-8`, `:32-66` |
| Show inactive | `/grid`, `/lanes` (`relay-tty-show-inactive`), `/tiles` (`relay-tty-tile-show-inactive`) | window-prefs | `false` | `app/routes/grid.tsx:54`, `app/routes/tiles.tsx:77` |

Duration grammar (`app/components/project-filter.tsx:22-29`):
`/^\s*(\d+(?:\.\d+)?)\s*(s|m|h|d|w)?\s*$/i`. Multipliers `s 1_000`, `m 60_000`,
`h 3_600_000`, `d 86_400_000`, `w 604_800_000`. **A bare number means hours.** Decimals
allowed. Rejects `n <= 0` or non-finite. Commits on blur or Enter; invalid input snaps back
to `24h`. Filters on `s.lastActivity >= now - ms` (`:57-66`).

When recency is on, projects with no recent sessions disappear from the dropdown but the
stored selection is **not** rewritten, so they reappear when it is turned off (`:142-145`).

**There is no text search over sessions** anywhere in the sidebar or the session picker.
The only text filters are the project-picker filter and the file-browser filter.

#### 1.2.5 Row anatomy (list view)

`SidebarSessionItem`, memoised on `session` + `selected`
(`app/components/sidebar-drawer.tsx:75-142`). This is exactly what the screenshot shows.

| Slot | Content |
|---|---|
| Status dot | Three states: **active** (`running && bps >= 1`) = `#22c55e` + `shadow-[0_0_6px]` + `animate-pulse`; **running idle** = `#22c55e`, dimmer glow, no pulse; **exited** = `#64748b`/50 (`:112-120`) |
| Title | `session.title \|\| "<command> <args>"`, truncated (`:121-123`) |
| Agent chip | `<AgentStateChip state={session.agentState}/>`, running only (`:124`) |
| Throughput | `formatRate(bps1 ?? bytesPerSecond)`. `< 1 → "idle"`, `< 1024 → "NB/s"`, `< 1 MiB → "N.NKB/s"`, else `"N.NMB/s"`. Green when active, grey otherwise (`:64-69`, `:125-128`) |
| Exit code | `exit {session.exitCode}` when not running (`:129-133`) |
| Row 2 | Right-aligned `timeAgo` only. **No cwd, no id, no total bytes** (`:135-139`) |

> The `idle` text visible on most rows in Scott's screenshot is the **throughput readout**
> (`bps < 1`), not the agent-state chip. `AgentStateChip` renders *nothing* for `idle` and
> `unknown` (`app/components/agent-state-chip.tsx:15-16`) — quiet sessions stay quiet.

`timeAgo` (`app/hooks/use-time-ago.ts:7-15`): `<60s → "Ns ago"`, `<60m → "Nm ago"`,
`<24h → "Nh ago"`, else `"Nd ago"`. Self-adjusting refresh: 5s / 30s / 60s by bucket
(`:24-29`).

#### 1.2.6 Row actions

| Gesture | Effect | Cite |
|---|---|---|
| Single click | Close mobile drawer → `revealSession(id)`; if a multi-session view handled it, **stay put**; otherwise `navigate('/sessions/:id')` | `app/components/sidebar-drawer.tsx:378-386` |
| Double click **(post-1.21.0)** | `e.currentTarget.blur()` (so keystrokes reach the zoomed terminal), then `revealSession(id, {zoom: true})`; falls back to navigation only if the path differs | `:104-109`, `:393-398` |
| Context menu | **None.** No `onContextMenu` anywhere in the sidebar | — |
| Swipe | **None** on rows | — |
| Kill | **None from the sidebar** | — |

**The reveal contract** (`app/lib/session-reveal.ts`) is the mechanism that makes the sidebar
a *finder* rather than an *exit*. A module-level single-handler slot; a view registers via
`useSessionReveal(cb)` (`:61-68`); `revealSession` returns `handler(id, opts) === true`
(`:49-55`) so a view can decline. Before revealing, `relaxFiltersForSession`
(`:82-103`) computes the **minimal** patch that un-hides the session — flip `showInactive`
only if status isn't running, disable recency only if it is what's hiding it, and *widen*
(never clear) the project filter by appending the cwd. Everything else the user set survives.

#### 1.2.7 Cards view

Toggle button (`Activity`/`List` icon) in the sidebar header, shown when there is at least
one session; key `relay-tty-sidebar-view`, default `"list"`
(`app/components/sidebar-drawer.tsx:60-61`, `:456-470`).

`SidebarAgentCard` (`app/components/agent-card.tsx:196-263`) shows: status dot, detected
agent name, `Cpu` icon when it is a known agent, a **160×24 sparkline**, the rate, and
timeAgo. It has **no agent-state chip** and **no double-click handler**.

`detectAgentLabel` (`app/components/agent-card.tsx:87-101`) substring-matches
`foregroundProcess` or `command` against, in order: `claude → "Claude Code"`,
`codex → "Codex"`, `aider`, `cursor`, `copilot`, `gemini`. **This list diverges from the
Rust classifier's `KNOWN_AGENTS`** (§3) which also knows `cursor-agent`, `opencode`,
`goose`, `amp`, `grok`, and bare-semver names. Use the Rust list, not this one.

#### 1.2.8 Sparkline

`Sparkline({values, width = 120, height = 32})`, `app/components/agent-card.tsx:42-84`.
Fewer than 2 points renders a flat `#2d2d44` line. Otherwise `max = Math.max(...values, 1)`,
`x = (i / (len - 1)) * width`, `y = height - (v/max) * (height - 4) - 2`; a green
`#22c55e` polyline at `strokeWidth 1.5` over a gradient-filled polygon (0.3 → 0.05 opacity).
Sizes in use: sidebar card 160×24, `/activity` card 140×28.

Data pipeline (`app/hooks/use-session-metrics.ts`): `SPARKLINE_MAX_POINTS = 120`
(≈2 min at 1 Hz), `FLUSH_MS = 1000`. Incoming `SESSION_UPDATE` frames accumulate in a
pending map and commit to React state **at most once per second** — without this, a dozen
sessions re-rendered every card and sparkline several times a second (`:13-17`, `:99-139`).
On mount, history is backfilled once from `GET /api/sessions/:id/sparkline`, bucket-average
downsampled to 120, applied only when fewer than 6 local points exist (`:141-175`).

#### 1.2.9 Empty states

Zero sessions → `<QuickLaunch compact/>` (`:609-610`). Filters hid everything → a `Filter`
icon and "No matching sessions" (`:611-615`).

---

### 1.3 Session lifecycle

#### 1.3.1 Create

All web launch paths funnel through `POST /api/sessions` with
`{command, args?, cwd?, cols?=80, rows?=24}` (`server/api.ts:107`). `command === "$SHELL"`
resolves to `process.env.SHELL || "/bin/sh"`. Response `201 {session, url}`.

`PtyManager.spawn` (`server/pty-manager.ts:119-163`): id = `randomBytes(4).toString("hex")`
(8 hex chars); cwd defaults to `$HOME`; spawns `bin/relay-pty-host` **detached** with
`stdio: "ignore"` and `unref()` so it survives the server. Env added:
`RELAY_SESSION_ID`, `RELAY_ORIG_COMMAND`, `RELAY_ORIG_ARGS` (JSON). Then polls for the Unix
socket with backoff 50→100→200→…→500 ms, timeout **3000 ms**, aborting early if the PID died
(`:414-437`). pty-host sets `TERM=xterm-256color`, `TERM_PROGRAM=relay-tty`
(`crates/pty-host/src/main.rs:1336-1337`) and ignores `SIGHUP` for itself (`:1578-1580`).

| Entry point | Command | cwd used | Navigates? | Cite |
|---|---|---|---|---|
| Sidebar **+ New** → command panel → **ProjectPicker** | any | picked project | yes | `app/components/sidebar-drawer.tsx:486-495`, `:300-323` |
| `Cmd+Shift+N` / `Ctrl+Shift+N` | always `$SHELL` — **no picker** | route-specific getter | yes (except tiles) | `app/hooks/use-new-session-shortcut.ts:19-49` |
| **"New session in this project"** button (`SquarePlus`) | `$SHELL` | `session.cwd` of the session you're viewing | yes | `app/routes/sessions.$id.tsx:187`, `:1107-1117` |
| `+` dropdown on grid/lanes | `$SHELL`/`bash`/`zsh` | **none sent** — server default | no | `app/routes/grid.tsx:550-568` |
| `+` dropdown on tiles | `$SHELL`/`bash`/`zsh` | `focusedSession?.cwd` | no | `app/routes/tiles.tsx:342-347` |
| `Cmd+D` / `Cmd+Shift+D` on tiles | `$SHELL` | `focusedSession?.cwd` | no | `app/routes/tiles.tsx:303-333` |
| `<QuickLaunch/>` empty state | any | picked project | yes | `app/components/quick-launch.tsx:35-63` |

cwd precedence for `Cmd+Shift+N`: grid/lanes = `zoomedCellId ?? selectedCellId ?? first`
(`app/routes/grid.tsx:484`); home = `realSessions[0]?.cwd`; activity = `sorted[0]?.cwd`;
session page = `session.cwd`; tiles = `focusedSession?.cwd`.

**Command menu** (`GET /api/available-commands`, `server/api.ts:649-673`): AI tools detected
by `sh -c "command -v <cmd>"` with a 2000 ms timeout, from the list `claude`, `codex`,
`opencode`, `aider`, `goose`, `gemini`, `amp`. Shells: always `$SHELL`, then whichever of
`bash`/`zsh`/`fish` exist. Custom commands come from `~/.relay-tty/commands.txt`.

**ProjectPicker** (`app/components/project-picker.tsx`). Every command shows it — nothing
bypasses it (`app/components/sidebar-drawer.tsx:325`). Projects from `GET /api/projects`
(`server/projects.ts:30-92`): (1) distinct cwds of existing session JSONs, excluding `$HOME`
and `/`, most-recent-first, source `"recent"`; (2) one-level git-repo scan of every line in
`~/.relay-tty/project-roots.txt`, source `"discovered"`. 30 s cache. Home row is dimmed and
annotated "not recommended" for AI tools, with an amber confirm step
(`app/components/project-picker.tsx:141-170`, `:212-230`). Filter input tries
`new RegExp(filter, "i")` and falls back to literal `includes` on a compile error (`:44-61`).

#### 1.3.2 Rename

**The web client has no rename UI.** Verified by grepping all of `app/` — the only hit is a
comment. Renaming is CLI/TUI only (`relay rename <id> [title...]`, `--unpin`;
`cli/commands/rename.ts:5-27`), which sends `SET_TITLE` (`0x24`, empty payload unpins).

The web *consumes* the result: `session.titlePinned` makes the pinned title outrank the live
OSC title in the document title and the session header
(`app/routes/sessions.$id.tsx:409-416`, `:1072`). Note the sidebar row ignores `titlePinned`
entirely and just renders `session.title` (`app/components/sidebar-drawer.tsx:122`).

#### 1.3.3 Kill

`DELETE /api/sessions/:id`, **owner only** (`server/api.ts:340`) — `SIGTERM` to the pty-host
PID, then unlink `<id>.json` and `<id>.sock` (`server/pty-manager.ts:183-201`, `:275-280`).

Web triggers, all behind a native `confirm()`:
- Session page: `confirm("Kill this session?")` → DELETE → `navigate("/")`
  (`app/routes/sessions.$id.tsx:1224-1228`). **Hidden for pair guests.**
- Tile pane menu: `confirm("Close this session?")` → remove the node immediately **and**
  DELETE (`app/components/tile-pane.tsx:173-177`, `app/routes/tiles.tsx:371-383`).
- Grid expand modal (`app/components/session-modal.tsx:473-477`).

#### 1.3.4 Detach, signals, restart

| Operation | Web client | Reality |
|---|---|---|
| Detach (`DETACH` `0x22`) | **never sent** | CLI `relay attach` on Ctrl+] only (`cli/attach.ts:132`) |
| Signal (`SIGNAL` `0x25`) | **never sent** | CLI `relay kill -s`, TUI `x` (`cli/tui/index.ts:306`) |
| Observe (`OBSERVE` `0x26`) | **never sent** | CLI and the server's own monitors (`server/pty-manager.ts:457-466`) |
| Restart | **does not exist anywhere** | — |
| Archive | **does not exist** | Exited sessions are hidden, then TTL'd away |

The browser's only way to interrupt is ordinary terminal bytes: `\x03` from the chat-mode
Ctrl+C button (`app/components/chat-terminal.tsx:394`), the Ctrl menu's `ctrlChar()`, or a
typed Ctrl+C. Closing a tab just closes the WebSocket.

#### 1.3.5 Exit and cleanup timing

| Rule | Value | Cite |
|---|---|---|
| Exited sessions drop out of the in-memory list | 5 min after `exitedAt` | `server/session-store.ts:8`, `:209-220` |
| Exited JSON deleted from disk | 1 h | `server/session-store.ts:10`, `:233-240` |
| Change-event debounce | 100 ms | `server/session-store.ts:9`, `:201-207` |
| Dead detection | PID gone **or** socket missing **or** socket unconnectable → `status="exited", exitCode=-1` | `server/pty-manager.ts:76-95` |
| Socket probe timeout | 2000 ms | `server/pty-manager.ts:439-451` |
| Metadata flush | 5 s, plus immediate on title-pin and agent-state change | `crates/pty-host/src/main.rs:2029-2050`, `:2143-2149` |

Session metadata is **disk-authoritative** at `~/.relay-tty/sessions/<id>.json`, written
atomically (`.tmp` + rename) by pty-host (`crates/pty-host/src/main.rs:2687-2702`).
`Session` fields are listed in `shared/types.ts:3-39`.

---

### 1.4 Terminal view

#### 1.4.1 Renderer

xterm.js, lazily imported with `FitAddon`, `WebLinksAddon`, `WebglAddon`, `Unicode11Addon`
(`app/hooks/use-terminal-core.ts:333-338`). Font stack
`ui-monospace, 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', 'Noto Sans Mono', monospace`
(`:355`). Theme: bg `#19191f`, fg `#e2e8f0`, cursor `#22c55e`, selection
`rgba(218,119,86,0.3)` (`:356-378`). `unicode.activeVersion = "11"` (`:394-396`).

`term.write` is monkey-patched to run `normalizeSgrColors` first, rewriting NeoVim 0.10+
`\e[38:2:R:G:Bm` (colon form, no colourspace) into `\e[38;2;R;G;Bm`
(`app/lib/sgr-normalize.ts:24-53`).

#### 1.4.2 Scrollback and replay

| Context | Scrollback | Replay tail | Cache |
|---|---|---|---|
| Session view / tiles / expand modal | **100 000** lines | full (up to the 10 MB ring) | IndexedDB on |
| Grid & lanes thumbnails | **2 000** lines | `256 * 1024` bytes | **off** |
| Mobile carousel neighbours | 100 000 | `256 * 1024` | off |

`app/hooks/use-terminal-core.ts:382`, `app/components/grid-terminal.tsx:140-150`,
`app/routes/sessions.$id.tsx:62`, `:1311`.

Replay is chunked at `REPLAY_CHUNK_SIZE = 64 * 1024` with a `setTimeout(…, 0)` between
chunks and a progress callback (`use-terminal-core.ts:64`, `:1497-1528`). `replayingRef`
stays true for `REPLAY_SUPPRESS_DELAY_MS = 200` after the write callback so xterm's async
DA/DSR/CPR replies don't leak to the PTY as stdin (`:71`, `:1464-1473`), with a 5 s safety
net that force-clears and warns (`:78`, `:1450-1456`).

**Buffer cache** (`app/lib/buffer-cache.ts`): IndexedDB `relay-tty-buffer-cache` v1, store
`buffers`, keyPath `sessionId`. Per-session cap **10 MB** (tail kept on overflow, `:201-204`),
flush every **1000 ms** or **64 KB**, TTL **24 h** swept on every `openDB` (`:18-21`,
`:45-50`). Cached bytes are written into xterm **before** the WebSocket connects, so RESUME
fetches only the delta; the container stays `visibility:hidden` until then so there is no
rapid-scroll flash on session switch (`use-terminal-core.ts:566-641`).

**Terminal instance pool**: `MAX_POOL_SIZE = 8` detached xterm wrappers kept for fast
remount, LRU by `pooledAt` (`use-terminal-core.ts:100-121`). `MAX_KEEP_ALIVE = 8` visited
sessions stay mounted on the session route (`app/routes/sessions.$id.tsx:56`).

#### 1.4.3 WebGL budget

Two modes (`use-terminal-core.ts:194`, `:409-449`). `"always"` — session view, **tiles**,
share view, expand modal — loads `WebglAddon` unconditionally. `"budgeted"` — gallery cells
only (`app/components/grid-terminal.tsx:136`) — registers with `app/lib/webgl-budget.ts`.

Browsers cap ~16 WebGL contexts per page; past that the browser evicts **at random** and the
loser silently falls back to xterm's DOM renderer, which rebuilds row `<span>`s on every
dirty write. The budget replaces roulette with determinism:

- `MAX_GALLERY_WEBGL = 8` (`webgl-budget.ts:29`), leaving headroom for the always-on views.
- Priority = `pinned ? Infinity : lastActivity` (`:61-63`). Selected/zoomed cells are pinned
  (`grid-terminal.tsx:205-207`).
- Rebalance every `REBALANCE_INTERVAL_MS = 2000`, plus on register/unregister/pin (`:32`).
- `REVOKE_HYSTERESIS_MS = 5000` — a granted cell keeps its context until it has been out of
  the top-N for 5 s, so two alternating cells don't thrash shader compiles (`:35`, `:93-102`).
- A **pinned** cell force-evicts the lowest-priority held context immediately; unpinned
  challengers wait out the hold (`:108-121`).
- `bumpActivity` is called at most once per second per cell and deliberately never
  rebalances (`:168-171`, `use-terminal-core.ts:1302-1308`).

#### 1.4.4 Write scheduler

Grid cells pass `throttleFps: 8` → 125 ms interval (`grid-terminal.tsx:131`). One shared
`requestAnimationFrame` loop serves all cells (`app/lib/write-scheduler.ts:193-222`) with
`FRAME_TIME_BUDGET_MS = 4` and `FRAME_BYTE_BUDGET = 512 * 1024`, checked **between** cells
and never before the first flush (`:44-47`, `:102-120`). Budget exhaustion **defers** —
bytes are never dropped or reordered. A rotating `startIndex` gives budget-cut cells priority
next frame (`:122-128`). Hidden tabs suspend rAF, so a 1000 ms interval flushes everything
unbudgeted (`:50`, `:146-178`).

#### 1.4.5 Search within a terminal

| Aspect | Detail | Cite |
|---|---|---|
| Toggle | **`Ctrl+Shift+F`** (no Cmd variant), or the magnifier button in the header | `app/routes/sessions.$id.tsx:382-384`, `:1151-1160` |
| Placement | `absolute inset-0 z-20` over the header, so xterm is never resized | `app/components/search-bar.tsx:88-94` |
| Live | Every query/case change calls `findNext`; empty query calls `clearSearch()` | `:44-54` |
| Next / prev | `Enter` / `Shift+Enter`, or the chevron buttons | `:66-78`, `:113-136` |
| Case toggle | `CaseSensitive` icon, `btn-primary` when on | `:139-149` |
| Counter | `"N of M"`, `"?"` when index < 0, `"No results"` at zero | `:81-85` |
| Close | `Escape` or the X | `:67-69` |
| Decorations | match `#eab30844`/`#eab30866`, active `#3b82f6aa`/`#3b82f6`, plus overview-ruler marks | `app/components/terminal.tsx:184-191` |

`TerminalHandle.findNext/findPrevious` accept `regex` and `wholeWord`
(`app/components/terminal.tsx:23-25`) but **the UI exposes only `caseSensitive`**. Zoomed
grid cells get their own `SearchBar` via a handle shim (`grid-terminal.tsx:464-499`).

#### 1.4.6 Selection, copy, clipboard

- **Auto-copy on selection.** `term.onSelectionChange` → `navigator.clipboard.writeText(sel)`
  → `onCopy`. Clipboard failure (permissions, non-HTTPS) is silently swallowed
  (`use-terminal-core.ts:552-564`). There is no explicit copy shortcut.
- Same handler **broadcasts** the selection to other devices via `sendClipboard(sel)` when
  `sel.length <= 1 MB` (`:560-563`).
- **"Copied" toast**: `#1a1a2e` pill with a `ClipboardCheck` icon, top-centre,
  **1500 ms** (`app/routes/sessions.$id.tsx:611-615`; multi-cell variant
  `COPY_TOAST_MS = 1500`, `app/hooks/use-session-inspect.ts:79`).
- **Mobile selection mode**: `setSelectionMode(on)` rewrites an injected style
  (`.xterm-rows span { pointer-events: auto|none }`) and makes the touch handlers bail out,
  so native OS selection works (`app/components/terminal.tsx:136-151`).
- **Visible-text viewer**: `getVisibleText()` walks the viewport rows, trims trailing blanks,
  and renders them in a `select-all` `<pre>` overlay with a "Copy all" button
  (`terminal.tsx:171-182`, `app/components/session-text-viewer.tsx:9-38`).

**Cross-device clipboard panel.** An inbound `CLIPBOARD` frame (remote selection or host
OSC 52) stores the text, **auto-opens** the panel, and auto-closes after **5000 ms**
(`app/routes/sessions.$id.tsx:617-624`). Panel shows a preview truncated at 2000 chars plus
"Copy to device" and "Paste to terminal" (`app/components/clipboard-panel.tsx:20-74`).

#### 1.4.7 Paste

| Path | Behaviour | Cite |
|---|---|---|
| Plain text `Cmd+V` | **Not intercepted** — falls through to xterm, which applies bracketed paste (`ESC[200~ … ESC[201~`) when the app set DECSET 2004 | `app/routes/sessions.$id.tsx:819` |
| Into a textarea/input | Handler returns early, so the scratchpad and search behave normally | `:821-823` |
| Finder file with a real path | `clipboardFilePaths(cd)` reads `text/uri-list`, keeps `file://` lines, `decodeURIComponent(new URL(l).pathname)`; falls back to `text/plain` lines starting `/`. Inserted **without uploading** | `:121-136`, `:828-834` |
| Finder file without a path (macOS Chrome/Safari) **(post-1.21.0)** | Uploaded like drag-drop, path pasted | `:796-804`, `:836-848` |
| Clipboard image | Nameless images renamed `paste-YYYYMMDD-HHMMSS.<ext>` (`.jpg`/`.webp`/`.gif`/`.png`) | `:838-848` |

Inserted paths are shell-quoted: `SAFE_PATH = /^[A-Za-z0-9_\-./+@%:,]+$/` passes through
bare, anything else is single-quoted with `'` → `'\''`, empty string → `''`
(`app/lib/shell-quote.ts:11-22`). Destination: the scratchpad if open, otherwise
`sendText(text + " ")` — the trailing space is the Terminal/iTerm drag-drop convention
(`app/routes/sessions.$id.tsx:766-775`).

#### 1.4.8 Links

One `ILinkHandler` serves both OSC 8 hyperlinks and `WebLinksAddon`'s regex URLs, so both
go through the identical security path (`use-terminal-core.ts:347-351`, `:384-393`).

**Scheme allowlist** (`app/lib/link-handler.ts:58-78`):

| Scheme | Action |
|---|---|
| `http:`, `https:`, `mailto:` | `window.open(uri, "_blank", "noopener,noreferrer")` |
| `file:` | Parsed into a `FileLink` and handed to the **in-app viewer**; resolves on the pty-host, never the browser. Hostname ignored. Fragment `#42`, `#42:10`, `#L42` parsed as line:col (`:33-49`) |
| anything else (`javascript:` above all) | **Refused**, no-op |

`allowNonHttpProtocols: true` is set and is safe *only* because `activate` enforces the
allowlist (`:157`). **Anti-spoof tooltip**: hovering appends a
`div.xterm-hover.relay-link-tooltip` inside `Terminal.element` showing the **real target
URI**, so link text cannot lie (`:130-150`). Read-only terminals — gallery thumbnails and
the share view — never activate links and never show the tooltip (`:113-114`, `:131`).

**Bare-filename detection** (`app/lib/file-path-detect.ts`) — this is what makes agent output
navigable. `FILE_PATH_RE` (`:65-66`) has three ordered alternatives so slash paths win over
bare names:

```
1. (\.\.?\/|\/)[^\s:'"`\])}>,;!]+\.[a-zA-Z0-9]+      ./ ../ / prefixed
2. [\w\-.]+(?:\/[\w\-.]+)+\.[a-zA-Z0-9]+             contains a slash
3. [a-zA-Z0-9_][a-zA-Z0-9_\-.]*\.[a-zA-Z0-9]+        bare filename (last)
   … optionally followed by (?::(\d+))?(?::(\d+))?   :line:col
```

Gated on the `FILE_EXTENSIONS` allowlist (`:11-42`, ~130 extensions across code/web/config/
shell/docs/media). Trailing `[,;)\]}>]+` stripped.

Because a bare name is a guess, heuristic matches are **existence-gated** before they are
underlined: `POST /api/sessions/:id/exists` with `{paths}` returns
`{results: [{path, exists, isFile}]}` and only `exists && isFile` survives
(`app/lib/file-link-provider.ts:294-306`, `server/api.ts:443-470`, batch capped at 100). A
module-level `existenceCache` with `EXISTENCE_TTL_MS = 30_000` plus an in-flight dedupe map
keeps hovering from causing a network storm (`:232-322`). This is what kills the `Node.js` /
`Vue.js` false positives. Markdown `[text](path)` links are detected too and are
**never** existence-gated — explicit intent (`:397-426`, `:453-455`).

Soft-wrapped paths are reconstructed by walking back through `isWrapped` rows, but only when
the match starts within the first 4 columns, and only lazily at activation time (`:155-213`).

**Mobile first-tap.** A scrollback-mode tap hit-tests the cell *before* focusing xterm's
textarea; a hit opens the viewer and **never focuses**, so the keyboard doesn't rise and
the link opens on the first tap (`use-terminal-core.ts:1157-1180`). Tap thresholds
`TAP_MAX_DISTANCE = 10` px, `TAP_MAX_DURATION = 300` ms (`:959-960`).

#### 1.4.9 Inline images (iTerm2 OSC 1337)

pty-host strips `ESC ] 1337 ; File=<args> : <base64> BEL|ST` from the stream and emits an
`IMAGE` frame — cap `IMAGE_MAX_SIZE = 10 MB`, MIME sniffed from magic bytes
(`crates/pty-host/src/main.rs:826-930`, `:626`). Wire format
`[u32 BE id_len][id][mime UTF-8 NUL][raw bytes]` (`shared/client/messages.ts:100-113`).
Client makes a `Blob` + `createObjectURL` (`use-terminal-core.ts:1401-1404`).

Thumbnails accumulate in a floating panel — `absolute bottom-14 right-3 z-20 max-h-[50%] w-48`,
header "Images (n)" with an X that revokes every blob URL
(`app/routes/sessions.$id.tsx:1398-1430`). Cap **50** images, oldest evicted and revoked
(`app/hooks/use-session-inspect.ts:78`, `:157-164`). Clicking a thumb opens a `z-40`
full-overlay viewer. Images are **not** cleared on session switch — only manually
(`app/routes/sessions.$id.tsx:342-343`).

#### 1.4.10 Font size and zoom

| Capability | Exact behaviour | Cite |
|---|---|---|
| Keyboard | `(metaKey \|\| ctrlKey)` + `=`/`+` → +1, `-`/`_` → −1; `preventDefault` also kills browser zoom | `app/routes/sessions.$id.tsx:394-402` |
| Pinch | Two-finger on `.xterm`; `PINCH_THRESHOLD = 30` px of accumulated distance per step, **±2 px font per step**, remainder kept | `use-terminal-core.ts:962-974`, `:1046-1059` |
| iOS gesture block | `gesturestart`/`gesturechange` `preventDefault`ed so iOS can't zoom the page | `:897-905` |
| Storage | `relay-tty-fontsize-<sessionId>` (tiles: `relay-tty-tile-fontsize-<id>`), via window-prefs | `app/routes/sessions.$id.tsx:55`, `app/routes/tiles.tsx:80` |
| SIGWINCH | On font change: set `fontSize`, `fit({snapToBottom: false})`, then **after 50 ms** send `RESIZE(cols, rows)` | `app/components/terminal.tsx:256-273` |
| Grid variant | Recomputes cols/rows from the **pre-change reference area** divided by the new cell size after a 100 ms settle — "iTerm don't-adjust-window" behaviour | `app/components/grid-terminal.tsx:350-386` |

**Defaults diverge despite the shared key**: session view default **14**, clamp 8–28
(`sessions.$id.tsx:77-80`); grid/lanes default **12**, clamp 4–28 (`grid.tsx:63-69`);
tiles clamp 8–28 (`tiles.tsx:569`). The docs claim the size is "shared across all views" —
the key is, the default is not.

#### 1.4.11 The resize wand

`WandSparkles` button, `absolute top-3 right-3 z-10`, `tabIndex={-1}` and
`onMouseDown`/`onTouchStart` `preventDefault`ed so it never steals focus or raises the mobile
keyboard (`app/components/terminal.tsx:304-316`).

It sends `RESIZE(cols, rows > 1 ? rows - 1 : rows + 1)` **immediately**, then after 50 ms
`RESIZE(cols, rows)` (`:228-249`). Two genuinely different geometries are required because
pty-host dedupes same-size RESIZE, and a no-change SIGWINCH cannot repaint a corrupted
Ink/TUI frame — the frame string is identical so nothing repaints. It nudges **rows, not
columns**, so line wrapping on other connected devices isn't reflowed. Toast "Text sizing
fixed" for 1500 ms, shown only when something was actually sent.

`useTerminalInput({sendResize: false})` in the main Terminal means refits from keyboard
show/hide or window resize do **not** send SIGWINCH. The only SIGWINCH paths are: the
post-handshake fit on `SYNC` (`use-terminal-core.ts:1284-1292`), a font-size change, the
wand, and grid fit-to-cell.

#### 1.4.12 Clear scrollback

`Cmd+K` on macOS or `Ctrl+Shift+K` elsewhere (`app/routes/sessions.$id.tsx:386-393`), or the
info-panel "Clear scrollback" item. Client does `term.clear()` + a one-byte
`CLEAR_SCROLLBACK` (`0x23`).

Server resets the ring buffer and `total_bytes_written = 0` but **deliberately does not**
reset the monotonic RESUME/SYNC offset, so delta replay still works
(`crates/pty-host/src/main.rs:1460-1473`). Every connected client receives the broadcast and:
clears its display, zeroes the reported size, and **unconditionally** deletes the shared
IndexedDB cache entry — even cache-disabled gallery cells purge it, because a clear is
authoritative for every client (`use-terminal-core.ts:1377-1400`).

#### 1.4.13 Scroll

Touch scroll is tracked in **float line units**, not pixels, decoupling it from row-height
fluctuation caused by Unicode/emoji; the sub-pixel remainder is applied as a
`translateY` transform (`use-terminal-core.ts:945-986`). Velocity is smoothed
`v = v*0.7 + instant*0.3`; momentum uses `friction = 0.97` per frame and stops below
`0.05` lines/frame, then snaps to a whole line (`:918-943`, `:1091-1094`). During momentum,
xterm's `viewport._innerRefresh`/`syncScrollArea`/`_handleScroll` are replaced with no-ops
to kill row-height oscillation; restoring calls `_innerRefresh()` **before**
`syncScrollArea(true)` — the reverse order reads a stale scrollTop and jumps to the top
(`:1188-1236`).

Mouse-mode (TUI) touches emit discrete wheel events (button 64/65) per row height, and taps
dispatch synthetic `mousedown`/`mouseup` so xterm's own encoder handles them; DEFAULT
encoding writes raw bytes `32+button` etc. rather than going through `TextEncoder`, which
would corrupt values > 127 (`:837-891`, `:1129-1153`).

`atBottom` = `buf.viewportY >= buf.baseY` (`:285-295`). The scroll-to-bottom button is a
`NoKbButton` shown only when not at bottom (`app/routes/sessions.$id.tsx:1354-1363`).

---

### 1.5 Multi-session layout

> **Correction to a common assumption:** there is **no 2-col / 3-col / N-col control
> anywhere.** Grid auto-packs; lanes has W/H pixel steppers; tiles has per-column pixel
> widths; activity uses a static `grid-cols-1 md:grid-cols-2 xl:grid-cols-3`. The three
> terminal columns in Scott's screenshot are **`/tiles` columns**, and the two icons right
> of "10 sessions" are the `Columns2`/`Rows2` split buttons
> (`app/routes/tiles.tsx:739-758`), not a column-count picker.

#### 1.5.1 `/grid`

Layout uses a **fixed `LAYOUT_FONT_SIZE = 12`** — deliberately not the per-session font — so
changing one cell's font never reflows the grid (`app/routes/grid.tsx:57-61`). `charW = 7.2`,
`lineH = 14.4`. Cell size comes from a **dimension snapshot** captured when a session first
appears (default 80×24); live `SESSION_UPDATE` dimension changes are ignored to prevent
re-shuffling (`:176-207`, `:445-451`). `GRID_GAP = 4`.

`computeFitScale()` binary-searches 30 iterations between 0.01 and 2 for the largest uniform
scale at which column-first packing fits without scrolling, capped at 1 (`:83-119`). The
viewport is `overflow-hidden` — it **never** scrolls (`:324`).

Zoom geometry: full viewport height, width `min(cols * 12 * 0.6, vpW)` — computed at the
*layout* font size so the box doesn't move when Cmd+/- changes the session font (`:240-267`).
Zoomed cells get 2px-wide **width drag handles** on both edges, delta doubled because the
cell stays centred, clamped `[200, vpW]`; on release a real PTY RESIZE is sent (`:376-393`,
`:299`, `:310`).

Sort order is **snapshotted per `sortKey:sortDir`**: new sessions append, removed ones are
filtered out, so live metric updates never reshuffle cells (`:499-520`). Deep link
`?session=<id>` opens the expand modal (`:529-548`).

#### 1.5.2 `/lanes`

Identical logic to grid, duplicated, with these differences
(`app/routes/lanes.tsx:314-835`):

| Aspect | Lanes |
|---|---|
| Cell size | Uniform `laneWidth × laneHeight` for every cell |
| Controls | **W** and **H** steppers, `ADJUSTMENT_STEP = 20` px; W clamp `[100,1200]`, H clamp `[200,1600]` (`:57`, `:526-540`, `:692-729`) |
| Defaults | `DEFAULT_LANE_WIDTH = 480`, `DEFAULT_LANE_HEIGHT = 800` (`:58-59`) |
| Centring | All positions shifted by `(vpW - totalW)/2` (`:216-223`) |
| Zoom | Fixed **1:2 portrait** — width = height / 2 (`:236-237`) |
| Width drag handles | None |

Storage keys `relay-tty-sort`, `relay-tty-sort-dir`, `relay-tty-show-inactive`,
`relay-tty-fontsize-<id>` are **shared with grid**.

#### 1.5.3 `/tiles` — the actual workspace

Tiles is the only multi-session view whose panes are **fully interactive** `<Terminal>`
components with full scrollback and unconditional WebGL
(`app/components/tile-pane.tsx:251-264`). Grid and lanes are `readOnly` thumbnails.

**Tree model** (`shared/tile-layout.ts`). `TerminalNode {type, id, sessionId}` and
`SplitNode {type, id, direction, children, sizes}`. Invariant: **at most two levels** — root
is `null`, a terminal, or a **horizontal** split (columns); each column is a terminal or a
**vertical** split containing only terminals. No horizontal-inside-vertical (`:1-12`). Node
ids are `crypto.randomUUID().slice(0,8)`. `sizes` are percentages; every structural mutation
resets them to equal shares (`:46-49`). `LAYOUT_VERSION = 1`; deserialization validates the
whole tree and falls back to empty on any failure (`:604-634`).

**Pixel widths and the carousel** (`app/components/tile-split-container.tsx`):

- `DEFAULT_COLUMN_WIDTH = 640` ("~80 cols at default font size"),
  `MIN_COLUMN_WIDTH = 200` (`:8-9`).
- Root container is `overflow-x-auto`, `scrollSnapType: "x mandatory"`,
  `overscrollBehavior: "contain"`, `scrollBehavior: "smooth"`; each root column gets
  `scrollSnapAlign: "center"` (`:170-199`). Momentum, axis-lock and snap timing are left
  entirely to the browser.
- **Edge gutters** so the first and last column can centre-snap:
  `gutterStart = max(0, floor((viewportW - firstColW)/2))`, applied as **both**
  `paddingInline*` and `scrollPaddingInline*` (`:163-179`).
- **Auto-centre on focus**: the containing column is `scrollIntoView({inline: "center"})`,
  `auto` on the first fire to avoid a mount animation (`:124-149`).
- **Column resize**: 6px strip at `right:-3px`, `cursor-ew-resize`, pointer-captured;
  `max(200, startWidth + deltaX)`, persisted per node id (`:304-343`).
- **Stack resize**: 6px strip at `bottom:-3px`; minimum is `max(5%, 8000/containerHeightPx)`
  — never smaller than 5% or 80px (`:218-265`).

**Creating panes**:

| Trigger | Result |
|---|---|
| `Cmd+D` / `Columns2` button | New session, `insertAfterColumn(focusedNodeId)`, focus moves to it (`app/routes/tiles.tsx:303-316`) |
| `Cmd+Shift+D` / `Rows2` button | New session, `splitLeafVertical(focusedNodeId)` — promotes a lone column to a vertical split or inserts a sibling (`:319-333`) |
| `Cmd+Shift+N` | New session as the **leftmost** full-height column; does not navigate away (`:336-340`) |
| Sidebar click | Focus the pane already showing it, else open one placed like `Cmd+D` (`:649-692`) |

`Cmd+D` is guarded `metaKey && !ctrlKey` — **Ctrl+D is EOF and must always reach the PTY**
(`:577-579`).

**Reconciliation** with the server list runs on every change (`:218-250`): sessions gone from
the server are removed and their dismissed flag cleared; sessions filtered out are removed
but stay dismissed; eligible sessions not in the layout and not dismissed are inserted
newest→oldest with `insertAtStart` so the newest ends up leftmost.

**Drag and drop.** Pointerdown on a pane header (left button, not on a `<button>` or
`[data-tile-menu]`) focuses the pane; dragging starts after `DRAG_THRESHOLD_PX = 5`
(`app/components/tile-pane.tsx:16`, `:137-144`). The dragged pane goes to `opacity-40`.
Hit-testing uses `elementFromPoint` → nearest `[data-tile-column-id]`
(`app/routes/tiles.tsx:414-508`):

| Zone | Condition | Mutation | Indicator |
|---|---|---|---|
| top | `relY < 0.25` | `insertAtColumnTop` | Horizontal band, `bg-[#3b82f6]/20`, `backdrop-blur-[1px]`, 2px bottom border |
| bottom | `relY > 0.75` | `insertAtColumnBottom` | Same band, anchored low, 2px top border |
| left | middle 50%, `relX < 0.5` | `insertBeforeColumn` | 3px vertical bar, solid `#3b82f6`, `shadow-[0_0_6px_rgba(59,130,246,0.8)]` |
| right | middle 50%, `relX >= 0.5` | `insertAfterColumn` | Same bar at the right edge |

For top/bottom the target is refined to the pane under the cursor so intra-column reorder
targets the right sibling (`:457-465`). Dropping on yourself, or left/right inside your own
column, hides the indicator and does nothing (`:536-542`). `movePane` removes the source
(collapsing single-child splits), **re-resolves** the target (which may have been reparented
by that collapse), then inserts (`shared/tile-layout.ts:368-407`).

**Pane header** (`app/components/tile-pane.tsx:187-249`): status dot, session label, cwd
(`hidden md:inline`, `max-w-[30ch]`), and a `MoreHorizontal` menu that renders the shared
`SessionInfoPanel` with `hideViewModeToggle` and `onRemoveFromLayout`. Exited panes get a
`bg-[#0a0a0f]/70` overlay reading "exited".

**"Remove from tiles"** is non-destructive: the session id joins `dismissedIdsRef`, is
persisted to `relay-tty-tile-dismissed`, and the node is removed; reconcile will not re-add
it. Only the sidebar reveal path un-dismisses (`app/routes/tiles.tsx:354-366`, `:668`).

Tiles has **no zoom** — a sidebar double-click behaves like a single click.

#### 1.5.4 `/activity`

Running sessions only, hard-coded `sortSessions(sessions, "active", "desc")` — **no sort UI,
no filters, no fullscreen, no perf HUD** (`app/routes/activity.tsx:34-39`). Responsive
`grid-cols-1 md:grid-cols-2 xl:grid-cols-3`. The whole card is a button that navigates;
**nothing else on the card is actionable** — no kill, no zoom, no menu.

#### 1.5.5 `/` (Home)

Mobile with sessions: **auto-redirects** to the first running session
(`app/routes/home.tsx:138-145`). Desktop: a single **phone-frame preview** of one session,
with a real live `<Terminal fontSize={14}/>` inside a `rounded-[2.5rem]` bezel with a notch.
The session list lives in the sidebar, not on this page. `?new` forces the empty state
(`:91-92`).

#### 1.5.6 Fullscreen

`document.documentElement.requestFullscreen()` / `exitFullscreen()`, icon driven by a
`fullscreenchange` listener. Present on `/grid`, `/lanes`, `/tiles`, `/`; **absent** on
`/activity` and `/desktop`. Always `hidden lg:flex`. **No keyboard shortcut.**
(`app/routes/tiles.tsx:266-269`, `:830-836`.)

#### 1.5.7 How many terminals can be live

**Unbounded by the app.** Every grid cell, lane cell and tile pane mounts a real terminal
with its own WebSocket. The only hard limits are `MAX_GALLERY_WEBGL = 8` (§1.4.3) and
`MAX_POOL_SIZE = 8` for the remount pool. Nothing caps concurrent sessions.

---

### 1.6 Status and telemetry

#### 1.6.1 Metrics pipeline

pty-host computes throughput every second and broadcasts `SESSION_METRICS` (`0x14`) —
`[f64 bps1][f64 bps5][f64 bps15][f64 totalBytes]` — **only while non-zero or on decay to
zero** (`crates/pty-host/src/main.rs:2151-2165`). Sparkline ring is `SPARKLINE_RING_CAP =
3600` (1 h at 1 s) (`:1235`), served on demand via `SPARKLINE_REQUEST` (`0x18`).

The server broadcasts the whole `Session` as `SESSION_UPDATE` (`0x15`, UTF-8 JSON) to every
WebSocket client on metadata change (`server/ws-handler.ts:65-77`), and — deliberately —
does *not* fire `sessions-changed` for it, to avoid loader-revalidation storms (`:45-52`).

#### 1.6.2 The shared `/ws/events` connection (post-1.21.0)

`app/lib/events-client.ts` is **one refcounted WebSocket per page**. Previously the root
layout, the sidebar and the activity view each opened their own, so every `SESSION_UPDATE`
was parsed N times — measured as periodic 50–165 ms main-thread stalls on phone-class CPUs,
which swallowed keystrokes.

| Aspect | Value | Cite |
|---|---|---|
| Text frames | exactly `"sessions-changed"` → fan out | `:66-70` |
| Binary frames | `data[0] === SESSION_UPDATE`, JSON decoded **once**, fanned out | `:72-81` |
| Reconnect | 1000 ms doubling to 10 000 ms | `:22-23`, `:83-95` |
| `online` listener | Installed once; resets delay and reconnects immediately | `:102-112` |
| Linger | `LINGER_MS = 250` after the last unsubscribe, so StrictMode double-mount and route transitions reuse it | `:41-44` |

`useSessionEvents` revalidates on `sessions-changed`, skips when `navigator.onLine === false`,
and runs a **10 s fallback poll** while disconnected with `retries > 0`
(`app/hooks/use-session-events.ts:4`, `:24-33`).

#### 1.6.3 Activity age

Row age = `useTimeAgo(running && lastActiveAt ? Date.parse(lastActiveAt) : createdAt)`.
Note the **two different clocks**: the recency filter uses numeric `s.lastActivity`
(`app/components/project-filter.tsx:65`) while row display uses
`lastActiveAt ?? createdAt` (`app/components/sidebar-drawer.tsx:91-93`).

`formatUptime` (`app/components/agent-card.tsx:28-39`): `Ns` / `Nm` / `Nh Nm` / `Nd Nh`,
refreshed on a 30 s interval.

#### 1.6.4 Perf HUD

Mounted **only** on `/grid` and `/lanes` (`app/components/perf-hud.tsx`). Enable with
`?perf=1` or **`Ctrl+Shift+`` `** (`e.code === "Backquote"`), persisted as
`relay-tty-perf-hud`. Rows: `frame` (EMA `ema*0.9 + dt*0.1`, seeded 16.7, deltas ≥1000 ms
ignored for tab backgrounding), `cells`, `render` (`N webgl / M dom`), `write` (bytes/sec),
`heap` (Chrome only). Zero cost when hidden — the rAF loop and 1 Hz snapshot only run while
visible (`:41-62`, `:67-127`).

---

### 1.7 Notifications

#### 1.7.1 OSC 9 → banner

pty-host parses `ESC ] 9 ; <text> (BEL | ST)` out of the stream, **strips it from the
output**, and broadcasts `NOTIFICATION` (`0x05`)
(`crates/pty-host/src/main.rs:748-796`). Partial sequences straddling a read boundary are
preserved. A synthetic `"Session idle"` also fires when sustained activity stops — previous
`bps5 > 100` and now `bps1 < 1.0` and `bps5 <= 100` (`:2167-2177`).

`handleNotification` (`app/routes/sessions.$id.tsx:441-489`) does three things in order:

1. **Always** shows an in-app toast for **4000 ms** (top-centre, `BellRing`, `animate-banner-in`,
   click to dismiss).
2. `POST /api/notifications {sessionId, sessionName, message}` and appends to local history.
3. **Only when `document.visibilityState === "hidden"` and permission is granted**, a system
   notification via `ServiceWorkerRegistration.showNotification(title, {body, tag:
   "relay-<id>", data: {url: "/sessions/<id>"}})`, falling back to `new Notification(...)`.

Permission is requested **only on a user gesture** (the `BellOff` header button) because iOS
Safari ignores automatic requests; granting immediately triggers `subscribeToPush()`
(`:424-439`, `:1120-1131`).

#### 1.7.2 Server-side notification history

`server/notification-store.ts`: a JSON array at `~/.relay-tty/notifications.json`, max **100**
entries trimmed from the front. Entry = `{id (4-byte hex), sessionId, sessionName, message,
timestamp}`. UI is `app/components/notification-panel.tsx` — newest-first, `maxHeight: 50vh`,
per-entry delete, clear-all, entries for dead sessions dimmed with an "ended" chip.

#### 1.7.3 Web Push (VAPID)

`server/push-store.ts`. Keys auto-generated on first use and persisted to
`~/.relay-tty/push/vapid.json` (`:184-200`); subject is hard-coded
`"mailto:push@relaytty.com"` because Apple APNs rejects `.local` TLDs (`:52-57`).
Subscriptions live in `~/.relay-tty/push/subscriptions.json`, deduped by endpoint.

Selection rule (`:104-117`): an empty `sessionIds` means all sessions; a
`perSessionTriggers[sessionId][trigger]` entry **wins over** the global `triggers[trigger]`.
Payload: `{title: "relay-tty: <sessionName>", body, url, sessionId, trigger, timestamp}`,
TTL 3600. HTTP 410/404 removes the subscription.

Service worker (`public/sw.js`): every push shows a visible notification (iOS requirement)
with `tag: relay-<sessionId>-<trigger>` and `renotify: !!sessionId` (`:25-48`);
`notificationclick` focuses a matching window or opens `data.url` (`:87-104`).
**Bug — do not copy:** the `pushsubscriptionchange` re-subscribe posts only three triggers,
silently dropping `agentBlocked` (`sw.js:78`).

#### 1.7.4 Smart triggers — exact rules

Names and defaults (`shared/notif-triggers.ts:6`, `:11-16`):

| Trigger | Client default |
|---|---|
| `activityStopped` | **off** |
| `activitySpiked` | **off** |
| `sessionExited` | **on** |
| `agentBlocked` | **on** |

Server state machine (`server/notify.ts`), constants `IDLE_DEBOUNCE_MS = 5000`,
`SPIKE_ABS_THRESHOLD = 500` B/s, `ACTIVE_THRESHOLD = 1` B/s (`:16-20`):

| Trigger | Rule | Message | Cite |
|---|---|---|---|
| `activityStopped` | Ignores the first **3** updates (warm-up). On `wasActive && !isActive` with `idleSince === 0` and not yet fired, arm a 5 s timer; any activity cancels and resets. Once per idle period | `"Activity stopped"` | `:146-179` |
| `activitySpiked` | `!wasActive && isActive && bps1 >= 500`, not already fired | `"Activity spike detected"` | `:181-190` |
| `sessionExited` | On the `exit` event | `"<cmd> <args> completed"` / `"… failed (exit N)"` | `:84-98` |
| `agentBlocked` **(post-1.21.0)** | `session-update` whose **changed fields** contain `agentState === "blocked"` (so once per transition) and `status === "running"` | `"<foregroundProcess or 'Agent'> is waiting for input"`; a semver-looking process name (Claude Code's comm name) is replaced with `"Agent"` | `:126-137` |

`sendPushAndRecord` (`:63-81`) is a **no-op unless at least one subscription has that
trigger enabled for that session** — it then records to the store *and* sends the push.

The client mirrors `activityStopped`/`activitySpiked` with identical constants
(`app/hooks/use-smart-notifications.ts:49-53`); `sessionExited` and `agentBlocked` are
server-push-only.

#### 1.7.5 Settings storage

Global `relay-tty-notif-settings`; per-session `relay-tty-notif-<sessionId>`;
effective = per-session ?? global (`app/lib/notif-settings.ts:12-13`, `:55-57`). "Mute" is
expressed as turning all four toggles off for that session. Toggling writes localStorage then
calls `syncPushTriggers()` (`app/routes/sessions.$id.tsx:503-516`).

---

### 1.8 Input

#### 1.8.1 Shift+Enter (kitty protocol)

`attachCustomKeyEventHandler` sends **`\x1b[13;2u`** (CSI 13;2u) on keydown and returns
`false` for **all** event types, fully suppressing xterm's `\r`
(`app/hooks/use-terminal-input.ts:44-58`). Programs that opt into extended key reporting —
Claude Code included — distinguish it from submit and insert a newline. `beforeinput
(insertLineBreak)` also checks `shiftEnterHandled` so it doesn't double-send
(`use-terminal-core.ts:734-744`).

#### 1.8.2 Mobile toolbar

`SessionMobileToolbar` renders when `window.innerWidth <= 1024`. Key row
(`app/components/session-mobile-toolbar.tsx:319-345`), all sent through `applyModifiers`:

| Button | Bytes | | Button | Bytes |
|---|---|---|---|---|
| ← | `\x1b[D` | | Tab | `\t` |
| ↓ | `\x1b[B` | | Enter | `\r` |
| ↑ | `\x1b[A` | | Esc | `\x1b` |
| → | `\x1b[C` | | | |

Plus Ctrl (sticky + menu), Alt (sticky), TextSelect, FolderOpen, ClipboardCopy. A touch that
moved more than `SCROLL_TAP_THRESHOLD = 10` px is treated as a scroll and the key is **not**
sent (`:13`, `:109-121`).

**Sticky modifiers**: `Ctrl` maps a single A–Z char to `charCode - 64`; `Alt` prefixes
`\x1b`; **both clear after one use**. While either is on,
`terminalRef.setInputTransform(applyModifiers)` routes physical-keyboard input through the
same transform (`app/routes/sessions.$id.tsx:998-1029`).

**Ctrl menu** (`app/lib/ctrl-shortcuts.ts:15-26`), editable in Settings as
`"<LETTER> <label>"` lines, stored in `relay-tty-ctrl-shortcuts`:

| | | | | |
|---|---|---|---|---|
| `^C interrupt` `0x03` | `^D EOF/logout` `0x04` | `^Z suspend` `0x1A` | `^R recall` `0x12` | `^L clear` `0x0C` |
| `^A home` `0x01` | `^E end` `0x05` | `^W del word` `0x17` | `^U kill to start` `0x15` | `^K kill line` `0x0B` |

Control byte = `String.fromCharCode(upper.charCodeAt(0) - 64)` (`:57-60`).

#### 1.8.3 Scratchpad

Floating text composer above the key row, overlaying xterm so **the terminal never resizes**
(`app/components/session-mobile-toolbar.tsx:235-238`). Auto-grows to 128 px then scrolls.

**Plain Enter inserts a newline. Only `Cmd+Enter` / `Ctrl+Enter` sends** (`:250`) — the docs
say otherwise (§1.14). `sendPad()` dedupes into history, `POST /api/scratchpad-history`,
calls `sendText(padText)`, then **after 50 ms** sends `"\r"`
(`app/routes/sessions.$id.tsx:710-715`). History (server-side at
`~/.relay-tty/scratchpad.hst`, newline-delimited with embedded newlines escaped) opens a
full-viewport picker listing entries newest-first.

#### 1.8.4 Virtual-keyboard handling

This is a large, hard-won body of browser workarounds:

| Problem | Fix | Cite |
|---|---|---|
| iOS ignores `autocomplete=off` and routes typing through `insertCompositionText` carrying the **full accumulated buffer** | `stopImmediatePropagation` on composition events, block xterm's `input` handler during composition, compute deltas manually; on buffer replacement send `\x7f` per previously-sent char then the new text | `use-terminal-core.ts:683-732`, `:785-801` |
| keydown + `beforeinput(insertText)` double-send | Capture-phase keydown records `keydownHandledKey` for single printable chars with no modifiers; a matching `beforeinput` is skipped | `:698-708`, `:803-821` |
| Android Gboard autofill toolbar | `PlainInput` is a single-line `<textarea rows=1 wrap="off">` styled as an input, because Gboard targets `<input>` but ignores `<textarea>` | `app/components/plain-input.tsx:17-54` |
| iOS auto-zooms ~10% on textarea focus | xterm's hidden textarea gets `style.fontSize = "16px"` | `use-terminal-core.ts:661-664` |
| Keyboard changes the visual viewport | `useKeyboardViewport()` sets `:root --app-h = visualViewport.height`, skipped when `vv.scale > 1.05` or width > 1024; `.h-app` resolves to it | `app/hooks/use-keyboard-viewport.ts:14-48` |
| iOS fires no vv resize during its ~250 ms dismiss animation, leaving a black gap | On `focusout`, after a 60 ms cancellable delay, `--app-h` reverts to `100dvh` | `:61-81` |
| Buttons stealing focus / raising the keyboard | `NoKbButton`: always `tabIndex={-1}`, `onMouseDown` preventDefault, `onTouchEnd` preventDefault + `onPress()` | `app/components/no-kb-button.tsx:13-34` |

Android IME edit intents are translated explicitly: `deleteContentBackward → \x7f`,
`deleteContentForward → \x1b[3~`, `deleteWordBackward → \x17`, `deleteWordForward → \x1bd`,
`insertReplacementText → \x17 + text` (`use-terminal-core.ts:752-783`).

#### 1.8.5 Carousel swipe (mobile)

Enabled when `isMobile && !textViewerOpen && !pickerOpen && allSessions.length > 1`
(`app/routes/sessions.$id.tsx:960-966`). Commit threshold `H_THRESHOLD = 30` px **and**
`absDx > absDy * 1.5`; rejected when `absDy > 20 && absDy > absDx`, or on multi-touch
(pinch owns it) (`app/hooks/use-carousel-swipe.ts:22-28`, `:211-215`). Rubber band
`damped = dx * (1 - min(|dx|/(pageW*1.5), 1) * 0.4)`. Inertia projection with
`FRICTION = 0.92`, `MIN_VELOCITY = 0.5`; target skip clamped to **±1** because only
immediate neighbours are pre-rendered. Snap is 200 ms ease-out-cubic; navigation happens in
the completion callback.

**Neighbours mount lazily** (post-1.21.0): only on mobile, `NEIGHBOR_MOUNT_DELAY_MS = 1000`
after the active session's content is ready (or immediately on swipe start), with a 256 KB
tail replay and no cache. Swiping to one upgrades it in place to a full replay
(`app/routes/sessions.$id.tsx:58-60`, `:1286-1316`).

#### 1.8.6 File upload (post-1.21.0)

Three triggers, one flow: the header `Upload` button, drag-and-drop anywhere on the terminal,
and clipboard paste of files/images (§1.4.7).

`POST /api/upload` with a raw binary body and header `X-Filename`; optional
`X-Upload-Dir` (URI-encoded absolute path) overrides the destination
(`app/routes/sessions.$id.tsx:735-739`). Default destination is the contents of
`~/.relay-tty/upload-dir.txt`, default `~/.relay-tty/uploads` (`server/api.ts:30-40`).
Collisions get a `-<6 hex>` suffix rather than overwriting (`:749-755`). Cap
`MAX_UPLOAD = 100 MB` → `413` (`:761-771`). Response `{ok, path, name, size}`.

After upload: a toast `Uploaded <name>` for 3000 ms, then the absolute paths are
shell-quoted and inserted into the scratchpad (if open) or the terminal with a trailing space.

The **file browser's** upload button is a separate flow: it uploads into the directory you
are viewing and refreshes the listing, and never types into the terminal
(`app/components/file-browser.tsx:362-400`).

Drag-and-drop uses a nested-element-safe `dragCounterRef` and only reacts when
`dataTransfer.types.includes("Files")`; the overlay is a dashed-border "Drop to upload"
scrim (`app/routes/sessions.$id.tsx:858-890`, `:1388-1395`).

#### 1.8.7 File viewer and file browser

**Viewer** (`app/components/file-viewer-panel.tsx`). Opens from any file link. `fixed inset-0
z-50` backdrop plus a right-anchored panel. Closes on backdrop click, the X, or `Escape`.

- **Resizable on desktop** (post-1.21.0): left-edge `role="separator"` handle,
  `FILE_VIEWER_MIN_WIDTH = 320` px to `80vw`, persisted in
  `sessionStorage["relay:fileViewerWidth"]` — one global width, written on pointerup only
  (`:392-402`, `:424-535`). Note the inconsistent key naming (`relay:` vs `relay-tty-`) and
  that it is **not** mirrored to localStorage like window-prefs keys.
- **Markdown** (`md`, `markdown`, `mdx`) opens **rendered** by default via `marked`
  (`gfm: true, breaks: true`); YAML frontmatter is parsed, `title` becomes an `<h1>`
  (`:543-615`).
- **HTML** (post-1.21.0) renders in an iframe via `srcDoc` with
  `sandbox="allow-scripts allow-popups allow-forms allow-modals"` — deliberately **no
  `allow-same-origin`**, so the frame has an opaque origin and its scripts cannot reach the
  app's DOM, cookies or storage. Relative sibling assets therefore don't load; the source
  toggle covers that (`:619-641`).
- Images / video / audio / PDF get native elements; everything else is CodeMirror 6 with
  `oneDark`, read-only, optional line numbers (default on) and wrap, jumping to `line` via
  `scrollIntoView({y: "center"})` (`:296-334`, `:645-696`).
- **Editing** adds history + default keymap and saves via
  `PUT /api/sessions/:id/write-file {path, content}` (`:700-779`).

**Browser** (`app/components/file-browser.tsx`). `GET /api/sessions/:id/ls?path=&recursive=1`.
Filters `{showFiles, showDirs, showHidden, recursive}` persisted in
`localStorage["relay-tty:file-browser-filters"]`, each with a live count. Name filter is a
**case-insensitive regex** falling back to substring on a compile error (`:285-294`). Sort by
name / size / mtime, same field re-selected flips direction, **directories always first**
(`:296-314`). Breadcrumbs abbreviate `$HOME` to `~` and offer an upload-dir shortcut.
Context menu — right-click or **500 ms long-press** — offers **Copy absolute path**
(shell-quoted), **Copy filename** (shell-quoted), and **Download** (`:764-820`, `:317-357`).
`Escape` cascades: viewed file → context menu → the whole browser.

#### 1.8.8 Chat mode

An alternative renderer toggled from the info panel, persisted in `relay-tty-viewmode`
(`app/components/chat-terminal.tsx`, `app/routes/sessions.$id.tsx:64-75`). Segments output
into turns using, in tiers: `\x1b]1337;RemoteHost=` (iTerm2), OSC 133 A/B/C/D (FinalTerm),
then a heuristic prompt regex (`app/lib/ansi.ts:144-330`). Sessions that emit
`\x1b[?1049h` or `\x1b[2J` are added to `tuiSessions` and **force terminal mode**
regardless of preference (`app/routes/sessions.$id.tsx:685-688`). Both renderers stay
mounted, so toggling is instant with no reconnect. **Plain Enter sends** here — the opposite
of the scratchpad. A Ctrl+C button appears while a turn runs.

---

### 1.9 Sharing, pairing, and remote access

#### 1.9.1 Share links

`POST /api/sessions/:id/share` (`server/api.ts:167-210`).
`ttl = clamp(parseInt(body.ttl) || 3600, 60, 86400)` — **min 60 s, max 24 h, default 1 h**.
`password` may be a string (hashed server-side), `true` (use the global relay password), or
falsy. Returns `{token, url, expiresIn, passwordProtected}`. The base URL prefers `APP_URL`
over the request host, because the CLI hits localhost and a localhost URL is useless to share.

Token shapes (`server/auth.ts`): plain tokens are HS256 over `JWT_SECRET` with
`{iss: "relay-tty", sub: sessionId, scope: "share:read", exp}` (`:157-166`). Password tokens
are signed with the **derived secret `JWT_SECRET + sha256(password)`** plus `pwd: true`, so
the token is cryptographically unverifiable without the password (`:222-238`).
`verifyShareToken` explicitly refuses `pwd:true` tokens (`:179-183`); `peekJwtPayload`
decodes without verifying so the UI can decide whether to prompt (`:280-288`).

**Dialog** (`app/components/share-dialog.tsx`): TTL options **5 min / 15 min / 1 hour
(default) / 6 hours / 24 hours** (`:5-11`); optional password with a confirm field; on
success a **QR code** via dynamic `import("qrcode")` at 256 px with
`{dark: "#e2e8f0", light: "#0a0a0f"}` (`:56-63`), plus copy-to-clipboard.

**Read-only enforcement is server-side.** For `/ws/share` connections the handler forwards
**only** `RESUME` to pty-host and answers `PING` locally; `DATA`, `RESIZE` and everything
else are silently dropped (`server/ws-handler.ts:324-338`). The viewer page shows a fixed
header with a `read-only` badge and renders `ReadOnlyTerminal`. Share auth failures are
reported as **WebSocket close codes after a successful upgrade** — `4001 password-required`,
`4001 wrong-password`, `4001 invalid-or-expired`, `4004 session-not-found` (`:212-239`).

A share viewer **cannot** reach any `/api/*` route; the token is accepted only at
`/ws/share`.

**There is no revocation endpoint.** A share token is a stateless JWT that dies at `exp`.
The only levers are waiting it out, rotating `JWT_SECRET`, or (for password tokens) changing
the password, which changes the derived secret.

#### 1.9.2 Device pairing (post-1.21.0)

`server/pair-store.ts`, entirely **in-memory** — nothing is persisted.

| Parameter | Value | Cite |
|---|---|---|
| Code | 6 digits, `randomInt(0, 1_000_000)` zero-padded, up to 10 collision retries | `:35-50` |
| Code TTL | **5 min**, single-use (deleted on redeem) | `:3`, `:77` |
| Grant idle expiry | **30 min** since `lastSeen`, refreshed on every use | `:4`, `:93-103` |
| Redeem rate limit | **5 attempts per IP per 60 s** → `429 rate-limited` | `:52-68` |
| Grant id | `randomBytes(32).toString("hex")` | `:78` |
| Sweep | every 60 s | `:132-149` |

Cookie: `relay_grant=<grantId>.<HMAC-SHA256(grantId, JWT_SECRET) base64url>; HttpOnly;
SameSite=Lax; Path=/; Max-Age=7200`. The cookie's 2 h life is longer than the 30 min
server-side idle expiry; the shorter one wins.

**Guest scope** (`server/auth.ts:374-392`): `/api/pair/logout` and `/api/pair/whoami`
unconditionally, plus any path whose session id equals the grant's — matched from
`/sessions/:id`, `/ws/sessions/:id`, `/api/sessions/:id/*`. A grant is **not** owner status
(`:322-330`), so guests get `403` on kill, pair-minting and grant listing, and `/ws/desktop`
is unreachable. The session page hides Share, Pair and Kill for guests
(`app/routes/sessions.$id.tsx:1222-1228`).

Host UI (`app/components/pair-host-dialog.tsx`): mints on open, renders the code as
`XXX XXX` at 4xl `select-all`, live `M:SS` countdown that clears at zero, copy button,
polls `GET /api/sessions/:id/grants` **every 5 s** showing `ip · since <time>`, and an X per
guest calling `DELETE /api/sessions/:id/grants/:grantId` to kick.

Guest UI (`app/routes/pair.tsx`): numeric input, strips non-digits, caps at 6,
**auto-submits at 6 digits**, `autoComplete="one-time-code"`.

#### 1.9.3 Auth

`JWT_SECRET` is the master switch — **if it is empty, everything is open**
(`server/auth.ts:326`, `:341-344`, `:429`).

`authMiddleware` order (`server/auth.ts:335-416`): localhost → no secret → `/api/auth/callback`
→ `/share/*` → `/pair` or `/api/pair/redeem` → valid `session` cookie → valid `relay_grant`
with matching scope → `401` for `/api/*` and `/ws/*` → assets pass → `401` HTML page.

`isLocalhost` (`:57-76`) requires the IP to be loopback **and** neither `cf-connecting-ip`
nor `x-relay-tunnel` to be present, because cloudflared and the tunnel client both run
locally. An explicit warning at `:44-51` says not to enable Express `trust proxy` without
reworking this.

Login flow: the server prints `<base>/api/auth/callback?token=<jwt>` (no `exp`) and, when
`APP_URL` is set, a terminal QR for a 24 h token (`server.js:196-222`). Visiting it exchanges
the token for a **30-day** `session` cookie and redirects to a validated same-origin `next`
(`server.js:96-111`).

#### 1.9.4 Tunnels

`server/tunnel-client.ts` is a cloudflared-style reverse proxy: one outbound WebSocket to
`wss://relaytty.com/ws/tunnel`, multiplexing HTTP and WS by `clientId`. Public URL is
`https://<slug>.<tunnelHost>`, except `*.workers.dev` hosts which become
`https://<host>/t/<slug>` (`:80-85`). HTTP proxying injects `x-relay-tunnel: 1`, strips all
`cf-*` headers, and uses `redirect: "manual"` so the auth callback's 302 + `Set-Cookie`
survives (`:169-242`). WS proxying forwards **only the path** — no headers, no cookies —
which is exactly why `x-relay-tunnel` is deliberately omitted there (`:244-253`). Reconnect
backs off 1000 ms → 30 000 ms.

Browser-side connection UI (`app/components/terminal.tsx:275-334`): first connect shows
"Connecting" immediately; **reconnects are delayed 1500 ms** so brief hiccups stay invisible;
the label becomes `Reconnecting (n)` past 2 retries; at 5 retries the corner pill is replaced
by a centred banner "Waiting for server connection / Will reconnect automatically". Stream
reconnect policy: base 1000 ms, max 15 000 ms, factor 1.5; heartbeat every 10 s with a 45 s
zombie timeout (`app/lib/browser-stream.ts:10-12`). `visibilitychange → visible` and
`online` both call `reconnectNow()` because mobile browsers suspend backoff timers.

#### 1.9.5 Remote desktop `/desktop` (post-1.21.0)

A byte-for-byte WebSocket↔TCP bridge to `127.0.0.1:5900` (`RELAY_VNC_PORT` overrides),
**owner-only** — guest grants and share links cannot reach it (`server/desktop.ts:22-23`,
`server/ws-handler.ts:184-193`). Availability is a TCP probe with a 500 ms timeout, cached
15 s (`server/desktop.ts:28-70`).

noVNC is lazily imported. Features: a **display picker** (shown only when ≥2 displays whose
max edges exactly equal the framebuffer), **Fit ↔ 1:1 pan**, a **minimap** (160 px, redrawn
at 4 Hz, viewport rect stroked `#E85D00`), a **frame-rate cap** cycling `5 → 10 → 20 → max`
(default 5, persisted) implemented by wrapping `RFB.messages.fbUpdateRequest` to coalesce
incremental requests, **clipboard both ways**, a **mobile keyboard** toggle backed by a hidden
textarea that translates to X11 keysyms, and a reconnect flow. The macOS password is never
stored; the username is (`relay-desktop-username`).

#### 1.9.6 PWA

`public/manifest.webmanifest`: `display: "standalone"`, theme `#1d232a`, SVG icons.
`public/sw.js` caches `/offline.html` on install and serves it for failed navigations
(`:1-20`). The service worker is registered inline in `app/root.tsx:51-55`.
`app/components/ios-homescreen-banner.tsx` shows an install prompt only when **all** of:
not dismissed, iOS device, not standalone, Safari (not CriOS/FxiOS/EdgiOS/OPiOS), and
`typeof Notification === "undefined"`.

#### 1.9.7 Multi-machine

`--host`/`-H <url>` exists on the CLI (`tui`, `list`, `kill`, `rename`, `send`, `wait`,
`events`, `share`, `stop`, `run`). **Creating** sessions on a remote host is not supported.
`shared/client/directory-remote.ts` lists over `GET /api/sessions` and subscribes to
`/ws/events`. **The web client has no multi-machine UI** — a browser talks to exactly one
`relay server`.

---

### 1.10 Settings

`app/routes/settings.tsx`, five cards, 2-column grid at `lg`.

| Setting | Control | Default | Storage | Cite |
|---|---|---|---|---|
| Quick Launch Commands | 5-row textarea, one per line, `#` comments stripped | empty | `~/.relay-tty/commands.txt` via `GET/PUT /api/commands` | `:210-259` |
| Project Roots | 10-row textarea, raw file including comments | seeded `~/code`, `~/projects`, … (existing ones uncommented) | `~/.relay-tty/project-roots.txt` | `:262-311` |
| Ctrl Shortcuts | 6-row textarea `"<LETTER> <label>"`, plus Reset | the 10 defaults in §1.8.2 | `localStorage["relay-tty-ctrl-shortcuts"]` | `:314-361` |
| Upload Directory | single-line input; writing the default or empty **deletes** the override | `~/.relay-tty/uploads` | `~/.relay-tty/upload-dir.txt` | `:364-412` |
| Smart Notifications ×4 | toggles; each also calls `syncPushTriggers()` | see §1.7.4 | `localStorage["relay-tty-notif-settings"]` | `:416-507` |

A banner warns when `Notification.permission` is neither granted nor unsupported: "System
notifications are not enabled. Grant permission in a session view first."

#### Complete storage-key index

`app/lib/window-prefs.ts` is the key mechanism to understand: **`getWindowPref` reads
`sessionStorage` first and falls back to `localStorage` on first access in a new window;
`setWindowPref` writes BOTH.** This makes layout preferences per-window while still seeding
new windows sensibly (`:12-25`).

| Key | Mechanism | Default |
|---|---|---|
| `relay-tty-sort` / `relay-tty-sort-dir` | window-prefs | `recent` / `desc` |
| `relay-tty-show-inactive` | window-prefs | `false` |
| `relay-tty:session-filters` | window-prefs, JSON | `{showRunning:true, showClosed:false}` |
| `relay-tty-sidebar-view` | window-prefs | `list` |
| `relay-tty-sidebar-collapsed` | window-prefs | `false` |
| `relay-tty-sidebar-width` | window-prefs | `288` (200–600) |
| `relay-tty-fontsize-<id>` | window-prefs | 14 session / 12 grid-lanes |
| `relay-tty-viewmode` | window-prefs | `terminal` |
| `relay-tty-lane-width` / `-height` | window-prefs | `480` / `800` |
| `relay-tty-tile-layout` / `-dismissed` / `-column-widths` | window-prefs | — |
| `relay-tty-tile-sort` / `-sort-dir` / `-show-inactive` / `-fontsize-<id>` | window-prefs | `recent` / `desc` / `false` / 14 |
| `relay-tty-perf-hud` | window-prefs | `0` |
| `relay-tty-project-filter` | **plain localStorage**, JSON array | `[]` |
| `relay-tty-recency-filter` | **plain localStorage**, JSON | `{enabled:false, duration:"24h"}` |
| `relay-tty-ctrl-shortcuts` | plain localStorage | 10 defaults |
| `relay-tty-notif-settings` / `relay-tty-notif-<id>` | plain localStorage | §1.7.4 |
| `relay-tty-ios-homescreen-dismissed` | plain localStorage | unset |
| `relay-tty:file-browser-filters` | plain localStorage | all true, recursive false |
| `relay:fileViewerWidth` | **sessionStorage only** | `0.4–0.5 × vw` |
| `relay-desktop-display` / `-fps` / `-username` | **plain localStorage** | unset / `5` / unset |
| `relay-tty-buffer-cache` | IndexedDB | — |
| Group collapse state | **NOT PERSISTED** — in-memory Set | all expanded |

---

### 1.11 Keyboard shortcuts — complete

**Read this first.** Three registration styles behave very differently:

- **Capture on `document` + `stopPropagation()`** → fires before xterm's handler. Genuinely
  swallowed; the PTY never sees it.
- **Bubble on `document`/`window`** → fires *after* xterm already ran `term.input()`.
  `preventDefault()` stops the browser default but **cannot un-send** bytes xterm queued.
- **`attachCustomKeyEventHandler`** returning `false` → fully suppresses xterm.

| Combo | Action | Routes | Swallowed? | Cite |
|---|---|---|---|---|
| **Shift+Enter** | Sends `CSI 13;2u` instead of `\r` | every interactive terminal | **Yes** — handler returns `false` for all event types | `app/hooks/use-terminal-input.ts:44-58` |
| **Cmd+Shift+N** / **Ctrl+Shift+N** | New `$SHELL` session in the current cwd, then navigate | `/`, `/activity`, `/grid`, `/lanes`, `/sessions/:id` | **Yes** — capture + `stopPropagation` | `app/hooks/use-new-session-shortcut.ts:39-49` |
| **Cmd+Shift+N** / **Ctrl+Shift+N** | New session as a leftmost column; **does not navigate** | `/tiles` | Yes | `app/routes/tiles.tsx:590-595` |
| **Cmd+D** (Mac only by design) | New column after the focused pane | `/tiles` | Yes | `app/routes/tiles.tsx:579-586` |
| **Cmd+Shift+D** | Stack a new pane below the focused one | `/tiles` | Yes | `app/routes/tiles.tsx:579-585` |
| **Cmd+K** (Mac) / **Ctrl+Shift+K** | Clear scrollback, client + server + caches | `/sessions/:id` | **Partly.** Bubble on `window`. Mac Cmd+K is effectively swallowed (xterm ignores meta); **non-Mac Ctrl+Shift+K very likely also delivers `0x0B` to the PTY** | `app/routes/sessions.$id.tsx:387-393` |
| **Ctrl+Shift+F** | Toggle terminal search. No Cmd variant exists | `/sessions/:id` | **No** — bubble on `window`; **the PTY likely also receives `0x06`** | `app/routes/sessions.$id.tsx:382-385` |
| **Cmd/Ctrl + `=` `+`** | Font size +1 | `/sessions/:id` (clamp 8–28), `/grid`, `/lanes` (4–28, target `zoomed ?? selected`), `/tiles` (8–28, focused pane) | Bubble; `preventDefault` blocks browser zoom. Tiles' branch is capture but **without** `stopPropagation` | `:394-402`, `grid.tsx:683-695`, `lanes.tsx:592-604`, `tiles.tsx:597-605` |
| **Cmd/Ctrl + `-` `_`** | Font size −1 | same | same | same |
| **Escape** | Unzoom first, then deselect | `/grid`, `/lanes` | Bubble; **explicitly passes through** when `e.target` has class `xterm-helper-textarea` | `grid.tsx:663-678`, `lanes.tsx:572-587` |
| **Escape** | Close the session modal | grid/lanes modal | Same xterm guard | `app/components/session-modal.tsx:99-111` |
| **Escape** | Close the file viewer | any route | **No xterm guard** — closes even when the terminal has focus, and the PTY still gets `\x1b` | `app/components/file-viewer-panel.tsx:456-465` |
| **Escape** | Cascade: viewed file → context menu → browser | file browser | **No xterm guard** | `app/components/file-browser.tsx:217-232` |
| **Escape** / **Enter** / **Shift+Enter** | Close search / next match / previous match | search input | React `onKeyDown` | `app/components/search-bar.tsx:66-78` |
| **Cmd+Enter** / **Ctrl+Enter** | Send the scratchpad (plain Enter = newline) | mobile scratchpad | `preventDefault` | `app/components/session-mobile-toolbar.tsx:250` |
| **Enter** | Send the chat command | chat mode | `preventDefault` | `app/components/chat-terminal.tsx:414-418` |
| **Enter** | Commit the recency duration and blur | project filter | `preventDefault` | `app/components/project-filter.tsx:285-291` |
| **Ctrl+Shift+`` ` ``** | Toggle the perf HUD | wherever `<PerfHud/>` is mounted (`/grid`, `/lanes`) | Bubble, `preventDefault` | `app/components/perf-hud.tsx:51-61` |
| **Pinch (2 fingers)** | Font size ±2 per 30 px | any touch terminal | Yes, `passive:false` | `use-terminal-core.ts:963-1012` |

**Not bound to anything:** layout switching, fullscreen, sidebar collapse, sort, filters,
closing a tile pane, killing a session, copy (auto-copy covers it), rename.

`Cmd+N` is deliberately unused — browser-reserved and not interceptable
(`app/hooks/use-new-session-shortcut.ts:8-10`).

---

### 1.12 Verified absences

Things a reader might reasonably assume exist. They do not.

| Absent | Evidence |
|---|---|
| **Rename from the web** | No input, menu item or double-click-to-rename anywhere in `app/`. CLI/TUI only. |
| **Text search over the session list** | No search input in the sidebar or the session picker. |
| **Restart / archive a session** | No endpoint, no UI. |
| **Sending signals from the browser** | `sendSignal` has no callers in `app/`. |
| **Detach / observe from the browser** | `sendDetach`, `encodeObserve` have no callers in `app/`. |
| **Column-count control (2-col / 3-col)** | Does not exist in any view. |
| **Context menu or swipe on a session row** | No `onContextMenu` in the sidebar. |
| **Kill from the sidebar** | Only the session page, tile menu, or expand modal. |
| **Persisted group collapse** | In-memory only. |
| **Share revocation** | Stateless JWT; no endpoint. |
| **Voice input UI** | See §1.14. `useSpeechRecognition` is complete but **imported by nothing**. |
| **Error UI when session creation fails** | `createSession` throws uncaught after `res.text()` (`app/components/sidebar-drawer.tsx:312`). |
| **Multi-machine in the browser** | A browser talks to one server. |

---

### 1.13 Security holes — do not port

These are real and reachable by any authenticated user, including a paired guest scoped to
that session.

1. `PUT /api/sessions/:id/write-file` resolves against `session.cwd` with **no traversal
   guard** — unlike the read route (`server/api.ts:549-552`) and the exists route
   (`:480-486`). `{"path": "../../../etc/x"}` writes outside the session directory
   (`server/api.ts:412-433`).
2. `GET /api/sessions/:id/files/*?abs=1` grants **full-filesystem read** to anyone past the
   middleware (`server/api.ts:517-529`).
3. `POST /api/upload` honours an arbitrary absolute `X-Upload-Dir` (`server/api.ts:728-745`).
4. `POST /api/notifications` stores whatever `sessionId`/`sessionName` the caller sends,
   unauthenticated as to those fields (`server/api.ts:805-822`).

---

### 1.14 UNVERIFIED / documentation-only claims

Claims in `docs/content` or `README.md` that could not be confirmed in source.

| Claim | Where | Finding |
|---|---|---|
| **Voice input** — "Tap the microphone icon in the mobile toolbar", Web Speech API dictation | `docs/content/how-to/voice-input.mdx` (a whole page), `how-to/index.mdx`, `reference/keyboard-shortcuts.mdx`, `docs/content/index.mdx`, README tech stack | **UNVERIFIED — almost certainly absent.** `rg "\bMic\b\|Microphone"` over `app/` returns zero hits, and `app/hooks/use-speech-recognition.ts` is imported by nothing. An entire how-to page documents a UI that is not rendered. |
| Scratchpad has "autocomplete and autocorrect" | `how-to/input-tools.mdx` | **Contradicted.** The textarea sets `autoCorrect="off" autoCapitalize="off" spellCheck={false}` (`app/components/session-mobile-toolbar.tsx:253-261`). |
| Scratchpad sends on **Enter** | `how-to/input-tools.mdx` | **Wrong.** Plain Enter inserts a newline; only `Cmd/Ctrl+Enter` sends (`:250`). |
| Mobile toolbar has Search / Microphone / Share icons | `reference/keyboard-shortcuts.mdx` | **Wrong.** Only Folder is in the toolbar. Search and Upload are in the session **header**; Share is in the info panel. |
| Settings: "long-press [Ctrl] for sticky modifier" | `app/routes/settings.tsx:320` (in-app copy) | **No long-press handler exists.** A plain tap sets sticky *and* opens the menu (`session-mobile-toolbar.tsx:186-195`). |
| Layout switcher toggles "Home, **Agents**, Grid, and Lanes" | `how-to/web-ui-views.mdx` | **Stale.** The route is `/activity`, labelled "Activity", and **Tiles is omitted entirely** despite being a first-class view. |
| `Cmd+Shift+N` works in "All Views" | `reference/keyboard-shortcuts.mdx` | **Wrong.** Not active on `/settings`, `/desktop`, `/share/:token`, `/pair`. |
| Font size "shared across all views" | `how-to/web-ui-views.mdx` | The **key** is shared; the **default** is 14 in the session view and 12 in grid/lanes. |
| Font shortcuts are Mac-only (`Cmd+=`) | `reference/keyboard-shortcuts.mdx` | All four implementations accept `Ctrl` too. |
| `Cmd+D` / `Cmd+Shift+D` | Referenced in passing prose in `web-ui-views.mdx:74` | **Never defined** in the shortcut reference. |

Also entirely undocumented but shipped: chat mode, the tiles view, the perf HUD, the mobile
swipe carousel, text-selection mode, the shared clipboard panel, the whole push-notification
UI, in-viewer file editing, media preview, the resize wand, the iOS home-screen banner, the
WebGL budget, and markdown-link detection in terminal output.

---

## 2. The daily-driver subset, ranked

What Scott would notice missing **within a day** of running ~10 concurrent Claude Code
sessions across several projects in `/tiles` with the sidebar open. Ranked by how fast the
absence bites.

| # | Capability | Why it bites within a day |
|---|---|---|
| 1 | **Agent state — `blocked` chip + blocked-first `active` sort** (§3) | This is the entire reason to glance at the screen; without it, supervising ten agents means eyeballing ten terminals in rotation to find the one asking permission. |
| 2 | **`/tiles`: N fully interactive panes in pixel-width columns** | The screenshot *is* this view. Grid and lanes are read-only thumbnails; tiles is the only place he can watch three agents and type into any of them without switching context. |
| 3 | **Live sidebar grouped by cwd, with per-group running counts** | It is the permanent left third of the window and his only index of "what is running where" across five projects — the group header count answers that at a glance. |
| 4 | **Instant session switching: delta resume + IndexedDB cache + cache-first paint** | Ten sessions × up to 10 MB of scrollback. Without the cached-first-then-delta path, every switch is a multi-second replay, and he switches constantly. |
| 5 | **Cmd+D / Cmd+Shift+D splits and header drag-and-drop** | How those three columns came to exist and get rearranged as work moves between projects; doing it by dragging windows is the thing the app exists to replace. |
| 6 | **Clickable file paths → in-app viewer resolved on the host** (incl. bare filenames + existence gate) | Agents emit `foo.ts:42:10` and `package.json` constantly; this closes the read-what-they-cite loop without leaving the workspace. The existence gate is what stops it being noise. |
| 7 | **New session inheriting the focused session's cwd** (`Cmd+Shift+N`, `+ New session in this project`, `Cmd+D`) | Starting work in the right project is the most frequent action after reading; typing `cd` ten times a day is exactly the friction being removed. |
| 8 | **Throughput readout + `idle`/rate per row, and the pulsing activity dot** | The cheap "is it moving?" signal that stops him opening a session just to check; the dot's three states encode running-and-busy vs running-and-quiet vs dead. |
| 9 | **Auto-copy on selection + "Copied" toast** | Invisible until gone. He selects output and pastes it elsewhere dozens of times a day and never presses a copy key. |
| 10 | **Clear scrollback (`Cmd+K`) that frees the server ring buffer and purges the cache** | Ten sessions × 10 MB ring buffers; a clear that only wipes the view leaves every reopen slow, which he'd feel by the afternoon. |
| 11 | **Per-session font size with the don't-reflow-others discipline** | Three columns at different widths need different sizes; the rule that resizing nudges *rows not columns* is what stops it corrupting the wrap on his other devices. |
| 12 | **"Agent blocked" push notification** | The away-from-desk half of #1. Without it, stepping away means coming back to an agent that stalled 20 minutes ago waiting for a y/n. |
| 13 | **Project filter + "Recent only" window** | At ten sessions across five projects the gallery and the sidebar are past the point where everything fits; this is how he narrows to today's work. |
| 14 | **Terminal search (`Ctrl+Shift+F`)** | Finding the error in 100 000 lines of agent output. Used less often than the above, but nothing substitutes for it when needed. |
| 15 | **Sort with stable tie-breakers and spinner-stripping `nameKey`** | Only noticed as an absence: without it, rows jitter every frame while agents animate braille spinners, which makes the list unusable for clicking. |
| 16 | **Session info panel actions (kill, clear, share, pair, per-session notification toggles)** | The per-session control surface. Kill is the only one he'd reach for daily; the rest are weekly. |
| 17 | **The resize wand** | Specifically for Ink/Claude Code frames that corrupt on reattach. Not daily, but when it happens the session is unusable without it. |

**Below the line** — real capabilities he would *not* miss in a day: chat mode, share links,
device pairing, the VNC desktop, the mobile carousel and scratchpad and Ctrl menu, the PWA,
the file browser, the perf HUD, and the whole notification-history panel. These matter for
RelayTTY's remote-access premise, which Max Pane does not share (§4).

---

## 3. Agent-state heuristic — exact

**This is the single most valuable thing RelayTTY does and it must be reproduced exactly.**

### 3.1 Where it lives

The classifier is **Rust, in pty-host**: `crates/pty-host/src/agent_state.rs`. The TypeScript
file `shared/client/agent-state.ts` contains **no classification logic at all** — only the
type, the rank function and the label function. Any client reading session JSON gets the
state for free; do not re-implement the classifier.

```rust
// crates/pty-host/src/agent_state.rs:11-17
pub enum AgentState { Working, Blocked, Done, Idle, Unknown }   // serde: lowercase
```

Serialized into session metadata as `agentState`, with `agentStateChangedAt` (epoch ms)
alongside (`shared/types.ts:33-36`).

### 3.2 When it runs

Once per second, in the metrics task, **before** the throughput broadcast
(`crates/pty-host/src/main.rs:2094-2149`). `METRICS_INTERVAL_MS = 1_000` (`:62`).

Inputs are gathered as follows:

| Input | How it is obtained | Cite |
|---|---|---|
| `foreground_process` | `libc::tcgetpgrp(master_fd)`; if the pgrp is > 0 **and differs from the child pid**, resolve it to a name — macOS `libc::proc_name()`, Linux `/proc/<pid>/comm`. Otherwise `None`. Two cheap syscalls, taken **outside** the lock | `main.rs:2104-2109`, `:1050-1079` |
| `bps1` | 1-minute rolling bytes/sec | `main.rs:2121` |
| `tail` | `strip_ansi(output_buffer.tail(AGENT_TAIL_BYTES))` where `AGENT_TAIL_BYTES = 4096`. `tail()` returns the **alt-screen buffer** when in alt screen, otherwise the ring's linearised tail. The caller may start mid-sequence | `main.rs:64`, `:443-458`, `:2135` |
| `clients_attached` | Count of attached clients. **`OBSERVE`-mode connections are deliberately not counted** | `main.rs:2140`, `:2337-2339` |
| `previous` | The last computed state | `main.rs:2141` |

On a change: `agent_state_changed_at = now_millis()` and the metadata JSON is written
**immediately and atomically**, not at the 5 s flush, so `relay wait` and the push trigger
see it at once (`main.rs:2143-2149`).

### 3.3 `strip_ansi`

`crates/pty-host/src/agent_state.rs:118-166`. Drops escape sequences and C0 controls except
`\n` and `\t`, so the pattern tables match visible text only. Lossy on invalid UTF-8.

| Sequence | Consumed |
|---|---|
| `ESC [` (CSI) | parameters/intermediates `0x20..=0x3f`, terminated by a final byte `0x40..=0x7e` |
| `ESC ]` / `P` / `_` / `^` / `X` (OSC/DCS/APC/PM/SOS) | until `BEL` (`0x07`) or `ESC \` |
| `ESC (` `)` `*` `+` `#` `%` | one more byte |
| anything else after ESC | two bytes total |
| bytes `< 0x20` other than `\n`/`\t` | dropped (so `\r` disappears) |

Tested: `"\x1b[31mred\x1b[0m ok"` → `"red ok"`;
`"\x1b]0;title\x07line\r\n\x1b]7;file:///tmp\x1b\\next"` → `"line\nnext"`;
`"\x1b[1m❯ 1. Yes\x1b[0m"` → `"❯ 1. Yes"` (`:189-204`).

### 3.4 Agent recognition

```rust
// agent_state.rs:29-41
const KNOWN_AGENTS: &[&str] = &[
    "claude", "codex", "cursor", "cursor-agent", "opencode",
    "aider", "gemini", "copilot", "goose", "amp", "grok",
];
```

`is_known_agent(process)` takes the **basename** (`process.rsplit('/').next()`), compares
case-insensitively against the list, **or** accepts a bare semver name (`:66-80`):

```rust
/// Claude Code's native binary reports its comm name as its version ("2.1.266"),
/// so a bare MAJOR.MINOR.PATCH name is treated as Claude Code.
fn is_semver_name(name: &str) -> bool   // exactly three dot-separated, all-ASCII-digit parts
```

Accepts `2.1.266` and `/opt/claude/versions/2.1.266`. Rejects `2.1`, `2.1.266.1`, `2.x.1`,
`v2.1.266`. Also rejects `claudette` (exact basename match, not substring) (`:207-231`).

> This semver rule is load-bearing for Scott: current Claude Code builds report their comm
> name as the version string. Without it every Claude session classifies as `Unknown`.

### 3.5 Pattern tables

```rust
// agent_state.rs:44-55 — tail substrings meaning the agent is waiting on the user
const BLOCKED_PATTERNS: &[&str] = &[
    "Do you want to proceed",
    "Allow",
    "(y/n)",
    "[Y/n]",
    "Yes, and don't ask again",
    "❯ 1. Yes",
    "Continue?",
    "Approve",
    "Waiting for your input",
    "Press Enter",
];

// :58 — tail substrings meaning it is busy even with no recent output
const WORKING_PATTERNS: &[&str] = &["esc to interrupt", "Thinking", "Running"];

// :61 — braille spinner glyphs used by ink/ora style progress indicators
const SPINNER_GLYPHS: &[char] = &['⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'];

// :64 — throughput at or above which a known agent counts as working
const WORKING_BPS1: f64 = 1.0;
```

Matching is plain **case-sensitive substring** containment, in table order.

### 3.6 The rules, in order

`classify(obs)` — `crates/pty-host/src/agent_state.rs:82-113`, reproduced exactly:

```rust
pub fn classify(obs: &Observation) -> AgentState {
    // Rule 1: nothing in the foreground is the shell prompt; anything we do
    // not recognize gets no guess at all.
    let Some(process) = obs.foreground_process else {
        return AgentState::Idle;
    };
    if !is_known_agent(process) {
        return AgentState::Unknown;
    }

    // Rule 2: a prompt on screen beats everything, including throughput,
    // because bps1 stays non-zero for a minute after the prompt was drawn.
    if BLOCKED_PATTERNS.iter().any(|p| obs.tail.contains(p)) {
        return AgentState::Blocked;
    }

    // Rule 3: recent output or a spinner means it is still going.
    if obs.bps1 >= WORKING_BPS1
        || WORKING_PATTERNS.iter().any(|p| obs.tail.contains(p))
        || obs.tail.chars().any(|c| SPINNER_GLYPHS.contains(&c))
    {
        return AgentState::Working;
    }

    // Rule 4: settled. Done is only meaningful while nobody is watching and
    // clears the first time someone attaches.
    match (obs.previous, obs.clients_attached) {
        (AgentState::Working, 0) => AgentState::Done,
        (AgentState::Done, n) if n > 0 => AgentState::Idle,
        (AgentState::Done, _) => AgentState::Done,
        _ => AgentState::Idle,
    }
}
```

In prose:

| Rule | Condition | Result |
|---|---|---|
| 1a | No foreground process (the shell itself is in front) | `Idle` |
| 1b | Foreground process is not a known agent | `Unknown` — **no guess at all** |
| 2 | Tail contains any `BLOCKED_PATTERNS` entry | `Blocked` — **wins over everything, including high throughput** |
| 3 | `bps1 >= 1.0` **or** tail contains a `WORKING_PATTERNS` entry **or** tail contains any spinner glyph | `Working` |
| 4a | `previous == Working` and `clients_attached == 0` | `Done` |
| 4b | `previous == Done` and `clients_attached > 0` | `Idle` |
| 4c | `previous == Done` and `clients_attached == 0` | `Done` (sticky) |
| 4d | anything else | `Idle` |

Rule 2's precedence is deliberate and explained in the source comment: `bps1` stays non-zero
for up to a minute after the prompt was drawn, so throughput alone would keep a blocked agent
looking busy.

Rule 4 makes `Done` a **notification state, not a display state** — it exists only while
nobody is watching, and self-clears to `Idle` the first time a client attaches. Note that
`OBSERVE`-mode connections do not count as attached, which is precisely why the server's own
session monitors use observer mode (`server/pty-manager.ts:457-466`) — otherwise the server
would permanently suppress `Done` for every session.

### 3.7 Transition graph

```
                        ┌──────────────────────────────────────────┐
   no fg process ──────▶│                  Idle                     │◀──── rule 4d
                        └──┬────────────────────────────▲──────────┘
                           │ bps1≥1 / working pattern   │ previous=Done
                           │ / spinner glyph            │ AND a client attaches
                           ▼                            │
                        ┌──────────┐               ┌────┴─────┐
                        │ Working  │──────────────▶│   Done   │─┐
                        └──┬───────┘  settles with └──────────┘ │ stays Done
                           │          0 clients                 │ while unattached
   blocked pattern in tail │                                    └────┘
   (beats everything)      ▼
                        ┌──────────┐
                        │ Blocked  │   ← reachable from ANY state in one tick
                        └──────────┘

   fg process not recognized ────▶ Unknown   (terminal for that process; no guess)
```

Every tick is independent: `Blocked` is entered whenever the pattern is on screen and left
the moment it scrolls out of the 4 KB tail. There is no hysteresis and no debounce.

### 3.8 What the UI does per state

| State | Rank | Chip | Chip colours | Push |
|---|---|---|---|---|
| `blocked` | **0** | `BLOCKED` | `border-[#E85D00] text-[#E85D00]` (Signal Orange) | **`agentBlocked` fires, default ON** |
| `working` | 1 | `WORKING` | `border-[#22c55e]/60 text-[#22c55e]` | — |
| `done` | 2 | `DONE` | `border-[#94a3b8]/60 text-[#94a3b8]` | — |
| `idle` | 3 | *(nothing)* | — | — |
| `unknown` / undefined | 4 | *(nothing)* | — | — |

`shared/client/agent-state.ts:11-29`, `app/components/agent-state-chip.tsx:4-8`.

The chip is a **square** `border px-1 text-[10px] leading-4 font-mono tracking-wider` span
with `title="Agent state: <state>"` — no border-radius (`agent-state-chip.tsx:19-20`).
`agentStateLabel` returns `""` for idle and unknown, and the component returns `null` on an
empty label, "so ordinary shells stay visually quiet" (`:10-16`).

Surfaces that render it:

- Sidebar list rows, running only (`app/components/sidebar-drawer.tsx:124`).
- `/activity` full agent cards, running only (`app/components/agent-card.tsx:147`).
- `app/components/session-card.tsx:63` — but that component is dead code.
- **Not** on sidebar *cards* view, and **not** in the tile pane header.

`agentStateRank` is used in exactly one place: level 2 of the `active` sort comparator
(`app/lib/session-groups.ts:49-50`). Selecting sort = **Active** is what makes blocked
sessions float to the top of every group.

The push side: `server/notify.ts:130-137` listens for a `session-update` whose **changed
fields** contain `agentState === "blocked"` — so it fires once per transition, not once per
tick — and sends `"<who> is waiting for input"`, where `who` is the foreground process name
unless it matches `/^\d+\.\d+\.\d+$/`, in which case it is replaced with the literal
`"Agent"` (so Claude Code doesn't page you as "2.1.266").

### 3.9 Reimplementation checklist

1. Sample once per second.
2. `tcgetpgrp` on the PTY master; resolve to a name only when the pgrp differs from the child
   pid; `None` otherwise.
3. Take the last **4096 bytes** — from the **alt-screen buffer** when in alt screen — and
   `strip_ansi` them.
4. Apply the four rules **in order**, exactly as written.
5. Keep `previous` and a client count that excludes observers.
6. Persist `agentState` and `agentStateChangedAt` on change, immediately.
7. Rank `blocked 0, working 1, done 2, idle 3, else 4`; render chips only for the first three.

A native Max Pane reading `~/.relay-tty/sessions/<id>.json` gets all of this for free from
the existing pty-host. Reimplementing the classifier is only necessary if Max Pane owns its
own PTYs.

---

## 4. What a native macOS app should not copy

### 4.1 Browser workarounds with no native analogue — delete on sight

| RelayTTY mechanism | Why it exists | What Max Pane should do |
|---|---|---|
| `webgl-budget.ts` — the 8-context budget with hysteresis | Browsers cap ~16 WebGL contexts per page and evict at random | Nothing. A Metal-backed SwiftTerm has no per-process context cap. **Keep the *idea*** of a frame budget across many panes (§4.2), discard the mechanism. |
| `MAX_POOL_SIZE = 8` detached xterm pool | React unmount/remount is expensive | Nothing — AppKit views are retained by the view hierarchy. |
| `buffer-cache.ts` IndexedDB, 10 MB cap, 24 h TTL | The browser cannot read the pty-host ring buffer directly | Read the ring buffer, or cache to a real file. The 10 MB cap is a mirror of the server's ring size, not a design choice. |
| `window-prefs.ts` dual sessionStorage+localStorage write | `localStorage` is shared across windows, so per-window layout leaked | `NSWindow` restorable state / per-scene `UserDefaults`. Do not invent a dual-write. |
| `--app-h`, `visualViewport` tracking, the 60 ms `focusout` revert, `interactive-widget=resizes-content` | iOS keyboard viewport bugs | Delete entirely. |
| iOS `insertCompositionText` delta reconstruction, the keydown/`beforeinput` dedupe, `PlainInput`-as-textarea (Gboard), the `16px` textarea font | Mobile browser IME bugs | Delete entirely. AppKit's `NSTextInputClient` is the correct layer. |
| `NoKbButton` (`tabIndex={-1}` + `preventDefault` everywhere) | Any focusable element raises the mobile keyboard | Use normal AppKit focus; the pattern is noise on macOS. |
| Mobile carousel swipe, scratchpad, Ctrl menu, sticky modifiers, text-selection mode | Phones have no keyboard and no right-click | Skip all of it. |
| Momentum scrolling in float line units with the `_innerRefresh`/`syncScrollArea` monkey-patch | xterm's viewport fights touch scrolling | `NSScrollView` already does this correctly. |
| `document.documentElement.requestFullscreen()` | — | Real macOS fullscreen / a dedicated Space. |
| `public/sw.js`, `manifest.webmanifest`, the iOS home-screen banner | PWA install | Delete. |
| Bubble-phase shortcut registration (§1.11) | An accident, not a design | Do not reproduce the `Ctrl+Shift+F` / `Ctrl+Shift+K` leak-to-PTY bug. Decide per shortcut whether it is swallowed, and be consistent. |

### 4.2 Ideas worth keeping even though the implementation is browser-shaped

- **A frame budget across many live panes.** `write-scheduler.ts`'s rule — one shared clock,
  4 ms and 512 KB per frame, *defer* rather than drop, rotate the start index for fairness —
  is sound engineering that applies equally to ten SwiftTerm views. Port the policy.
- **Batched metric commits.** The 1 Hz `FLUSH_MS` in `use-session-metrics.ts` exists because
  re-rendering ten sparklines several times a second stalls the main thread. That is true in
  AppKit too.
- **Deterministic thumbnail degradation.** Even without a context cap, ten full-scrollback
  terminals is not free. The *principle* — pin what the user is looking at, degrade the rest
  by recency, with hysteresis so nothing thrashes — is the right shape.
- **Dimension snapshotting so live resizes don't reflow the gallery**
  (`app/routes/grid.tsx:176-207`). This is a UX decision, not a browser workaround.
- **Sort-order snapshotting per sort key** (`grid.tsx:499-520`) and the spinner-stripping
  `nameKey` (`session-groups.ts:21-24`). Both exist because agent output is visually noisy.
  Both are needed anywhere ten agents are listed.
- **The resize-wand row-nudge** (`terminal.tsx:228-249`). Nudging *rows not columns* so other
  connected clients' wrapping isn't reflowed is a protocol-level courtesy, not a browser
  quirk. If Max Pane can ever be one of several clients on a session, keep it.
- **Shift+Enter as `CSI 13;2u`** and bracketed-paste awareness. These are terminal-protocol
  behaviours Claude Code depends on. Copy exactly.

### 4.3 Things a native app should do *differently*, not merely better

| RelayTTY | Max Pane |
|---|---|
| File links resolve on the pty-host via `POST /api/sessions/:id/exists` with a 30 s TTL cache and in-flight dedupe | The app **is** on the host. `stat()` directly. Keep the extension allowlist and the regex; drop the HTTP round-trip, the cache and the dedupe. |
| HTML preview in an opaque-origin sandboxed iframe with `srcDoc` | Keep the *discipline* — a `WKWebView` with no app-bridge, no same-origin access, and `.nonPersistent()` data store. Do not hand agent-authored HTML a privileged web view. |
| Link scheme allowlist refusing everything but `http/https/mailto/file` | Copy the allowlist, and make it stricter: never hand an arbitrary URL to `NSWorkspace.open`. The anti-spoof hover tooltip should survive as a native tooltip. |
| `GET /api/sessions/:id/files/*?abs=1` (full-filesystem read) and the unguarded `write-file` | **Do not port.** These holes exist because a browser has no filesystem. A native app has one; use it, under the user's own permissions and sandbox. |
| Share links, device pairing, tunnels, QR auth, Web Push, the JWT/cookie model | All of this exists because the client is remote and untrusted. A local app supervising local PTYs needs none of it. If remote access is wanted, the answer is "also run `relay server`", not "reimplement the auth model." |
| Notifications as OSC 9 → in-app toast → `POST /api/notifications` → service-worker push, gated on `visibilityState === "hidden"` | `UNUserNotificationCenter`, gated on app activation state. Keep the **trigger rules** verbatim (§1.7.4) — especially `agentBlocked` firing once per *transition*, not per tick — and keep the semver→"Agent" substitution. |
| `/desktop` VNC bridge | Pointless locally. |
| Agent-state classifier reimplemented client-side | Don't. Read `agentState` from `~/.relay-tty/sessions/<id>.json`, which pty-host already writes atomically on every transition. Reimplement §3 **only** if Max Pane owns its own PTYs — and then reproduce it byte for byte, including the semver rule and the observer-exclusion in rule 4. |
| `detectAgentLabel`'s six-agent list (`app/components/agent-card.tsx:87-101`) | Use the Rust `KNOWN_AGENTS` (eleven names plus semver). The web list is stale. |
| No rename UI; rename is CLI-only | A native app should just let the user rename a pane. Send `SET_TITLE` (`0x24`, empty payload unpins) — the protocol already supports it and the web client simply never wired it up. |
| No way to send signals from the client | Wire `SIGNAL` (`0x25`, one byte). A supervision app that cannot SIGINT a runaway agent is missing an obvious affordance the protocol already offers. |
| Group collapse state held in memory | Persist it. Its absence in RelayTTY is an oversight, not a decision. |
| Auto-copy on **every** selection change | Reasonable on a touch device where there is no copy key. On macOS, users expect `Cmd+C`. Consider making auto-copy opt-in, and definitely keep `Cmd+C`. |
