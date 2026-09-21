# Pasted text is tidied when it obviously should be: smart punctuation, a copied prompt, stray whitespace

## Problem

Commands copied from Slack, Notion, Docs or a web page arrive with curly
quotes and long dashes that make a shell fail in ways that look like typos
(`–-flag`, `“path”`). Docs prefix commands with `$ `. Copies drag leading and
trailing blank space along. iTerm offers these as Advanced Paste transforms;
here they should mostly just happen, and say that they did.

## Acceptance Criteria

- **Straighten smart punctuation** when present: `“ ” „ ‟` → `"`, `‘ ’ ‚ ‛` →
  `'`, `–` `—` → `-` (an em dash between two option-looking tokens is `--`:
  `—force` → `--force`; state the rule and test it), `…` → `...`,
  non-breaking and other Unicode spaces → a space, zero-width characters
  removed. **Only outside of text that is clearly prose**: apply when the
  paste is a single line, or every line looks like a command; otherwise leave
  it. Define "looks like a command" as a pure predicate and test both sides.
- **Strip a leading prompt** `$ ` or `% ` or `# ` (with the space) from each
  line when *every* non-empty line has the same one. Never `> `.
- **Trim** leading blank lines and trailing whitespace on each line; leading
  indentation is kept (it is a heredoc or Python).
- **It says so:** a one-line notice in the pane, e.g. `pasted · straightened 4
  quotes · removed "$ "`, with **⌘Z-style undo for one keystroke-second**: the
  notice has an `as copied` action that, if nothing else has been typed,
  erases what was pasted (send that many backspaces only if the far end echoed
  exactly the pasted bytes; otherwise the action is absent) and pastes the
  original. If that is not reliable, ship without the undo and say why.
- Setting `paste_tidy = true`. ⌥⌘V (Paste Without Asking, from the confirm
  sheet task; create it here if that task has not landed) also skips tidying.
- Order with the confirm sheet: tidy first, then decide whether to ask, and
  the sheet shows what will actually be sent.
- Tests: each rule, the prose guard, the prompt rule's all-lines condition,
  indentation kept, idempotence (tidying twice changes nothing).

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
