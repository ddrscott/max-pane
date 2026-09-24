# Paste history records what you copy in a web pane, not only in terminals

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F5. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, and the change with its acceptance criteria and size).

## Notes beyond the finding

- ADR-0031's line holds and is the reason this is safe: **the pane writes, the app never polls.** Do not read `NSPasteboard.changeCount` on a timer, and do not record a copy made in another app.
- The hook is the app performing `copy:` in a web pane (the Edit menu and ⌘C routed through the pane's responder). A copy the *page* makes with `document.execCommand`/`navigator.clipboard.writeText` is the page's, not ours: decide whether it is recordable at all (a script message from the page's world would be, but it is also a page reading your intent) and say what you chose. The conservative answer is to record only what the app itself performed.
- A picture copied by that route follows ADR-0027's store (`paste_image_*`) and is recorded as its path, not its bytes.
- Every ADR-0031 exclusion still applies: private lanes, concealed/transient pasteboard types, 64 KB cap, secret masking.
- ⇧⌘H rows gain a `web` / `pty` chip; ↩ still pastes into the focused terminal.

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

