# Day one — could Scott actually switch?

A blind critique by a fresh-eyes critic who built none of this. Judged against
`docs/reference/relaytty-web-features.md` and `docs/bar-relaytty.png`, and
against Max Pane **driven live** on 2026-09-12 (screen unlocked, visual mode).

> **Environment caveat.** Another agent was driving the same running instance
> during this pass — a `/tmp/fakeagent/claude` fixture appeared, and a script was
> SIGTERMing sessions. Lane indices shifted mid-run. Every finding below was
> re-confirmed after that was noticed, and each is either reproduced twice or
> corroborated in source. No session that was not spawned by this critic was
> killed; all eight of Scott's live sessions were verified alive at the end.

---

## 1. The verdict

**No, he would be back by lunch** — not because of anything on the ranked
feature list, but because Max Pane has no clipboard: `⌘V` into a terminal lane
does nothing, and there is no Copy, Paste or Select All anywhere in the app.

---

## 2. THE SINGLE BIGGEST GAP

### There is no copy and no paste.

`⌘V` in a focused terminal lane inserts nothing. Verified twice by driving: with
`PASTETEST123` on the pasteboard, typing `TYPED-OK `, then `⌘V`, then ` END`
produced `TYPED-OK  END`. A second run bracketing the paste produced `A[]B` —
the brackets adjacent, nothing between them. The typed characters arrive; the
paste is silently dropped.

This is not a missing convenience feature, it is a missing hole in the app.
`AppDelegate` builds the menu bar from `MenuSection.allCases`, which is `File`,
`Navigate`, `View` — **there is no Edit menu**, and macOS does not supply one.
There is no `performKeyEquivalent` override anywhere in `swift/`. SwiftTerm's
`MacTerminalView` does implement `copy(_:)`, `paste(_:)` and `selectAll(_:)` as
responder methods (lines 2723, 2731, 2741), but with no menu item carrying the
key equivalent and no key-equivalent handler, nothing ever calls them. The only
two pasteboard writes in the entire binary are "Copy Working Directory" in the
lane overflow menu and "copy session id" in the sidebar. `clipboardCopy(source:
content:)` in `TerminalPaneController` is an empty stub, so even a host-side
OSC 52 copy is thrown away.

**When he hits it:** inside five minutes. The workflow is supervising ten Claude
Code agents. Pasting a stack trace, an error line, a file path or a URL into an
agent prompt is the single most frequent input action in that workflow, ahead of
typing prose. He will also try to select an agent's output and `⌘C` it — RelayTTY
auto-copies on selection so he has never pressed a copy key in his life, and here
neither the key nor the auto-copy exists.

**What it would take to close it:** small, and that is the frustrating part. An
`Edit` case in `MenuSection` with `copy:`/`paste:`/`selectAll:` items (nil target,
so they walk the responder chain to the focused `TerminalView`), plus wiring
`TerminalView.selectionChanged` to `NSPasteboard` for RelayTTY's auto-copy-on-
selection behaviour, plus filling in the `clipboardCopy` stub for OSC 52. Call it
an afternoon. Until it lands, nothing else on this list matters.

---

## 3. The next four

### 2. Terminal scrollback is 500 lines. RelayTTY's is 100,000.

Measured, not inferred: a lane printing 3,000 numbered lines, then 80 Page Up
presses (roughly 4,600 rows of scroll requested), bottomed out with
`SCROLLTEST LINE 2443` at the top of the viewport — about 500 lines of history
above the screen, and lines 1–2442 destroyed. The cause is
`TerminalPaneController.swift:82`, `TerminalView(frame: .zero)`, which passes no
`TerminalOptions`, so SwiftTerm's default `scrollback: 500` applies.

