# Follow the system's light/dark mode — chrome, terminals and web pages — live

The owner: *"we should respect system light/dark modes and pass them through to
the browser instance, too."*

## Problem

The app half-supports appearance and does not actually follow it:

- `Theme`'s colours are dynamic (`NSColor(name:)` closures on `bestMatch(from:
  [.darkAqua, .aqua])`), and terminals already carry a light palette (Alabaster)
  and a dark one (Afterglow) — `TerminalPaneController.swift` ~880–906.
- But views paint by converting those colours **once**: 54 `.cgColor`
  conversions across 21 files, and **zero** `viewDidChangeEffectiveAppearance` /
  `updateLayer()` handlers. A `CGColor` is a snapshot, so switching the system
  from dark to light leaves lane backgrounds, borders, headers, the sidebar, the
  toolbar, popups, gallery tiles and docks in the old appearance until each view
  happens to be rebuilt.
- Web panes set only `underPageBackgroundColor`
  (`WebPaneController.swift` ~1007–1016). Whether pages see the right
  `prefers-color-scheme`, and whether `matchMedia` fires on a switch, has not
  been checked at all.

## Decisions already made (do not re-open)

- **Follow the system by default, live** — no relaunch, no page reload.
- **Plus an override:** a `theme` setting, `system | light | dark`. `system`
  leaves `NSApp.appearance` nil; `light`/`dark` pin it. The override reaches web
  pages too.

## Acceptance Criteria

- Toggling System Settings › Appearance with the app open repaints every piece of
  chrome in the new appearance within one frame: lanes, headers, seams, focus
  outline, sidebar, strip toolbar, status bar, docks, gallery tiles, every
  `Popup` (open or opened later), placeholders' frames.
- Terminals switch palette live (Alabaster ⇄ Afterglow) without resizing or
  redrawing the session's contents from scratch.
- A web page with `@media (prefers-color-scheme: dark)` renders dark in dark mode
  and light in light mode, and a `matchMedia('(prefers-color-scheme: dark)')`
  change listener fires on a live switch. Proven against a local test page, in
  real WebKit, not assumed.
- `theme = light` / `dark` pins all of the above regardless of the system;
  `system` follows it. Changing the setting applies live.
- The switch is not a hard cut: a short crossfade on the app's `Motion` clock,
  honouring Reduce Motion (the owner's standing rule — nothing may "jank in").
- One mechanism, not 54 hand edits: views resolve colours against their own
  `effectiveAppearance` in `updateLayer()` / `viewDidChangeEffectiveAppearance`
  (or a single shared helper that does), so a view added later cannot forget.
- Render sheets under `MAXPANE_SHOTS` in **both** appearances for the lane
  header, sidebar, strip toolbar and a `ConfirmPopup`, looked at.
- Signal Orange (`Theme.accent`) is the same in both.
- README: a short "Light and dark" section, and the `theme` key documented.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Views/Theme.swift` — the dynamic colours.
- Every `.cgColor` use: `rg -l '\.cgColor' swift/MaxPane/Sources`.
- `Terminal/TerminalPaneController.swift` — light/dark `TerminalConfiguration`s.
- `Web/WebPaneController.swift` — web view setup, `underPageBackgroundColor`.
- `Config.swift` — add `theme` (hand-rolled per-key decoder: add it there too).
- `swift/MaxPane/Sources/MaxPane/AppDelegate.swift` — where `NSApp.appearance`
  would be set at launch and on a settings change.
- ADR-0006 — placeholder snapshots are JPEGs taken in whatever appearance the page
  had; decide and state what an evicted page's snapshot does after a switch.

## Constraints

- Do not reload pages or restart sessions to apply an appearance.
- The `theme` key lands in today's `Config`; the settings-UI task queued after
  this one moves every key to TOML and gives `theme` its control.
- Square corners and the existing palette values stay; this is about following
  appearance, not redesigning either mode.
