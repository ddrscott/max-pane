# Middle-click pastes in a terminal

## Problem

Nothing handles a middle click in a terminal pane (`ClickableTerminalView`
overrides only `mouseDown`). iTerm pastes on middle click; X11 habit, and the
owner's hands expect it.

## Acceptance Criteria

- A middle click (`otherMouseDown`, button 2) in a terminal pane pastes. What
  it pastes, in order: this pane's current selection if it has one (the X11
  primary-selection behaviour, within one pane and without touching the
  clipboard: this is what makes `copy_on_select = false` liveable); otherwise
  the general clipboard.
- **Not when the program wants the mouse:** if the terminal has mouse
  reporting on (tmux, vim with `mouse=a`), the click belongs to the program,
  as left clicks already do. ⌥-middle-click forces the paste, matching how ⌥
  forces selection.
- The strip already uses middle-click on a *link* in a web pane and ⌘-click in
  terminals; a middle click on a URL or path token in a terminal still pastes
  (do not open). Say so in the README.
- It goes through the same paste path as ⌘V: tidy, confirm sheet, chunking.
- Setting `middle_click_paste = true`.
- Tests: the routing decision as a pure function (selection / clipboard /
  reported to the program / ⌥ override), and that it reaches `TerminalPaste`.

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
