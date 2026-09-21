# ADR 0026 — A risky paste asks first, in a sheet over the pane; bracketed paste stays off; every paste leaves in paced pieces

**Status:** Accepted · 2026-09-20
**Decides:** what protects a prompt from a paste that presses Return, given
that Max Pane never sends bracketed-paste markers; which pastes are held for a
question and what the question offers; and how the bytes of any paste leave,
given pty-hosts that drop what does not fit their PTY in one write.
**Evidence:** the work item [`docs/work/paste-confirm-sheet.md`](../work/paste-confirm-sheet.md);
`TerminalPaste.swift`, whose header comment is the standing argument against
the markers; `PasteConfirmTests.swift`; the runs under
`spikes/m7-remote-relay/out/paste-chunked/`; the render sheet
`paste-ask-sheet-*.png` from `./scripts/test.sh shots`.

## The facts

1. `TerminalPaste` sends **no bracketed-paste markers, ever**. The local
   emulator's belief about DECSET 2004 at the far end of a socket is a guess
   (the mode can be set before attach, fall outside the 256 KiB replay, or be
   lost when a surface is rebuilt), and the two ways of being wrong are not
   symmetric: markers sent to a program that did not ask for them arrive as
   text, `[200~…`, on the owner's prompt. That is settled and this ADR does
   not reopen it.
2. The cost, which is what this ADR is about: **every interior newline in a
   paste is the Return key.** Five lines copied from a README, and four have
   run before the first has been read. A pasted tab asks a shell for
   completion. iTerm guards this with bracketed paste *and* a warning; Max Pane
   had neither.
3. A pty-host older than relay-tty 1.23 wrote each input message to its
   non-blocking PTY once and dropped what did not fit: on macOS, everything
   past 1 022 bytes. A session keeps the pty-host it was started with, and
   nothing on the wire says which kind it is.

## Decision

### 1. A sheet, not the markers

Bracketed paste would hand the decision to the program at the far end, which is
the right place for it when the terminal knows the program asked. This one
cannot know (fact 1), so the decision goes to the only party that does know
what they meant: the person, **before** a byte is sent. A sheet that sends
nothing until it is answered cannot be wrong about the far end's modes, because
it does not depend on them.

If relay-tty ever reports the PTY's modes in its handshake, the markers become
knowable rather than guessed, and that is the moment to reopen this: the sheet
would stay for the cases bracketed paste does not cover (a program that never
asked), and stop asking where the far end will hold the paste itself.

### 2. Which pastes ask (`TerminalPaste.asksFirst`)

Measured on the bytes that would go out, so a trailing newline — which is
dropped — never makes one line two:

- an **interior line ending** (`paste_confirm_multiline`, default true);
- a **tab** (`paste_confirm_tabs`, default true);
- **more than `paste_confirm_bytes`** bytes (default 16 384; 0 never asks).

All three are read at each paste, not at launch. A Finder-files paste is
space-separated shell words and a name with a control character is left out
before it gets here, so it can only ever ask for its size.

### 3. What the sheet is

`PasteAskSheet`, over the pane it is about (a scrim and a square panel pinned
to the top, `WebAskSheet`'s shape for `WebAskSheet`'s reasons), modal to
nothing: other lanes keep working. It shows the line and byte count, one line
per thing that is unusual, and the first eight lines **as they will be sent**,
in the terminal font, control characters as control pictures (`␉`, `␛`).

- **The default is Cancel**, and both ↩ and Esc press it. Return is the key the
  sheet exists to keep from being pressed by accident; it cannot be the key
  that sends five lines to a shell. Sending takes a letter, shown on the
  button: **P** Paste, **O** Paste as One Line, **T** Tabs to Spaces.
- **Paste as One Line** joins lines with one space; a line ending in an odd
  number of backslashes is a continuation and is joined as the shell joins it
  (backslash and newline removed, no space); empty lines are dropped. Offered
  only when there are several lines.
- **Tabs to Spaces** is a toggle (`paste_tab_width`, default 4; a fixed width,
  not tab stops), offered only when there are tabs. The counts and preview
  follow it.
- It remembers nothing. One sheet at a time per pane: a second paste while one
  is a question is ignored, neither queued nor taken as an answer. A pane torn
  down under its sheet sends nothing.
- **⌥⌘V, Paste Without Asking** (`Command.pasteWithoutAsking`, Edit menu,
  rebindable under `[keys]`) is the same paste with the question skipped once.
  It travels the responder chain as ⌘V does, so it is live exactly when a
  terminal has the keyboard.

### 4. Every paste leaves in pieces, paced, with no setting

Not just pastes: everything a pane sends goes through `PacedInput` in the
attachment adapter — typing, pastes, input held while disconnected and flushed
on reconnect — as `DATA` messages of **at most 1 000 bytes, cut on UTF-8
boundaries (`InputChunks`), at most one per 5 ms**, from one FIFO. What is
typed during a long paste goes out after it and never inside it. The first
piece of anything leaves at once, so a keystroke pays nothing.

The gap is what makes the pieces worth cutting. Against a pty-host built from
the commit before the 1.23 fix, on this Mac: unpaced 1 000-byte pieces lost
two thirds of 64 KB; a 1 ms gap was enough for a reader taking big reads and
not for one reading a byte at a time, which is what a line editor does; 5 ms
delivered 256 KB whole to both. On relay-tty 1.23.0, 1 048 576 bytes went as
1 049 messages in 7.1 s to a local session and 7.2 s through the relaytty.com
tunnel, whole, sha256 equal. 200 KB/s is about three times iTerm's default
paste speed. A paste that will take a second or more says so in the pane's
notice line.

The pacer lives below the hold-while-disconnected buffer, not above it, so a
paste into a lane whose socket is not up yet is still held or dropped whole
(`PendingInput`'s all-or-nothing rule), and what remains of a paste when the
wire goes is handed back to that buffer under the same rules.

## Consequences

- A 1 MB paste takes seven seconds where a 1.23 pty-host would have taken it
  at once. That is the price of not knowing which pty-host a session has, paid
  only by large pastes. If relay-tty reports its pty-host's version per
  session, the gap can drop to zero for 1.23 and later.
- `paste-special`'s Paste Slowly is this pacer with a smaller piece and a
  longer gap; `paste-text-hygiene` tidies before `asksFirst` is consulted, so
  the sheet shows what will be sent; middle-click and the history picker come
  through the same `paste(_:asking:)`.
- In a gathered view Esc leaves gather view before it reaches the sheet, as it
  does for every other first responder; the second Esc cancels.
