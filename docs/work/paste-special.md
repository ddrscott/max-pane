# Edit › Paste Special: escaped, base64, a file as base64, slowly

## Problem

iTerm's Paste Special submenu is how people move awkward content through a
terminal: text that must not be interpreted, a small file onto a box with no
scp, input for something that drops characters when fed fast.

## Acceptance Criteria

An **Edit › Paste Special ▸** submenu, each item a rebindable command with no
default key except where stated:

- **Paste Escaped** (⌃⌘V): the clipboard text as one shell word, using the
  quoting function from `paste-file-paths.md` (double quotes, `\\ " $ `` ` ``
  escaped; single quotes when it contains `!`; newlines inside are kept inside
  the quotes and therefore do *not* run anything, so this never triggers the
  confirm sheet).
- **Paste as Base64** and **Paste Base64-Decoded**: text ↔ standard base64, no
  line wrapping on encode; decode refuses non-base64 and non-UTF-8 results with
  one line.
- **Paste File as Base64…**: an open panel (or the file URLs on the clipboard
  when there are any), pastes `base64 -d > "NAME" <<'EOF'` … `EOF` wrapped at
  76 columns, *without* the final Return, so the owner sees it before it runs.
  Refuses above 5 MB. Goes through the chunker. This is the no-scp way onto a
  remote lane until upload lands; say that in the README.
- **Paste Slowly**: the same bytes as ⌘V in chunks of 16 bytes with a 10 ms
  gap (`paste_slow_chunk`, `paste_slow_delay_ms`), cancellable with Esc, with a
  progress line in the pane's notice area. Typing during it cancels it.
- **Paste Without Asking** (⌥⌘V) lives here too if an earlier task made it.
- Tests: each transform as a pure function; the heredoc for a name with
  spaces and for a file whose content contains a line `EOF` (choose a delimiter
  that does not occur); slow paste cancels and sends nothing after.

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
