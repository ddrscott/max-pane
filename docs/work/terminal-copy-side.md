# Copying out of a terminal: clean text, styled text, and a keyboard copy mode

## Problem

The other half of leaving iTerm. With `copy_on_select` off, ⌘C is the way out,
and what it puts on the clipboard should be what you meant. iTerm offers copy
without trailing whitespace, copy with styles, and a keyboard-driven copy mode.

## Acceptance Criteria

- **What ⌘C copies today**, stated first with evidence (a selection spanning a
  soft-wrapped line; a selection with trailing spaces; a rectangular
  selection if libghostty has one): does a wrapped line copy as one line?
  Are trailing spaces kept? Write the findings into the README.
- **Clean by default:** trailing whitespace trimmed per line, soft wraps
  joined, a final newline not added. Setting `copy_trim_trailing = true`.
- **Edit › Copy with Styles** (⌥⌘C): RTF and HTML flavours alongside plain
  text, with the terminal's colours and font, for pasting a session into a
  doc or a bug report. If libghostty does not expose styled selection text,
  say so, reject this bullet only, and leave the rest.
- **Copy mode** (⇧⌘C to enter, Esc or `q` to leave): a keyboard cursor in the
  scrollback: `h j k l`, `w b`, `0 $`, `g G`, ⌃U/⌃D, `v` to start a
  selection, `V` line-wise, `y` or ↩ to copy and leave, `/` to find. A
  `COPY MODE` chip in the lane header (green family). Keys never reach the
  pty while it is on. If libghostty's API cannot move a selection from the
  outside (ADR-0009 notes scrollback is viewport-only), say exactly what is
  missing, build what is possible within the viewport, and record the rest as
  a reason to revisit in ADR-0009.
- Tests: the trim/join as pure functions on captured cell text; copy mode's
  key table as a pure state machine; that the pty receives nothing while in
  copy mode.
- ADR where a libghostty limit shaped the result.

## Constraints

- The goal behind all of the paste tasks (the owner, 2026-09-20): *"one of my
  goals is to stop needing iTerm at all as my daily driver."* Match what iTerm
  does where it does it well; do not copy its dialogs where a quieter answer
  fits this app.
- `TerminalPaste`'s header comment is law: **no bracketed-paste markers, ever**,
  and a paste never ends in Return. Read it before touching anything.
- Everything that decides what bytes go out is a pure function in
  `TerminalPaste` with the pasteboard injected; tests use a private named
  `NSPasteboard` and never write to `NSPasteboard.general`.
- Identity: square corners, greens for state, grey at rest, Signal Orange only
  for DONE, no instant transitions (`Motion.*`, Reduce Motion lands at once).
  New sheets follow `ConfirmPopup` / `WebAskSheet`, not `NSAlert`.
- Every new command goes in `Commands.swift`, is rebindable through `[keys]`,
  and is listed in the ⌘/ sheet and the Edit menu.
- Works the same in a remote lane (a session on a relay server) unless the
  task says otherwise.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- README (there is no terminal paste section yet; the first of these tasks to
  land creates "Pasting into a terminal" and the rest extend it), CHANGELOG,
  and an ADR only where a decision was made that someone will want to reopen.