He hits this the first time an agent runs a test suite or a `rg` over a repo and
he scrolls up to read what it did — inside the first half hour. There is no
fallback: `RelayAttachmentAdapter.maximumReplayBytes` caps a cold attach at
256 KB so reattaching does not recover it, and the app has no in-terminal find
(see #4), no "view all text", and no export. RelayTTY keeps 100,000 lines in
every interactive pane plus a 10 MB server ring, so the information still exists
in Relay — Max Pane simply throws it away on arrival.

### 3. Attaching a session focuses a lane you cannot see.

Driven: `⌘O`, filter `trifecta ask`, Return. The sidebar row highlighted, `maxpane
ls` reported `*3` as focused — and the strip did not move. Lane 3 was off-screen
to the right and stayed there through two captures five seconds apart, with no
focus border visible anywhere on screen. Pressing `⌘]` afterwards scrolled it in
correctly, which isolates the fault: `StripViewController.focus(_:)` calls
`ensureVisible`, and the "already on strip" and "import strip" paths both call
`strip.reveal(...)`, but the attach branch in
`StripWindowController.showSessionPicker` calls `store.attachSessionAtEnd(...)`
and nothing else.

He hits this at second thirty of day one, on the very first thing he does after
launching — and worse than the confusion, focus has moved to an invisible lane,
so the next thing he types goes somewhere he is not looking. The fix is one line,
`self.strip.reveal(laneId:flash:)` after the attach, but a first-run experience
where the primary action appears to do nothing is exactly what sends someone back
to the tool that works.

### 4. Agent output is inert: no clickable file paths, and no in-terminal find.

`requestOpenLink` turns any clicked link into a web lane to the right, which is
right for `https://`, but SwiftTerm detects URLs only. The things Claude Code
actually emits all day — `src/foo.ts:42:10`, `package.json`, `docs/gauntlet.md` —
are not links at all, and a `file://` link would open as a *web* lane rather than
a host-resolved viewer at line 42. RelayTTY's existence-gated bare-filename
detection (`POST /api/sessions/:id/exists`, ~130 extensions, 30 s cache) is what
closes the read-what-the-agent-cited loop without leaving the workspace, and it
is ranked #6 on the inventory's own list because it fires dozens of times a day.

Compounding it, there is no find-in-terminal: `⌘P` is a cross-lane *lane finder*
over `TerminalPaneController.scrollbackLines = 200` — the last 200 lines of each
lane, no next/prev, no highlighting. SwiftTerm even ships `MacFindBarView` and
Max Pane never wires it. Between a 500-line buffer and a 200-line index, anything
an agent said more than a few minutes ago is unreachable by any means.

### 5. A session can be attached and detached, but never killed, cleared, or renamed.

There is no SIGTERM, SIGKILL or signal path anywhere in `swift/` — `⌘⇧W` closes
the lane and `RelayAttachmentAdapter.disconnect()` drops the socket, which is
correct and safe (verified: all eight of Scott's sessions survived my attach and
detach), but it means the app cannot end a session at all. Dead sessions
accumulate visibly: an `untitled  GONE / EXITED` row sat in the sidebar for the
rest of my run with no way to dismiss it.

Alongside it, `Command` has no clear-scrollback (RelayTTY's `⌘K`, which frees the
server's 10 MB ring — at ten sessions that is where his afternoon slowdown comes
from), no rename, and no font-size control; `⌃⌘=`/`⌃⌘-` adjust lane *width* in
points, not type size, so the three-columns-at-three-different-sizes arrangement
in his actual screenshot has no equivalent. Kill is the only one of these he
reaches for daily, but he reaches for it daily, and he would have to drop to
`relay kill` in another terminal to do it.

---

## 4. What Max Pane already does better

These are real, and some of them are things RelayTTY cannot do at all.

- **Text search over the session list.** `⌘O` filters ten sessions to one by
  typing `trifecta ask`. RelayTTY has no session search anywhere — the inventory
  lists it as a verified absence (§1.12). At ten sessions across six projects
  this is the better index, and the picker's footer
  (`1 OF 10 SESSIONS · 10 RUNNING · 2 ON STRIP`) answers a question RelayTTY's
  sidebar never answers.
- **`N BLOCKED` promoted to the group header.** RelayTTY's group header only ever
  says "N running"; blocked-first sorting exists but the *count* never surfaces
  above the row level. Max Pane puts it in the header in Signal Orange and bold
  (`SidebarRowViews.swift:301-302`), which is strictly more glanceable for the
  exact question the whole screen exists to answer.
- **Web panes as peer lanes.** The entire premise, and RelayTTY's only browser
  surface is a VNC bridge to the host's screen. A terminal that opens a URL in a
  lane beside it via the `BROWSER` shim is a genuinely better shape.
- **Richer picker rows.** `trifecta ask  8f91bf75 · /bin/zsh  idle  2h ago` — the
  session id and the command. RelayTTY's sidebar row shows neither, and it has no
  picker at all.
- **A durable, portable strip.** SQLite at
  `~/Library/Application Support/MaxPane/ledger.db`, plus `⇧⌘S`/`⇧⌘O` export and
  import. RelayTTY's tile layout is localStorage, per-browser, non-portable.
- **Discoverability.** `⌘/` is generated from the `Command` enum, so it cannot
  drift. RelayTTY has no in-app shortcut list, and the inventory's §1.14 shows
  its written docs are wrong on at least eight counts.
- **Honest lane headers.** Status dot, title, live throughput, `~`-shortened cwd,
  age, overflow menu, and a full-perimeter orange border on the focused lane —
  the bar's pane header, matched, with age added.

---

## 5. What I verified by driving vs. what I inferred from source

### Verified by driving the running app

- `⌘/` opens a generated shortcut panel; read the full FILE / NAVIGATE / VIEW map
  off it.
- `⌘O` opens a session picker that filters by typed text; footer reads
  `1 OF 10 SESSIONS · 10 RUNNING · 2 ON STRIP`.
- **Attaching a session leaves the focused lane off-screen** and the strip does
  not scroll; confirmed across two captures five seconds apart.
- **`⌘]` afterwards does scroll it into view**, isolating the fault to the attach
  path rather than to `ensureVisible`.
- **Scrollback holds ~500 lines**: 80 Page Ups on a 3,000-line lane stopped at
  `LINE 2443`.
- **`⌘V` pastes nothing**: two independent runs, `TYPED-OK  END` and `A[]B`.
- Typed characters *do* reach the PTY, so the failure is the paste path, not
  focus or key delivery.
- `⌘⇧W` detaches without killing: all eight of Scott's live sessions were alive
  afterwards.
- The sidebar renders cwd groups, per-group running counts, status dots, agent
  glyphs, live throughput (`616B/S`, `1.5KB/S`) and relative age (`3h ago`) —
  the bar's left third, matched.
- An exited session shows as `untitled  GONE / EXITED` and cannot be dismissed.
- At a 1600pt window with the sidebar open, roughly **two** default-width (640pt)
  lanes are visible; the bar fits **three** terminal columns in a comparable
  window. Narrowing with `⌃⌘-` is available, so this is a default, not a ceiling.
- An attached Claude Code session renders correctly — colour, bold, box glyphs,
  focus border, header with `~/code/trifecta-discovery`.

### Inferred from source, not driven

- `RelayAttachmentAdapter.maximumReplayBytes = 256 * 1024` caps a cold replay, so
  reattaching cannot recover lost history.
- `TerminalView(frame: .zero)` passes no `TerminalOptions`, so SwiftTerm's
  default `scrollback: 500` applies — this is the *cause*; the 500-line behaviour
  itself was measured.
- `StripWindowController.showSessionPicker`'s attach branch omits
  `strip.reveal(...)` that its sibling branches call — the *cause* of the
  attach-focus bug, which was measured.
- No `Edit` menu (`MenuSection` is File/Navigate/View) and no
  `performKeyEquivalent` anywhere, which is why SwiftTerm's existing `copy:` /
  `paste:` / `selectAll:` are unreachable.
- `clipboardCopy(source:content:)` is an empty stub, so OSC 52 host copies are
  dropped. (Not driven — I did not emit an OSC 52 sequence.)
- No `SIGTERM` / `SIGKILL` / signal path anywhere in `swift/` or `crates/`.
- `requestOpenLink` creates a web lane for any link; SwiftTerm's detector is
  URL-only, so bare filenames and `path:line:col` are not links. (Not driven — I
  did not click a path in agent output.)
- SwiftTerm ships `MacFindBarView`; Max Pane never references it. `⌘P` indexes
  `scrollbackLines = 200` per lane.
- Agent state, blocked-first ordering and the blocked group count are implemented
  in `SidebarModel` / `Theme.agentStateColor`. (Partly driven — I saw `IDLE`
  chips and the rate slot, but never observed a `BLOCKED` chip, because the one
  visibly-blocked lane on screen was a `/tmp/fakeagent` fixture another agent
  owned and its row showed no chip during my run. **Blocked-state display is
  therefore unproven by driving and should be re-tested.**)
- The strip persists to SQLite (`StripStore.defaultLedgerPath`), so lane layout
  survives a restart.
