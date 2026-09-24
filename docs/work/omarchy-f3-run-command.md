# ⇧⌘P Run Command: every command, live setting toggles and server actions in the picker, with chord binding

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F3. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- `OmniPicker` already has scopes (everything / pages / sessions) and the `@server` grammar (ADR-0022); add the `app` scope and the `>` prefix without breaking those. Search palette (`SearchPalette`) is a separate thing; do not merge them.
- The list comes from `Command.allCases` with `title`, current chord (from `[keys]` overrides, not only defaults), and `menu` section, so it never rots. Rows that are not applicable right now (a web-only command with a terminal focused) are shown greyed with the reason, not hidden.
- Setting toggles: the boolean and `choice` settings from `ConfigSchema` that apply live; a row shows the current value and flips it through `ConfigStore` (comments kept).
- Server actions: `connect`/`disable`/`enable`/`color` per configured server via `RelayServerBook`.
- `⌘⌫` binds: reuse the chord recorder from Settings › Keyboard; write to `[keys]`; refuse a chord that collides and say with what.
- Refused: rows that run a shell line (that is ⌘O's job).

## Constraints (every Omarchy-round task)

- The finding above is the spec; where it is silent, the app's own conventions
  decide (README, ADR index, `Commands.swift` for command/key/menu/⌘/ sheet).
- Identity: greens for state, Signal Orange only for DONE, grey at rest, square
  corners, `// CAPS` section headers, JetBrains Mono, no bubble cards, no
  single-edge rail, no new colour family; no instant transitions (`Motion.*`).
- Every new command: in `Commands.swift`, rebindable under `[keys]`, in a menu,
  in the ⌘/ sheet; check the chord against existing ones and macOS.
- Tests as the app tests things (models pure; real-surface/WebKit where the
  claim is about one); render sheets where a surface is new, looked at.
- README section, CHANGELOG entry, ADR only for a decision worth reopening.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Never capture `self` weakly in a callback on an object nobody else holds.

