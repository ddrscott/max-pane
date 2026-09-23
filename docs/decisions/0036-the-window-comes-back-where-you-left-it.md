# ADR 0036 — The window comes back where you left it

**Status:** Accepted · 2026-09-23
**Decides:** whether the window is fullscreen at every launch (PRD §5.2) or
where it was last time; where that is remembered; when it is written; how a
remembered frame is put back on screens that may have changed.
**Evidence:** the work item [`docs/work/window-state-restore.md`](../work/window-state-restore.md);
`WindowState.swift`, `StripWindowController.showWindow`; `WindowStateTests.swift`,
`crates/laned-core/tests/window_state.rs`.

## The request

The owner: *"MaxPane is always opening fullscreen, instead we should recall
the previous state and position and use it so that the user's experience is
consistent."*

## The conflict

PRD §5.2: *"Fullscreen `NSWindow` (`.fullScreen` collection behavior). Menu
bar auto-hides."* That was built literally: `showWindow` called
`toggleFullScreen(nil)` on every launch unless `MAXPANE_WINDOWED` was set, and
the window was created at a fixed 1600×1000 with nothing remembering its
frame. A person who had dragged the window out of fullscreen to sit beside
another app got fullscreen again on the next launch, every time.

The PRD's sentence is about what the app is *for* — a strip that takes the
display — not a rule that the display must be taken again after the user has
said otherwise. The owner's daily use overrules the literal reading.

## Decision

**The window's last state is remembered and restored.** Fullscreen, or a
frame on a display. **The first launch, with nothing remembered, is
fullscreen**, so §5.2 still describes what a new user sees.

**Where: the ledger's `app_state` table, key `window_state`**, beside
`sidebar_collapsed` and `hidden_lane_ids`. One small JSON value:
`{"fullscreen":true}` or
`{"fullscreen":false,"frame":[x,y,w,h],"screen":"<display id>"}`. The core
stores it opaquely (`Core::window_state` / `set_window_state`); screens are
the shell's to read. Per profile, because the ledger is. Not
`NSWindow.setFrameAutosaveName`: it writes to UserDefaults, which is not where
this app keeps anything, and it cannot say "fullscreen". The display is
`NSScreen`'s display number, the one thing about a screen that is the same
after a relaunch — two of the same monitor share a name.

**When: on every fullscreen enter and exit** (the window's own `did*`
notifications), **on move and resize after 0.5 s of quiet** (a drag is
hundreds of frames; that is one write), **and on quit** (`flushPaneState`,
which already runs there). **Never while a fullscreen transition is in
flight**: AppKit resizes the window several times on the way in and out, and
those frames are the animation's, not the user's; a write pending when the
transition starts is dropped, and the `did*` write replaces it.

**Restore: a remembered fullscreen enters fullscreen after the window exists**,
as before, and on the remembered display when it is still plugged in — the
window is moved onto that display first, because fullscreen takes the display
the window is on. **A remembered frame is applied before the window is shown**,
so the strip lays out once at its final size, and it is clamped onto a screen
that still exists: the remembered display when present, otherwise the screen
the frame overlaps most, otherwise — off every screen — the nearest to the
frame's centre. The size shrinks to what that screen's visible area can hold
and the origin moves so the whole window is inside it. The visible area
excludes the menu bar and the Dock, so the window is never under either.

**`MAXPANE_WINDOWED` still forces windowed, and writes nothing.** A smoke test
on somebody's machine must not change what the owner comes back to.

A value this build cannot read — a hand-edited ledger, a future build's shape
— reads as nothing remembered, which is the first launch, which is fullscreen.
Never a crash over a preference.

## What was found already remembered

The strip's layout (lanes or gallery) is in the ledger under `strip_layout`.
The sidebar's width is `NSSplitView`'s autosave (`MaxPaneStripSplit`, in
UserDefaults — the one place this app does use it, predating this ADR).
Whether the sidebar is collapsed rides on the same autosave and was not
verified here. Scope was not widened past the window frame and fullscreen.

## Rejected

- **Fullscreen at every launch**, as built. The PRD's reason for it — the
  strip is the interface, the menu bar is an interruption — is a reason to
  *offer* fullscreen, and the first launch still does.
- **`setFrameAutosaveName`.** UserDefaults, no fullscreen bit, not per
  profile, and a second place to look for state.
- **Remembering the windowed frame under a fullscreen state too**, so that
  leaving fullscreen after a relaunch returns to the old frame. macOS returns
  the window to the frame it had before *this* process entered fullscreen,
  which for a relaunch is the default 1600×1000. Cheap to add later behind the
  same key; not asked for.
- **Writing on every frame of a drag.** A write is a SQLite commit; 120 of
  them a second is absurd for a value nobody reads until the next launch.

## What would make us revisit

- A second window. Then the key is per window, and the value is a list.
- AppKit stopping the `didMove` / `didResize` notifications for a window whose
  delegate is set. It does not today; the keeper is tested against a real
  window and posts nothing itself.
