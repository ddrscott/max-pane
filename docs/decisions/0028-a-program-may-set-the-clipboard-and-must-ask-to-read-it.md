# ADR 0028 — A program may set the clipboard, and must ask to read it (OSC 52)

**Status:** Accepted · 2026-09-20
**Decides:** what happens when a program in a terminal sets or reads this Mac's
clipboard with OSC 52; which of the two roads such a request arrives by; who
writes the pasteboard; what relay's `CLIPBOARD (0x16)` frame is and whether it
is honoured; and how the person is told.
**Evidence:** the work item [`docs/work/terminal-osc52.md`](../work/terminal-osc52.md);
a real `relay-pty-host` (relay-tty 1.23.0) run under a scratch `HOME` on
2026-09-20 with its frames printed; a real Ghostty surface fed the same bytes
before this change; `Osc52Tests.swift`; relay-tty `crates/pty-host/src/main.rs:676-740`
and `:1876-1886`, `server/ws-handler.ts:99-113`, `:406-416`, `:457-464`,
`app/hooks/use-terminal-core.ts:548-560`; libghostty-spm
`Controller/TerminalController+Callbacks.swift:66-143`, `:217-270` and
`InMemory/TerminalCallbackBridge.swift:188-204`.

## The finding: what OSC 52 did before this

The work item guessed at three outcomes (written silently, dropped silently,
asked of nobody). It was two of them, by road.

**Every lane, local or remote, through a current pty-host: dropped silently,
both directions.** Every Max Pane session runs under `relay-pty-host`, and
pty-host lifts OSC 52 *out of the output stream* before any client sees it
(relay-tty 409c7e7, 2026-03-11). Run for real:

```
$ relay-pty-host probe01 80 24 . /bin/sh -c \
    'printf "\033]52;c;aGVsbG8=\a"; printf "\033]52;c;?\a"; echo after'
0x16 b'hello'        <- CLIPBOARD frame: the write, decoded, as a frame of its own
0x00 b'after\r\n'    <- DATA: neither escape sequence is in it
```

- The **write** arrives as `CLIPBOARD (0x16)`, which `RelaySession.handle`
  dropped in its `default:` arm. A yank in tmux or nvim changed nothing here
  and said nothing. Over a WebSocket the server forwards the host's frame to
  every client of the session, so a remote lane was the same.
- The **read** query is stripped by pty-host and *never answered*: no frame,
  no reply. The program waits out its own timeout. Nothing Max Pane does can
  change that; it would take a relay-tty change (see Consequences).

**Bytes that do reach Ghostty** (a session whose pty-host predates the
lifting; a session keeps the pty-host it started with): the app set neither
`clipboard-write` nor `clipboard-read`, so Ghostty's defaults applied, `allow`
and `ask`. Fed `ESC ] 52 ; c ; aGVsbG8= BEL` and then the read query, a pane's
real surface did this (the general pasteboard redirected for the test process,
holding a sentinel):

```
after write  general = "hello"                 <- written, with nothing shown
read reply   ESC ] 5 2 ; c ; ESC \             <- denied: an empty reply
```

- The **write was silent**: the library put it on `NSPasteboard.general`
  itself, no callback reached the app, `copy_on_select = false` had no bearing.
- The **read was denied with nobody asked**: `ask` goes to
  `TerminalSurfaceClipboardConfirmationDelegate`, the pane did not conform,
  and the bridge answers no for a host that does not. The program got an
  empty reply, which is at least an answer.

## Decision

1. **Two settings, read at each request.** `osc52_write = "allow" | "ask" |
   "deny"`, default `allow`: it is what makes tmux and nvim usable over ssh,
   and what iTerm users turn on. `osc52_read = "allow" | "ask" | "deny"`,
   default **`ask`, every time, remembered never**. A read is a data
   exfiltration channel: it hands whatever was last copied, a password as
   readily as a path, to whatever is running in the terminal, and from a
   remote lane to another machine. `curl | sh` is enough to be that program.
   `copy_on_select` is a different thing (a selection made *here*) and has no
   bearing on either.
2. **Relay's `CLIPBOARD` frame is implemented, because it *is* the OSC 52
   write.** It is not a second source beside it: through a current pty-host it
   is the only form a program's copy ever arrives in. `RelaySession` delivers
   it (`onClipboard`), the attachment passes it up, and it goes through the
   same door as everything else, under `osc52_write`. Over a WebSocket the
   same frame is also what *another client* sends when it copies (the relay
   web app sends one on every selection, and the server fans it out). The two
   are indistinguishable on the wire, so they are treated alike: the other
   client is the owner's own browser or phone, authenticated to his server,
   and the `COPIED` chip shows it happening. Someone who does not want a phone
   selection landing on the Mac sets `osc52_write = "ask"` or `"deny"`. Max
   Pane never *sends* the frame: copying here stays here.
