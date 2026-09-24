# ADR 0041 — A web pane's ⌘C is paste history too, and a page's own copy is not

**Status:** Accepted · 2026-09-23
**Decides:** whether a copy made in a web pane is recorded, and by what
mechanism; whether a copy a *page* makes is recordable at all; what a copied
picture becomes; where the chord is taken from WebKit; what the rows say.
**Evidence:** the Omarchy critique [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F5;
the work item [`docs/work/omarchy-f5-web-clipboard.md`](../work/omarchy-f5-web-clipboard.md);
ADR-0031 (paste history is what panes pasted and copied, never the clipboard),
ADR-0027 (the pasted-picture store), ADR-0016 (private lanes);
`crates/laned-core/migrations/0018_clip_source.sql`, `clips.rs`, `ledger.rs`;
`Web/WebClipboard.swift`, `Web/WebPaneController.swift` (`WebPaneContainer`,
`WebCopyTarget`), `AppDelegate.swift` (`copyFromEditMenu`),
`Views/PasteHistoryPicker.swift`; `WebClipboardTests.swift`,
`crates/laned-core/tests/clips.rs`.

## The problem

ADR-0031 built paste history out of one fact: **the pane writes, the app never
polls.** A row exists because a *terminal* pane of this app sent those bytes to
a prompt or copied that text out of one. That is still the right line, and it
was drawn one pane kind too narrow. Copy a token off a web dashboard in a lane,
copy something else, and the first is gone — so the owner opens Raycast or
Maccy, which is a clipboard manager, which is the thing ADR-0031 exists not to
be.

## Decision

**A ⌘C the app performs in a web pane is recorded**, under `source = web`,
with every one of ADR-0031's refusals unchanged: a private lane, an unknown
pane, blank text, over 64 KB, a pasteboard carrying one of the three
nspasteboard.org marks, `paste_history = false`. Text shaped like a secret is
still four characters and `•••`, written by the same `clips::redact` inside the
same function that writes the row. None of that is re-implemented here: the
Swift side says only *which pane*, and `Ledger::record_clip` decides the rest,
which is why a web pane could not record in a private lane by forgetting to.

**The pane still writes, and the app still never polls.** Nothing added here
runs while the app is idle. `WebClipboard.whenCopyLands` exists only between
the moment this pane performed WebKit's copy and a fifth of a second later,
stops at the first change, and reads nothing if nothing changed — which is what
an empty selection looks like. Its deadline is wall clock and is checked
*before* the pasteboard is read, so a main thread that stalls comes back to
find the window closed rather than to a pasteboard somebody else has written
since. `NSPasteboard.changeCount` on a timer stays refused, and a copy made in
Safari or Mail is still never seen.

**A copy the page makes is not recorded, and is not recordable here.**
`navigator.clipboard.writeText` fires no `copy` event at all, and a
`document.execCommand('copy')` fires one the UA marks trusted, indistinguishable
at the DOM from a person's ⌘C. Recording either would mean a script in every
frame of every page reporting what the page put on the clipboard — a page
writing rows into your history without you copying anything, which is the
keylogger ADR-0031 refused, only with the page holding the pen. So the hook is
the *app's* action and nothing else. Two consequences, stated rather than
hidden: a page's "Copy to clipboard" button leaves no row (⌘C on the selection
does), and WebKit's own right-click **Copy** leaves none either, because its
context menu items are dispatched inside WebKit and never reach the responder
chain.

**The chord is taken before the web view, and the menu item before `copy:`.**
A focused `WKWebView` claims every ⌘-chord in `performKeyEquivalent` and
forwards it to the page, so `WebPaneContainer` takes ⌘C there, ahead of its
subviews — and declines unless the *page* has the keyboard, which is how the
address and find fields keep their own ⌘C. Edit › Copy is targeted at
`AppDelegate.copyFromEditMenu`, the shape Paste already had: the pane is
offered it down the responder chain (`WebCopyTarget`) and everything else still
ends at `copy:`. The copy itself is always WebKit's own, sent as `copy:` — this
app never writes the clipboard for a page. A `WKWebView` subclass could not have
done it: WebKit declares `copy:` in no header this module can see.

**A copied picture becomes a file and the row is its path**, quoted as a prompt
takes it: ADR-0027's store, `paste_image_max_mb` and the same
`paste_image_keep_days` sweep, under `copy-YYYYMMDD-HHMMSS.png`. So ⇧⌘H ↩ hands
an agent a picture you copied off a page. Text wins over a picture, as it does
for ⌘V (`TerminalPaste.clipboard`): a Copy Image that carries the address too is
the address, which is what was meant. The file is on this Mac — a web pane has
no session and so no server to upload to.

**A popup's page is never recorded.** A sign-in dialog's web view is not in a
pane container's responder chain, so it declines by construction, and a
one-time code or a password field's contents is the last thing that belongs in
a list that outlives it.

**The rows say which pane it was.** Migration 0018 adds `source` to `clip`
(`pty` for every row that existed), and every ⇧⌘H row wears a square grey
`PTY` / `WEB` chip — grey because which pane it happened in is a fact about the
row and never a state (ADR-0015), and on every row because a list where only
some rows are labelled reads as a list where the label means trouble. ↩ still
pastes into the terminal that has the keyboard.

## Consequences

- A page that copies for you — a "copy" button, a code block's clipboard icon —
  leaves nothing. The keyboard does.
- The right-click Copy item leaves nothing. If that turns out to be how the
  owner copies, the road is WebKit's menu-item identifiers, which
  `WebContextMenu` already matches for renaming and which WebKit does not
  promise.
- A pane that reads the pasteboard for a fifth of a second is reading it at all,
  which ADR-0031 did not do. What it can be wrong about is bounded to that
  window, after a copy this app performed, in the app that is frontmost.
- `copy-*.png` files accumulate like pasted ones and are swept by the same
  setting. A copied picture is written to disk without being asked for — the
  alternative was no path to keep and so no row.
