# Check for updates daily, show ↻ vNEXT in the status bar, and update from a terminal lane with Relaunch

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F7. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- The release feed: `https://api.github.com/repos/ddrscott/max-pane/releases/latest` (no auth; respect ETag; once a day and on Help › Check for Updates…; never on a metered/offline failure loudly, one line in the log). Compare against `CFBundleShortVersionString` with the changelog parser's version ordering.
- The update runs in a **terminal lane** the app spawns locally (`LocalSpawner`, the shell line `brew upgrade --cask max-pane`; `update_command` in config overrides), so the user watches it; exit status via the session's EXIT frame. On 0: a `RELAUNCH` action in that lane's footer/banner. Relaunch = export the strip is NOT needed (the ledger is the truth); it is: `open -n` the new bundle from a detached helper that waits for this pid to exit, then `NSApp.terminate`. **The relaunch must scrub `CLAUDE*`/`ANTHROPIC*` env vars** (project memory: a launch inheriting them poisons every pane); the detached helper starts with a minimal environment like the orchestrator's recipe (HOME, USER, LOGNAME, SHELL, PATH=/usr/bin:/bin:/usr/sbin:/sbin, TMPDIR, LANG, SSH_AUTH_SOCK, __CF_USER_TEXT_ENCODING).
- Homebrew-less installs (the DMG): `update_command` unset and no `brew` on PATH → Help › Update… opens the release page in a web lane instead, and says so.
- The relay-tty minimum (README › Requirements) is checked on the same tick from `relay --version`; when short, one line in the status bar tooltip and the version popover.
- Refused: Sparkle, background download, silent relaunch.
- **Do not run the real upgrade during your work**; test with a fake feed and a fake `update_command` (`true`/`false`).

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

