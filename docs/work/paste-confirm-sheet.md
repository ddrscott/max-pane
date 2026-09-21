# A risky paste asks first: several lines, tabs at a prompt, or a lot of bytes

## Problem

Max Pane never sends bracketed-paste markers (deliberately: it cannot know the
far end's mode). The cost is that **every interior newline in a paste runs its
line the moment it lands.** Paste five lines copied from a README and four of
them have executed before you have read the first. iTerm guards this with
bracketed paste plus a warning; Max Pane has neither. A pasted tab triggers
shell completion. And a very large paste goes out as one write: pty-hosts
older than relay-tty 1.23 dropped everything past ~1 KB of a single DATA
message, and a session keeps the pty-host it was started with.

## Acceptance Criteria

- **A sheet over the pane** (not a window-modal alert) before a paste goes out
  when any of these holds: it contains an interior line ending; it contains a
  tab; it is larger than `paste_confirm_bytes` (default 16 384). It shows: the
  line count and byte count, the first ~8 lines in the terminal font with
  control characters made visible, and what is unusual in one line each.
- **Choices**, keyboard first: **Paste** (↩ is *not* the default; the default
  is the safe one) sends as is; **Paste as One Line** joins lines with a space
  (a trailing `\` continuation is respected: `\`+newline is removed); **Tabs to
  Spaces** toggle when there are tabs (4, or `paste_tab_width`); **Cancel**
  (Esc, and the default). Remember nothing between pastes.
- **Settings:** `paste_confirm_multiline` (default true),
  `paste_confirm_tabs` (default true), `paste_confirm_bytes` (0 = never).
  ⌥⌘V, "Paste Without Asking", skips the sheet once.
- **Chunked sending, always, no setting:** a paste goes to the session in
  chunks of at most 1 000 bytes on UTF-8 boundaries, in order, through the same
  outbound path keystrokes use, so typing during a long paste cannot interleave
  mid-chunk. State the pacing chosen and measure a 1 MB paste against a local
  and a remote session (the box in `remote-relay-spike.md`): arrives whole,
  sha256 equal.
- The Finder-files paste (`paste-file-paths.md`) never triggers the sheet for
  its own separators.
- Tests: the predicate (which pastes ask), each transform as a pure function,
  the chunker's boundaries on multi-byte text, that a cancelled paste sends
  nothing, that ⌥⌘V bypasses.
- ADR: why a sheet rather than bracketed paste, referencing `TerminalPaste`.

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
