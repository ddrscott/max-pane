# One green family instead of Signal Orange — BLOCKED is the brightest green, pulsing

The owner: *"I don't like the orange highlight color. Let's ensure we stick with
the green and shades of green so we're not too colorful."*

## Problem

Signal Orange (`Theme.accent`, `#E85D00`) is the app's highlight: 66 uses across
17 files — the focus outline, default and `+ NEW` buttons, the `//` of every
section header, the `$` live marker, the palette's selection, drop indicators, the
terminal cursor, the ⌘P flash, the web-ask sheet, the wizards and the memory
dashboard. It is also BLOCKED, because Relay TTY renders BLOCKED in the same
`#E85D00`. Green already exists beside it as "working" — defined twice, as
`Theme.flowing` and again inline in `agentStateColor`. The result is two loud hues
where the owner wants one quiet one.

## Decisions already made (do not re-open)

- **No orange anywhere.** One green family carries every highlight and every state.
- **Roles, by brightness:**
  - **working** — muted green, `#16A34A` (filled status square, state chip)
  - **focus / interactive accent** — mid green, `#22C55E` (focus outline, default
    and `+ NEW` buttons, `//` slashes, `$` marker, selection, drop indicators,
    cursor, flash, lit toolbar switch)
  - **BLOCKED** — brightest green, `#4ADE80`, **with a slow pulse** on its chip, the
    sidebar/status-bar BLOCKED count and the lane header's blocked mark
  - **done** stays slate; **exited** stays dim.
- This overrides the owner's global visual signature (Signal Orange as accent) for
  this project, on his instruction. Record it in an ADR so a later change does not
  "restore" the orange.

## Acceptance Criteria

- `rg -i 'e85d00|0xE8 / 255'` finds nothing in `swift/`, and no view is orange in
  any render sheet.
- `Theme` names the roles rather than a hue — e.g. `accent` (mid), `working`,
  `blocked` — each defined once; `flowing` and the inline duplicate in
  `agentStateColor` are folded into them.
- **The three greens stay tellable apart**, which is the whole risk of one family:
  focus is an *outline*, working a *filled* muted square, BLOCKED the brightest and
  *moving*. The lane-header render sheet already calls out the pair that must be
  distinguishable at a glance — a blocked unfocused lane vs a focused idle one — and
  it still is, in both appearances.
- **The pulse** is slow and subtle (a period of roughly 1.5–2 s, easing between
  full and reduced brightness, never off), runs on Core Animation rather than a
  timer, only on blocked marks that are on screen, and stops the moment the agent
  is no longer blocked. Under Reduce Motion it does not animate; BLOCKED is then
  distinguished by brightness plus a filled mark.
- **Light mode** has its own values where the dark-mode shades lack contrast on a
  light ground (the appearance task, queued before this, makes colours resolve per
  appearance; use that mechanism). Check contrast of text and 1 pt outlines in both.
- The terminal cursor, section-header slashes and `$` marker follow the accent.
- Render sheets regenerated and looked at, in both appearances: lane headers (all
  agent states, focused and not), sidebar rows including BLOCKED, strip toolbar,
  a `ConfirmPopup`, the ⌘O picker, a wizard screen.
- Comments and README text that say "Signal Orange" are updated to name the role
  instead (Theme, LaneView, WebAskSheet, ImportHistoryWizard, StatusBar, README).

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Views/Theme.swift` — `accent`, `flowing`,
  `agentStateColor`.
- Every `Theme.accent` use: `rg -l 'Theme\.accent' swift/MaxPane/Sources` (heaviest
  in `SidebarRowViews.swift`, `SearchPalette.swift`, `PaneDrag.swift`,
  `WebChromeBar.swift`, `TerminalPaneController.swift`).
- `Views/LaneView.swift` — header state mark and its docs.
- `Views/StatusBar.swift`, `Views/SidebarRowViews.swift` — BLOCKED counts and chips.
- `LaneHeaderTests.swift`, `SidebarBookmarkRenderTests`, `StripToolbarTests.swift`,
  `PopupTests.swift` — render sheets.
- `docs/decisions/` — new ADR for the palette.

## Constraints

- Queued after the appearance and settings tasks: build the greens on the
  per-appearance colour mechanism the appearance task introduces.
- Square corners and the rest of the house style stay; only hue changes.
- Nothing may appear, change or pulse abruptly — the owner's standing rule.
