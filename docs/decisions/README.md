# Decisions

One ADR per open decision in PRD §14, written before the affected component is
implemented (PRD §0.7).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-swiftterm-over-web-terminal.md) | SwiftTerm vs. Relay's web terminal in a `WKWebView` | Accepted |
| [0002](0002-uniffi-over-cbindgen.md) | uniffi vs. cbindgen for the FFI | Accepted |
| [0003](0003-website-data-store-sharding.md) | How many `WKWebsiteDataStore`s, and the assignment rule | Accepted |
| [0004](0004-strip-view-strategy.md) | Virtualized strip (`NSCollectionView`) vs. `NSScrollView` with manual recycling | Accepted |
| [0005](0005-cwd-for-relay-sessions.md) | How cwd is obtained for Relay sessions | Accepted |
| [0006](0006-placeholder-snapshots.md) | Snapshot format and resolution for placeholders | Accepted |
| [0007](0007-terminal-panes-never-resize-the-pty.md) | Terminal panes never resize the PTY (**amends PRD §11**) | Accepted |
| [0008](0008-no-multi-display-yet.md) | Multi-display is not built (PRD §13 Phase 3 is gated) | Accepted |
| [0009](0009-libghostty-over-swiftterm.md) | libghostty replaces SwiftTerm as the emulator (**supersedes 0001**) | Accepted |
| [0010](0010-docking-takes-the-word-pinned.md) | Docking takes the word "pinned"; the eviction flag becomes `keep_live` | Accepted |
| [0011](0011-gallery-layout.md) | The gallery: a tile is its lane under a transform; docks, gather, eviction and Esc in it | Accepted |
| [0012](0012-in-house-toml-line-editor.md) | `config.toml` is edited by a line editor in Swift, not `toml_edit` over uniffi | Accepted |
| [0013](0013-web-popups-are-dialogs.md) | A web page's popup is a dialog over the window, never a lane (**amends PRD §9**) | Accepted |
| [0014](0014-web-full-screen-fills-the-pane.md) | A page's full screen fills its pane; ⇧ or a second request goes to the display | Accepted |
| [0015](0015-one-green-family.md) | One green family instead of Signal Orange; BLOCKED is the brightest green and pulses (**overrides the owner's global accent for this project**) | Accepted |
| [0016](0016-private-lanes-live-in-the-ledger-until-open.md) | A private lane is a ledger row until the next open; its jar is non-persistent and its visits, session and passwords are never written | Accepted |
| [0018](0018-macos-only.md) | macOS only; Linux and Windows are not planned (0017 is reserved for the passkeys capability) | Accepted |
| [0019](0019-maximize-pane-is-an-overlay.md) | A maximized pane (⇧⌘↩) is lifted over the strip and the lane never widens; the rule for showing a pane larger than its lane, the PTY told one size per toggle, and what restores it | Accepted |
| [0020](0020-a-session-belongs-to-a-server.md) | A session belongs to a server and is keyed on `(server, id)`, never a synthesised id; the local server is implicit and never named; a remote project root is `host:path` | Accepted |
| [0021](0021-servers-are-a-pasted-url-and-a-keychain-item.md) | A remote server is added by pasting the one line its server printed; the token lives in the Keychain and nowhere else; `[[servers]]` applies live through the config store, from the window, the CLI and a hand edit alike | Accepted |
| [0022](0022-a-remote-spawn-sends-the-wrapper-and-the-cwd-is-the-root.md) | A remote spawn is `POST /api/sessions` carrying the no-`exec` wrapper through `$SHELL`, so a remote agent can be BLOCKED; a line runs where the focused lane is unless `@server` says otherwise; a remote project root is `host:` plus the cwd itself, with no git walk | Accepted |
| [0023](0023-one-truth-per-server-and-the-server-chip.md) | A server's state is one truth held by the registry and stamped on its sessions, so a dead server shows at once on its header, rows, lanes, tiles and counts; silent death is noticed in ≤ 13.5 s (4 s timeout, two failures, a ping on `/ws/events`) and a lane and the list tell each other; offline typing is not sent and the banner says so; the one mark of a remote session is the server chip, and the path stops repeating the server | Accepted |
| [0024](0024-a-folded-sidebar-group-hides-its-lanes.md) | Folding a sidebar group, a server's group or a section hides its lanes from the strip and the gallery; the hidden set is lane ids in the core beside the gather filter, not a generalisation of it, because a sidebar group is a session's cwd and not a tag; persisted in `app_state`; hidden is not closed (controllers kept, planned for as far away); the lane with the keyboard is never hidden by a recount, and every door that reaches a lane opens the fold first (**amends 0023**: sections fold by their triangle) | Accepted |
| [0025](0025-a-server-has-a-colour.md) | A remote server has one of eight colours (`color` on its `[[servers]]` table, auto-assigned, live), and a small solid square in it is the mark of that server's sessions; the name chip stays, tinted, only where no section names the server (lane header, gallery tile, ⌘O, ⌘P); hollow when offline; picked from a right-click menu on the sidebar header, Settings' swatches or `maxpane server color`. Identity, never state: a stated exception to 0015, held to ΔE 40 from every green and from DONE (**amends 0023**: the grey chip on every row; **amends 0015**) | Accepted |
| [0026](0026-a-risky-paste-asks-first.md) | A paste with an interior line ending, a tab, or more than `paste_confirm_bytes` asks first, in a sheet over its pane whose default (↩ and Esc) is Cancel; Paste, Paste as One Line and Tabs to Spaces take a letter; ⌥⌘V skips it once. A sheet rather than bracketed paste because the far end's mode is a guess (`TerminalPaste`) and the person's intent is not. Everything a pane sends leaves as ≤1 000-byte `DATA` messages on UTF-8 boundaries, one per 5 ms, from one FIFO: measured against a pre-1.23 pty-host, which drops what its PTY cannot take in one write | Accepted |
| [0027](0027-a-pasted-picture-becomes-a-path.md) | ⌘V of a clipboard holding a picture and neither files nor text writes a PNG and pastes its quoted path: in the profile's Caches for a local session, and for a remote one uploaded through relay-tty's `POST /api/upload` into the server's own upload directory, with the server's path pasted and no copy kept here. Files win over text and text over a picture. A failed upload pastes nothing. The first piece of remote Phase 4 | Accepted |
| [0028](0028-a-program-may-set-the-clipboard-and-must-ask-to-read-it.md) | OSC 52. Found: pty-host lifts it out of the stream, so a program's copy arrived as relay's `CLIPBOARD (0x16)` frame and was dropped, and a read query is eaten unanswered; bytes that did reach Ghostty were written to the clipboard silently and reads denied with nobody asked. Now `osc52_write` (default `allow`, 1 MiB, a `COPIED` chip in the lane header) and `osc52_read` (default `ask` every time, Deny on ↩, Allow only by ⌥A or a click, because a program raised the sheet). The `CLIPBOARD` frame is implemented as the write path under the same setting; Ghostty is told `ask` both ways so the pane decides live, and the pane, never the library, writes the pasteboard | Accepted |
| [0029](0029-pasted-text-is-tidied-unless-it-is-clearly-prose.md) | Copied text is tidied on its way into a terminal: smart quotes, long dashes, `…`, odd spaces and zero-width characters straightened unless the paste is several lines and one of them does not look like a command (a stated predicate); a long dash that starts a word before a letter is `--`, any other `-`; a `$ ` `% ` `# ` prompt off every line only when every line has it and what is left is command-shaped; trailing whitespace and leading blank lines trimmed. Tidy first, then decide whether to ask. The pane says what it did; ⌥⌘V and `paste_tidy = false` skip it. No undo: the far end's echo is never the bytes that went in | Accepted |
| [0030](0030-paste-special-is-five-pure-transforms-and-one-queue.md) | Edit › Paste Special. Five pure transforms in `TerminalPaste`. Paste Escaped is `shellWord`'s rule with a newline kept inside the quotes (an open quote runs nothing, so it never asks) and `$'…'` with every control character written out when there is a tab, an escape or a ^C. The base64 heredoc ends with no Return, skips the sheet, and checks its delimiter against the body. Paste Slowly is a marked stretch of `PacedInput`'s one buffer, not a second queue: cancel removes its unsent bytes and nothing else, Esc is swallowed, typing cancels and follows, a dropped wire cancels | Accepted |
| [0031](0031-paste-history-is-what-terminals-pasted-and-copied-never-the-clipboard.md) | Paste history (⇧⌘H). Only what a terminal pane sent to a prompt or copied out; the system clipboard is never polled, which is the line between this and a keylogger. Recorded at `send(pasted:record:)` as the text sent; a cancelled sheet and Paste File as Base64 record nothing. A pasteboard marked Concealed/Transient/AutoGenerated sets `doNotRecord` as it is read. `Ledger::record_clip` refuses a private lane's pane, an unknown pane, blank text and over 64 KB, and stores secret-shaped text (`sk-`, `ghp_`, `AKIA`, PEM, JWT, Slack, GitLab) as four characters and `•••`. Table `clip`, migration 0016, capped by count and age, `secure_delete` on the deletes a person asks for | Accepted |

Each ADR states the decision, what evidence decided it (usually a spike, by
number), what was rejected and why, and what would make us revisit.

ADR-0009 is not one of §14's open decisions either. It supersedes ADR-0001's
choice of emulator, which §14 did ask about — the rejected alternative there
(Relay's web terminal in a `WKWebView`) is still rejected, for the same reasons.

ADR-0010 is not one of §14's open decisions either. It settles a name collision
between an existing field and a feature the owner named after it, which had to
be decided before either half of docking could be built.

ADR-0007 is not one of §14's open decisions. It records a PRD requirement that
turned out to contradict the system it depends on, surfaced per §0.6 rather than
quietly reinterpreted. [`docs/acceptance.md`](../acceptance.md) tabulates every
such conflict.
