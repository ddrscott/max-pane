# ADR 0009 — libghostty, not SwiftTerm

**Status:** Accepted · 2026-09-12
**Supersedes:** [ADR-0001](0001-swiftterm-over-web-terminal.md), in its choice of
emulator. Its argument against putting Relay's web terminal in a `WKWebView`
stands unchanged.
**Evidence:** the working app, before and after
(the `swiftterm-final` tag marks the last SwiftTerm commit).

## Decision

The pty pane's emulator is **libghostty**, taken as a prebuilt XCFramework via
[libghostty-spm](https://github.com/Lakr233/libghostty-spm), driven through its
in-memory session backend. SwiftTerm is gone.

One `TerminalController` backs every pane.

## Why

ADR-0001 picked SwiftTerm on measurements of the *alternative* — a WebView per
terminal — not on SwiftTerm being good. Three of the four reasons it gave
(scrollback in-process, no IPC hop per keystroke, no `WebContent` process per
pane) are properties of any in-process emulator, and libghostty has all of them.

What changed is what got built on top. By the time the strip was usable,
SwiftTerm was carrying:

- **A hand-rolled OSC 7 sniffer.** Scanning the byte stream for the escape that
  reports the shell's directory, because SwiftTerm did not surface it. Ghostty
  parses OSC 7 as part of being a terminal and hands it over through
  `TerminalSurfacePwdDelegate`.
- **A subclass reaching into selection internals** for auto-copy, and another
  for the click-to-open gesture.
- **Its own reflow**, which is the one that mattered: a lane you drag wider has
  to re-wrap, and getting that right is most of what an emulator *is*.

Each was a re-implementation of something a terminal already does. libghostty is
the emulator behind Ghostty, exercised daily by people whose entire terminal it
is, and it renders on the GPU — which is the difference between a strip holding
a dozen live terminals and a strip holding a dozen live terminals comfortably.

The hyperlink path is a straight gain: Ghostty recognises OSC 8, so a link a
program *declares* is a link, rather than one a regex over the visible text
guessed at.

## What this cost

- **The exit screen had to be refused.** Telling the session its process exited
  makes Ghostty paint "Ghostty failed to launch the requested command … Press
  any key to close the window" over the pane. Neither half is true here: Relay
  launched the command, and no key closes anything. The lane's own `EXITED`
  chip says it in this app's vocabulary, so the exit is not forwarded.
- **A missing controller fails silently.** A `TerminalView` with no
  `TerminalController` never builds a surface and renders black while bytes
  arrive normally — the header keeps reporting throughput. The only trace is a
  lifecycle log line reading `surface rebuild skipped: missing controller`.
- **The resize callback's cell size is zero** on the first report and then goes
  quiet, so the ⌘-click geometry works the cell size back out of the grid. See
  `ClickableTerminalView.cell(at:columns:rows:viewSize:padding:)`.
- **Scrollback is viewport-only.** `readViewportText()` reads the visible rows
  by design and ignores history, so the §7.5 search index is fed from the live
  stream plus whatever is on screen — where SwiftTerm could be walked backwards
  through its buffer.

## What was rejected

**Staying on SwiftTerm.** The reflow bug that started this — a pane dragged
wider not re-wrapping its text — is exactly the class of problem that keeps
coming back when the emulator is the part you maintain.

**One controller per pane.** A controller owns a libghostty app; per-pane would
stand up a renderer and an event loop for each lane, and every pane here wants
the same font and the same palette. Surfaces are minted from a controller, and
one controller mints as many as the strip has.

## What would make us revisit

- libghostty-spm falling behind upstream Ghostty, or its XCFramework not
  shipping a slice the app needs.
- Needing real scrollback in-process — for search, or for a pane that outlives
  its session — beyond what the live stream gives.
