# ⌃⌘W End Session (with a sheet), ⌘K clears scrollback, rename from the lane header

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F10. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- End Session kills the relay session: locally via the pty-host (find how relay-tty's CLI does `relay kill`: a SIGNAL frame 0x25 on the socket or a signal to the pid — read docs/reference/relay-integration.md and ~/code/relay-tty/cli); remotely `DELETE /api/sessions/:id` with the cookie (owner only). The lane closes after; the sheet defaults to Cancel and names the command line it will end.
- ⌘K: clear scrollback in Ghostty is a binding action (`clear_screen`/`clear_scrollback` via `performBindingAction`, see CopyModeDriver for the pattern); ⌘K collides with nothing in `Commands.swift`? check. Both lanes kinds: in a web pane ⌘K is the page's (yield).
- Rename: the lane header title becomes editable on double-click or Rename… in `⋯`; writes `set_lane_title` / the session title via `SET_TITLE` 0x24 where the session is the source of the title (README › titles; relay-tty 1.22+). Say which is written where.

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

