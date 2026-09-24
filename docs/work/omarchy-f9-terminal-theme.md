# Pick a Ghostty terminal theme, and make font size live

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F9. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, and the change with its acceptance criteria and size).

## Notes beyond the finding

- `terminal_theme = { dark = "...", light = "..." }` naming Ghostty themes. ADR-0009 records that the theme is rendered *after* the configuration, which is why colours set beside the font are overwritten — read it before touching `TerminalControllerPool.makeController`. The app's own palette is a `TerminalTheme` built on Afterglow/Alabaster; a named theme replaces that, and the three colours that are the app's (find them, they are commented) must still win or be documented as lost.
- Which themes exist: libghostty-spm ships `GhosttyTheme` with a themes table (`Sources/GhosttyTheme/Themes/`). Enumerate from it, do not hard-code a list; an unknown name is reported the way a bad config value is and falls back.
- **Live**: applying a theme and a font size must reach existing surfaces without a relaunch. ADR-0035's live path and `setTerminalConfiguration` on the library are the leads; if only new surfaces can take it, say so plainly and mark the setting "relaunch to apply" rather than pretending.
- `⌘=` / `⌘-` in a terminal pane change font size live (they already zoom a web pane); `⌘0` resets. Per pane or app-wide: decide, say which, and keep it consistent with how web zoom is remembered (per pane, in the ledger).
- A picker in Settings and a `theme` row in ⌘E. The chrome stays as ADR-0015 says.

## Constraints (every Omarchy-round task)

- The finding is the spec; where it is silent, the app's own conventions decide
  (README, the ADR index, `Commands.swift` for command/key/menu/⌘/ sheet).
- **The critique predates F3**: where it says `⇧⌘P`, the command picker is
  **`⌘E` Run Command** (commit `f1dfaca`, the picker's APP scope). Add rows
  there, not to a chord that no longer exists.
- Identity: greens for state, Signal Orange only for DONE, grey at rest, square
  corners, `// CAPS` headers, JetBrains Mono, no bubble cards, no single-edge
  rail, no new colour family; no instant transitions (`Motion.*`).
- Every new command: in `Commands.swift`, rebindable under `[keys]`, in a menu,
  in the ⌘/ sheet and in ⌘E; check the chord against existing ones,
  `Keymap.reserved` and macOS.
- Tests as the app tests things (models pure; real-surface/WebKit where the
  claim is about one); render sheets where a surface is new, looked at.
- README section, CHANGELOG entry, ADR only for a decision worth reopening.
- The owner's app is installed and RUNNING at /Applications/MaxPane.app and he
  is using it. Do not quit, replace or launch any MaxPane; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Never capture `self` weakly in a callback on an object nobody else holds.

