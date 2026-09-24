# ⌃⌘S Capture Pane: a PNG of the focused pane, its path pasted into the nearest terminal, and `maxpane capture`

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F6. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, the change with its acceptance criteria and size).

## Notes beyond the finding

- Web pane: `WKWebView.takeSnapshot(with:)`; ⇧ variant = full page (resize the snapshot config to the document height, or `createPDF`→rasterise is NOT acceptable; if full page cannot be done with `takeSnapshot`, ship the visible-area capture only and say so).
- Terminal pane: the view's layer contents (`cacheDisplay(in:to:)` on the Ghostty view or the pane container); a Metal-backed layer may need `CGWindowListCreateImage` of the pane's window rect; measure both, use what actually captures text.
- Storage and naming: the pasted-picture store (`PastedImages`, ADR-0027, `paste_image_keep_days`); remote lanes upload through `RelayUpload` and paste the remote path.
- Where the path goes: the nearest terminal pane in the same lane (the pane below/above in a split), else copied with the `COPIED` chip.
- `maxpane capture LANE` on the control socket prints the path, so an agent can ask for its own screenshot.

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

