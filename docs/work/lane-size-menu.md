# Lane size presets in every lane's menu, replacing Span Lane

## Problem

The `s | m | xl` presets (commit 6e9b2be) are reachable only from the header
switch and three unbound View menu commands. The switch is hidden on docked
lanes, on gallery tiles, and on any lane narrower than `sizeSwitchMinWidth`, so
on exactly the lanes where size is most in question there is no way to pick
one. Meanwhile the lane's dropdown menu still offers **Span Lane (2× Width)**
(⌘\, 1800 pt), which xl now covers: two ways to make a lane wide, with
different widths.

## Decisions already made (by the owner)

- The presets replace Span Lane. Span goes away as a command, not just as a
  menu item.
- ⌘\ **cycles s → m → xl → s**. A lane that is off every preset (dragged,
  zoomed, an old 1800 pt span) goes to **m** on the first press.
- Docked lanes get the presets too.

## Acceptance Criteria

- Every lane's dropdown menu (`LaneView.swift`, the `NSMenu` built near
  `menuToggleSpan`) always shows **Small**, **Medium**, **Extra Large** as three
  items, with a checkmark on the current preset and none when the lane is off
  every preset. "Always" means regardless of lane width, of whether the header
  switch is showing, and of whether the lane is docked.
- Picking one does exactly what the header switch does (same
  `StripStore.setLaneSize` / `Core::set_lane_size` path, same `Motion.lane`
  easing, one terminal reflow at the end, Reduce Motion lands at once).
- **Span is gone:** the menu item, `Command.toggleSpan` and its title, its
  View menu entry, its row in the ⌘/ shortcuts sheet, `onToggleSpan` and the
  `.toggleSpan` handling in `StripWindowController`. No dead code left behind.
- **⌘\ cycles** through the presets on the focused lane, through the same
  command path, and is shown on the menu items' cycle command in the ⌘/ sheet.
  It stays rebindable like any other `defaultShortcut`. Decide whether it is a
  new `laneSizeCycle` command or bound to the existing three, and say which
  in the commit.
- **Old spanned lanes:** a lane persisted at span 2 / 1800 pt still loads, keeps
  its width, and simply shows no preset checked. No data migration unless the
  core's span field turns out to be meaningless without the command; if so,
  explain in the commit.
- **Docked lanes:** choosing a preset sets the dock's width (`setDockWidth` /
  `DOCK_MIN_PT`..`DOCK_MAX_PT`) and the pane zoom the preset implies (s = 60%).
  Where a preset's width falls outside the dock bounds, clamp it and state that
  in the README; the checkmark follows what the lane actually is. The header
  switch shows on docked lanes when there is room, like any other lane.
- README: the lane size paragraph describes the menu, the ⌘\ cycle, and that
  Span Lane is gone (and why).
- Tests: menu contents for normal, narrow and docked lanes (three items,
  correct checkmark, none off-preset); ⌘\ cycle order including off-preset →
  m; that no `toggleSpan` command remains; docked preset width and clamp.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift`: header menu
  (~line 1366), `onToggleSpan`, `showsSizeSwitch` (`!isDocked && !isThumbnail`)
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift`: `toggleSpan`,
  `laneSizeSmall/Medium/Large`, `defaultShortcut`, menu grouping
- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift`: command
  dispatch for `.toggleSpan` and the preset commands, dock width ±60 handling
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift`:
  `onToggleSpan` wiring, preset animation
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneSizePreset.swift`,
  `LaneSizeSwitch.swift`
- `swift/MaxPane/Sources/MaxPaneKit/StripStore.swift`: `setLaneSize`,
  `setDockWidth`
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripDock.swift`: dock width bounds
- `crates/laned-core/src/lib.rs`, `model.rs`: `set_lane_size`, span, dock
  width; regenerate bindings with `./scripts/gen-bindings.sh` if the API moves
- `swift/MaxPane/Tests/MaxPaneKitTests/LaneSizePresetTests.swift`

## Constraints

- Motion: no size change snaps in (Motion.lane, ease-out, reduce-motion aware).
- Greens only (ADR-0015). Menu checkmarks are system-drawn, which is fine.
- relay-tty is read-only; the PTY resize rules from 6e9b2be stay as they are.
- In a fresh worktree, build the core with rustup's toolchain, since Homebrew's
  rustc 1.86 is first on PATH: `RUSTC=~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc ~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo build --release -p laned-core`.
