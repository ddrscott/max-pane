# A chord per web app: `[[apps]]` that focus the lane if it is open and open it if not

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F8. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, and the change with its acceptance criteria and size).

## Notes beyond the finding

- `[[apps]]` is the third array-of-tables in `config.toml` after `[[servers]]`; `ConfigToml.swift` already parses and edits them in place keeping comments (from the Phase 2 remote work). `name`, `url`, `key`, optional `docked = "left"|"right"`.
- "Focuses the lane whose pane is on that origin" — match by registrable domain, the same notion the per-site blocking exemption uses (find it; do not invent a second matcher). Several matching lanes: the most recently focused.
- The chord binding is dynamic (from config, not `Command.allCases`), so `Keymap` needs a second source: check how `[keys]` overrides resolve at runtime and add app chords beside them, with a collision refused and named. A page that wants the key follows the existing `yieldsToPage` rule.
- Surfaces: `// APPS` in the ⌘/ sheet, a section in Settings with the chord recorder (shared since F3), rows in ⌘E, and `maxpane app NAME` on the control socket.
- Opening honours `docked`, and a docked app lane keeps ADR-0003's data-store rules.

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

