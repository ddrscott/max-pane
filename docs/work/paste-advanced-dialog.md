# Advanced Paste: one dialog that previews every transform

## Problem

iTerm's Edit › Paste Special › Advanced Paste… combines the transforms with a
live preview. By the time this task runs, Max Pane has the pieces (tidy, tabs
to spaces, one line, escaped, base64, slow). This is the place to combine and
*see* them, for the paste that needs two or three at once.

**Do this one last among the paste tasks, and only build on what has landed:**
read `TerminalPaste` and list the transforms that exist; if fewer than four
exist, reject this task with a note saying which to land first.

## Acceptance Criteria

- **Edit › Paste Special › Advanced Paste…** (⌥⇧⌘V), a sheet over the pane:
  the clipboard's content on top (editable, terminal font), a column of
  toggles for each existing transform in a fixed, stated order of application,
  a regex substitution row (pattern, replacement, `NSRegularExpression`
  syntax, invalid pattern shown inline, never thrown), and a **preview of the
  exact bytes that will be sent** with control characters made visible and the
  line/byte counts. Paste, Paste Slowly, Cancel.
- It remembers the last toggle set per app launch, not across launches, and
  never the content.
- It composes the existing pure functions; it adds none of its own except the
  regex step and the ordering. A test asserts the dialog's output equals the
  composition.
- Tests: ordering, the regex step (groups, invalid pattern, no match), preview
  equals bytes sent.

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
