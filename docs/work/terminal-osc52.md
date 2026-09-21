# OSC 52: a program in the terminal can set the clipboard, and may ask to read it

## Problem

tmux, vim, neovim and many CLIs copy to the *local* clipboard over ssh with
OSC 52. In a remote lane it is the only way a yank on the far machine reaches
this Mac. Status today, read from the code and not yet tested:

- libghostty parses OSC 52 and raises
  `GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE` / `_READ`
  (`.build/checkouts/libghostty-spm/…/Surface/TerminalSurfaceViewDelegate.swift:55-57`)
  through `TerminalSurfaceClipboardConfirmationDelegate`. **Max Pane does not
  implement that delegate**, so find out what happens now: written silently,
  dropped silently, or asked of nobody.
- relay-tty forwards a `CLIPBOARD (0x16)` frame over WebSocket between clients
  of a session; `RelaySession.handle` ignores it (`RelaySession.swift`, the
  `break // NOTIFICATION/CLIPBOARD/…` arm). Decide whether that frame is a
  second source (the web app copying) and whether to honour it.

## Acceptance Criteria

- First, a finding: what OSC 52 write and read do today in a local and a
  remote lane, with evidence (`printf "\\033]52;c;$(printf hello | base64)\\a"`
  and a read request), written into the ADR.
- **Write** (program sets the clipboard): allowed by default, setting
  `osc52_write = "allow" | "ask" | "deny"` (default `allow`, which is what
  iTerm users turn on and what makes tmux/nvim usable). Capped at 1 MiB.
  When it happens, the lane header shows a brief `COPIED` chip (green family,
  fades) so a program changing your clipboard is never invisible.
- **Read** (program asks for the clipboard): **ask every time by default**,
  `osc52_read = "ask" | "deny" | "allow"` (default `ask`). The sheet names the
  lane, the program if known, and shows what would be handed over, truncated.
  A remote lane says which server. Deny is the default button. This is a data
  exfiltration channel; say so in the ADR.
- `copy_on_select = false` (the owner's default) must not disable OSC 52: they
  are different things. Test that.
- The relay `CLIPBOARD` frame: implement or explicitly refuse, with the reason
  in the ADR; if implemented it obeys the same `osc52_write` setting.
- Tests on a real Ghostty surface: a write lands on a private pasteboard
  (inject it; never the general one), a read asks and a denial returns
  nothing, the cap, each setting value.
- ADR (required).

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
