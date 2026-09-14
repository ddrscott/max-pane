# Lane size presets: s | m | xl

The owner: *"`../wiz-term` has a great lane feature where it can set `[s | m | xl]`
— we can make 'xl' the double wide standard font size, 'm' phone width standard
font size, and 's' smaller 60% font size but compute the columns to be the same
number and adjust the width to fit the new number of columns."*

## Reference: what wiz-term does (read-only, `../wiz-term`)

`src/lib/components/terminal/TerminalLane.svelte` —
`SIZE_PRESETS = { s: { width: 320, fontSize: 8 }, m: { width: 640, fontSize: 13 },
xl: { width: 800, fontSize: 13 } }`; `applyPreset` sets the font size, refits, sends
a resize, then sets the lane width. `webview/WebviewPane.svelte` has width-only
presets `{ s: 320, m: 640, xl: 800 }`. Its `s` changes font and width independently,
so the column count changes. **The owner wants something different:** at `s` the
columns stay the same.

## Decisions already made (do not re-open)

Presets are **absolute** sizes, the same for every lane, not relative to its current
width.

| | terminal lane | web lane |
|---|---|---|
| **m** | `laneDefaultPt` (656 pt) at 100% zoom — **80 columns** at the standard 13 pt | default width, 100% page zoom |
| **s** | **the same 80 columns** at **60% font**; the width is *computed* so exactly those columns fit (~400 pt) | 60% page zoom at 60% of m's width, so the page lays out exactly as at m, just smaller |
| **xl** | **double wide** (the existing 2× span) at 100% — ~160 columns, since the PTY follows the lane (ADR-0007 is superseded on that point) | double wide at 100% zoom — more page |

- A **split lane** applies the preset to every pane in it.
- **`s` may go below `laneMinPt`** (420 pt). The preset is the point, so it is not
  clamped away. Dragging a lane still respects the minimum.
- **The control:** a square `s | m | xl` switch in the lane header, lighting the
  current preset. It shows none lit when the lane has been dragged or zoomed off
  every preset. There are also three commands (`laneSizeSmall`, `laneSizeMedium`,
  `laneSizeLarge`) in the menu, the ⌘/ sheet and `keys`, with no default chords.

## Acceptance Criteria

- **Columns really are equal at s and m.** Switching a terminal lane m → s changes
  its font to 60% and its width so that Ghostty reports the same column count, and
  the session receives no RESIZE. The width comes from the real cell metric at the
  smaller font (the way `TerminalPaneController.newSessionSize` measures a cell),
  not from 0.6 × 656 — rounded cells would drift a column. Tested against the grid
  report.
- xl sets span 2 at 100% zoom; the PTY grows to the columns the wider lane holds,
  as a width change already does today.
- m restores `laneDefaultPt`, span 1, 100% zoom.
- A web lane at s shows the page at 60% zoom in 60% of m's width, and the page's
  `innerWidth` equals its m value; xl doubles the width at 100%.
- The preset survives a relaunch. Width, span and zoom are already in the ledger;
  derive the lit preset from them rather than storing a second copy that could
  disagree.
- Changing preset eases: the lane width on `Motion.lane` (as widen/narrow and span
  already animate), and the font or zoom step with it. Nothing jumps; Reduce Motion
  is honoured.
- The switch works on docked lanes and in gallery tiles, or is deliberately hidden
  there, with the reason stated.
- Tests: the width computation for s at several font sizes; preset derivation from
  width + span + zoom; m → s → m round-trips with no RESIZE; web s `innerWidth`
  equality in real WebKit. Render sheet of the lane header switch, light and dark,
  looked at.
- README: a "Lane sizes" paragraph.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/StripStore.swift` — `setLaneWidth`, `setPaneZoom`,
  span toggle.
- `crates/laned-core/src/lib.rs` — `set_lane_width`, `set_pane_zoom`, span; lane width
  clamping.
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift` — `laneDefaultPt`, `laneMinPt`,
  `laneMaxPt`, `widthRange`, `clampWidth`.
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaneController.swift` —
  `newSessionSize` (cell metric), `applyZoom`, grid reporting.
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` — page zoom.
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` (`LaneHeaderView`) — where
  the switch goes; `Commands.swift` / `Keymap.swift` — the commands.
- `docs/decisions/0007-terminal-panes-never-resize-the-pty.md` — superseded: the PTY
  follows the lane width.

## Constraints

- Colours from `Theme` only. The lit state uses whatever accent the green-palette
  task lands. It is queued before this one, as is the layout-switch icon task, whose
  switch this should look like.
- Square corners; nothing appears or changes abruptly.
