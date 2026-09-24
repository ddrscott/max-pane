# Notifications when an agent stops while you are elsewhere, ⌘J Next Attention, and an ATTENTION list

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F1. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- Web-page notifications already go through macOS Notification Center (README › Web notifications, the pane sheet, `UNUserNotificationCenter` use): reuse that plumbing and its permission request; an agent notification is the app's own, so it needs no per-site grant.
- "Not frontmost" is `NSApp.isActive == false`; `away` also means frontmost but the lane is folded/hidden (ADR-0024) or off screen? Decide, and say which; the safe reading is app-not-active only.
- DONE is decided in `SessionRegistry` (`doneSince`, `acknowledge`); the notification fires on the transition, once, and never for a dead server (ADR-0023).
- ⌘J / ⇧⌘J / ⌥⌘J: check `Commands.swift` for collisions first. The Dock badge is `NSApp.dockTile.badgeLabel`; it shows the BLOCKED count and clears at zero.
- The list popover follows the volume/changelog popovers' look (square, mono, `// ATTENTION · N`).

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