3. **Ghostty is told `ask` for both, always, and the pane answers.**
   `clipboard-write = ask` and `clipboard-read = ask` are written into the
   terminals' configuration whatever the settings say. `ask` is what makes
   the library bring each request to the pane
   (`terminalDidRequestClipboardConfirmation`), and the pane decides from the
   config as it is *now*; the Ghostty configuration is built once per launch
   and could not follow a change.
4. **The pane writes the pasteboard; the library never does.** Both roads end
   at `TerminalPaneController.programSetClipboard`, which asks
   `ProgramClipboard.write` (pure) and sets the pane's injected pasteboard
   through `ProgramClipboard.set`. A write that came through Ghostty is
   answered `respond(allow: false)` after the pane has dealt with it: allowing
   it *through the library* would put it on `NSPasteboard.general` with no
   cap, no chip and no seam. One function is also the one place a later record
   of what terminals copied out (the paste-history item) is taken.
5. **Capped at 1 MiB**, measured in UTF-8 bytes. relay-tty stops there at both
   ends already, so a bigger one only ever arrives through Ghostty; it is
   refused in the pane's notice line. **An empty write is ignored**: OSC 52
   with no data asks to clear the clipboard, and no program has business doing
   that to what the person copied.
6. **Never invisible.** An allowed write shows `COPIED` in the lane header for
   two seconds, in the state chip's column and shape, outlined in the working
   green, faded in and out (`Motion.fade`; Reduce Motion lands it). It does
   not cover `BLOCKED` or a server that is not answering; when the chip is not
   free, or the pane is in no lane, the pane's own notice line says
   `a program copied 12 bytes to the clipboard` instead.
7. **The sheet** (`ClipboardAskSheet`, `PasteAskSheet`'s shape, over its own
   pane, modal to nothing) names the program when the registry knows the
   session's command, the lane by its header title, the server for a remote
   lane ("It leaves this Mac for yorkshire."), and shows what would be handed
   over: the first eight lines, control characters made visible. **Deny is
   the default: ↩ and Esc.** Unlike the paste sheet, *no bare key allows*.
   That sheet answers something the person just did; this one goes up because
   a program asked, quite possibly mid-word in the pane it covers, and the
   next letter typed must not be the one that gives the clipboard away.
   Allowing is **⌥A** or a click. For the same reason the sheet takes the
   keyboard only from its own terminal, never from another lane. One question
   at a time: a second request under an open sheet is denied, not stacked,
   and a pane torn down under one denies it. A denial reaches the program as
   Ghostty's empty reply, so it is not left waiting.

## What was not done, and why

- **No patch to the library** to hand it a pasteboard. For a read it reads
  `NSPasteboard.general` by name before the pane is asked
  (`TerminalPasteboardContent.text()`), and what the sheet shows is exactly
  what it read. The pane's `pasteboard` seam therefore covers writes only.
  Tests of a real read redirect `+[NSPasteboard generalPasteboard]` to a
  private pasteboard for the whole test process (`GeneralPasteboardStandIn`),
  which also takes `CopyOnSelectSurfaceTests` off the owner's clipboard.
- **No answering a read ourselves.** The pane could deny Ghostty and type the
  reply into the PTY from its own pasteboard. That is a second OSC 52 encoder
  to keep in step with the emulator's, to win a seam only tests want.
- **No scanning replays.** Through an old pty-host a replayed scrollback can
  carry a raw OSC 52, and attaching re-runs it: a write sets the clipboard to
  what the program copied then (what the library did silently before, now
  with a chip), a read asks. pty-host since March 2026 stores the cleaned
  stream, so this ages out with those sessions.
- **No command, no key, no menu item.** Nothing here is something the person
  starts.

## Consequences

- tmux, vim and nvim yanks reach the Mac's clipboard from local and remote
  lanes, visibly.
- **OSC 52 read still cannot work through a current pty-host**, because
  pty-host eats the query. The sheet and both settings are live for the road
  that exists (Ghostty) and ready for the other. Making it work is a relay-tty
  change (forward the query to clients, or pass it through in DATA), which is
  a proposal for `docs/proposals/`, not something this repo can do.
- A selection in the relay web app on another device lands on this clipboard
  under `allow`. That is relay's cross-device copy working as designed; the
  chip shows it and the setting stops it.
