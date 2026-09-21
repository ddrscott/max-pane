# ADR 0030 — Paste Special is five pure transforms, and Paste Slowly is a stretch of the one input queue

**Status:** Accepted · 2026-09-20
**Decides:** how Paste Escaped quotes text that holds control characters; what
ends a base64 heredoc and why it has no final Return; and where a slow paste is
paced and cancelled.
**Evidence:** the work item [`docs/work/paste-special.md`](../work/paste-special.md);
the `// MARK: - paste special` section of `TerminalPaste.swift`; `PacedInput` in
`TerminalOutbound.swift`; `PasteSpecialTests.swift`.

## The facts

1. There is no bracketed paste (ADR-0026). Whatever is pasted is typed: a
   newline is Return, a tab asks a shell for completion, ^C abandons the line.
2. `shellWord(for:)` quotes a *path* and refuses any control character, because
   a file name with a newline in it is a keystroke, not text. Copied text is
   the opposite case: its newlines and tabs are the content.
3. Every byte to a session leaves through one FIFO, `PacedInput`, at most
   1 000 bytes a message and one message per 5 ms, so that keystrokes and
   pastes keep the order they were made in.
4. Advanced Paste is queued behind this and will compose these transforms.

## Decision

**Each transform is a pure function in `TerminalPaste` with a stable name:**
`escaped`, `base64Encoded`, `base64Decoded`, `base64Heredoc`,
`heredocDelimiter`. The pane only picks one and picks a door.

**Paste Escaped keeps `shellWord`'s rule and takes back its refusal.** Bare,
double quotes with `\ " $` and the backtick escaped, single quotes on a `!`. A
newline stays a newline inside the quotes: it goes out as Return, the shell sees
an open quote and prints its continuation prompt, and nothing runs, which is
why this paste is never tidied and never asks. Line endings at the end are
dropped, as every paste drops them. **Any other control character switches the
whole word to `$'…'`**, with every control character written out (`\t`, `\n`,
three-digit octal for the rest, `\041` for `!`), because inside ordinary quotes
a tab is still a request for completion and ^C still abandons the line. The
cost: `$'…'` is bash, zsh and ksh, not POSIX `sh` or fish. A tab that arrives as
a tab in two shells out of three was judged better than one that arrives as a
completion menu in all of them.

**The heredoc ends without Return, and its delimiter is checked.**
`base64 -d > NAME <<'EOF'`, the body wrapped at 76, `EOF`, and then nothing: the
lines of the body each end in Return because a heredoc is read that way, and
the last Return, the one that writes the file, is the owner's. It skips the
confirm sheet, which would ask about exactly those Returns. The delimiter is
the first of `EOF`, `EOF_1`, `EOF_2`… that is not a line of the body. Base64
cannot produce the line `EOF` (its lines are multiples of four characters), so
for this caller the check never fires; it is a separate function because a line
equal to the delimiter turns the rest of a paste into commands, and the next
caller's body will not be base64. 5 MB, all files together, because a third
more than that goes out at 200 KB/s at best.

**Paste Slowly is a stretch of `PacedInput`'s own buffer**, marked with a chunk
size and a gap (`paste_slow_chunk` 16, `paste_slow_delay_ms` 10), not a second
queue. What was queued before it leaves at the usual pace, a piece never
straddles the boundary, and what is queued after it waits. Cancelling removes
the unsent part of the stretch and nothing else, so the key that cancelled it
follows what had already gone. Esc cancels and is swallowed; any other key
cancels and is delivered. A wire that drops cancels it too: held input is
flushed at full speed on reconnect, which is the one thing a slow paste said
the far end could not take. It goes straight to the attachment rather than
through the emulator's write path, which carries bytes and no way to say "these
ones slowly".

## Costs

- A slow paste sent in the same run-loop turn as a keystroke still in
  `TerminalOutbound` can overtake it. That needs a key and a menu command in
  one turn.
- Key *equivalents* (⌘-chords) do not cancel a slow paste; only `keyDown` does.
- `⌃⌘V` is Paste Escaped. Nothing else in `Commands.swift` and no macOS system
  shortcut uses it; a page in a web pane never sees it because the command is
  only live in a terminal.
