# ⌘V with an image on the clipboard pastes a path to it

## Problem

A screenshot copied to the clipboard (⇧⌃⌘4, or Copy Image in a browser) has no
text flavour, so ⌘V in a terminal does nothing. The owner hands screenshots to
agents all day; Claude Code takes an image *path*. Today that means saving the
screenshot to disk first. In a remote lane it is worse: the file is on the
wrong machine.

## Acceptance Criteria

- When the pasteboard has image data (`public.png`, `public.tiff`,
  `public.jpeg`, or an `NSImage` readable from it) and **no file URLs and no
  text**, ⌘V writes it as PNG to a file and pastes that file's quoted path
  (the quoting function from `paste-file-paths.md`). File URLs still win over
  everything; text still wins over an image (a browser copy often carries
  both, and the text is what was meant). Say so in the code.
- **Where, locally:** `~/Library/Caches/app.ljs.maxpane/paste/` (per profile),
  named `paste-YYYYMMDD-HHMMSS.png`, never overwriting. Pruned on launch:
  files older than `paste_image_keep_days` (default 7) go. A one-line notice in
  the pane says what was saved and its size.
- **In a remote lane:** upload through the relay server's API, the way the
  relay-tty web app does (read `~/code/relay-tty/server/api.ts` upload and
  upload-dir endpoints and how the web client calls them; cite what you
  used), with the server's Keychain token, and paste the **remote** path the
  server returns. Off the main thread, with a notice while it uploads and one
  line naming the server on failure; the prompt gets nothing on failure. This
  is the first piece of plan Phase 4; note it in
  `docs/plans/remote-relay-servers.md`.
- Large images: refuse above `paste_image_max_mb` (default 25) with one line.
- A setting `paste_images_as_files` (default true). Off: an image-only
  clipboard pastes nothing, as today.
- Tests: the precedence (files > text > image), the PNG on disk round-trips,
  naming never collides, pruning, the remote upload against the fake relay
  server from `RemoteRelayTests`, failure pastes nothing.
- Verify by hand against the real box over the control socket if a socket op
  helps; if not, say what was not seen.

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
