# Clock, battery and network at the right of the status bar while fullscreen

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F2. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- Only while `window.styleMask.contains(.fullScreen)`; windowed shows nothing (the menu bar has it). `status_clock = true` setting, live.
- Battery via `IOPSCopyPowerSourcesInfo` (IOKit), refreshed on the power-source notification, not polled; network = the active interface's kind (wifi/ethernet/none) via `NWPathMonitor`, no SSID (needs Location permission; refused). Clock ticks on the minute.
- Under 15 % battery uses the existing red for "past the hard limit"; charging shows ⚡. Grey otherwise; never green.

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

