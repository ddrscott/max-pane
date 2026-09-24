# A ⌘; leader with a which-key overlay, so the chords become a vocabulary

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F4. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, and the change with its acceptance criteria and size).

## Notes beyond the finding

- **This is the most speculative item in the critique and the one the owner is most likely to veto.** It adds a second way to reach commands that already have chords and a picker (⌘E). Before building: re-read the finding, look at how many commands would actually hang off a leader, and if the honest answer is that ⌘E already covers it, **reject the task** (`- [~]` with the reason) rather than building a vocabulary nobody asked twice for. A rejection with a paragraph of reasoning is a good outcome here.
- If you build it: every leader sequence is an alias for an existing `Command`, spelled in `[keys]` as `"cmd+; d l"`; nothing existing moves or is removed. The overlay is 300 ms delayed, square, mono, `// LEADER`, at the foot of the focused lane, and reuses the ⌘/ renderer so the two cannot drift. Esc cancels; an unknown key shows `? no such key` and stays. Web panes never see the sequence. ⌘; must be checked against `Commands.swift`, `Keymap.reserved` and macOS.

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

