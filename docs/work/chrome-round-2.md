# Browser chrome, round 2: the failures you cannot see

The chrome **passed** its kill criterion five for five — the URL is visible and
editable, back and reload work, and hovering a link shows where it goes. This is
what a fresh critic found anyway, ranked as it ranked them.

**Items 1–5 are done.** What is left is three things in "Smaller" that are each
their own piece of work — address-bar autocomplete, an honest find match count,
and a context menu that macOS has no public hook for — carried to their own
queue entry; two more that belong to queue entries that already exist
(bookmarks, and ⌘[ to the configurable-shortcuts work); and the zoom readout,
still disputed because settling it needs a human at the keyboard.

## 1. A navigation that fails produces no feedback of any kind — **DONE**

> `didFailProvisionalNavigation` now calls `report(_:)`, and `didFail` — the
> committed-then-came-apart case, which was not implemented at all — calls the
> same thing. `BrowserAddress.failure(domain:code:failingURL:)` turns the error
> into a short lowercase phrase plus the host it failed on, and
> `WebChromeBar.showFailure` puts `⚠ server not found — host` in the slot the
> hover target already borrows, for five seconds, and takes the hairline to
> zero. The two silences matter as much as the messages: a cancel
> (`NSURLErrorCancelled`) is what the ✕ button and a superseding navigation both
> look like from here, and `WebKitErrorDomain 102` is what a download looks
> like — reporting either would print an amber error for doing exactly what was
> asked. The hairline still comes down in both. Failure outranks the hovered
> link while it shows: a failed load leaves the *previous* page under the
> pointer, full of links to hover the message away with, and the hover answer is
> re-askable by moving the mouse where this one is not. Covered by
> `NavigationFailureTests`.

`didFailProvisionalNavigation` is an empty body. Typing
`https://no-such-host-zzz9911.example.com/page` and pressing Return leaves the
page unchanged and snaps the URL bar back — **indistinguishable from the app
having ignored the keystroke.**

Worse, the green progress hairline then stays on screen forever. Watched for
25+ seconds: the bar draws while `0.001 < progress < 0.999` and a failed load
parks `estimatedProgress` at ~0.15, while `isLoading` has already gone false, so
the ✕ has reverted to ↻ and there is nothing left to cancel.

The fix the critic proposed, which is a good one: on failure reset progress to
zero and write the error into the URL slot for a few seconds — `⚠ server not
found — no-such-host-zzz9911.example.com` — in the same slot the hover target
already borrows. The substitution mechanism exists; it just has a third thing to
say.

## 2. Public-internet `http://` does not load at all — **DONE**

> `NSAllowsArbitraryLoadsInWebContent=true` alongside the existing
> `NSAllowsArbitraryLoads=false`. That is the narrow key: it lifts ATS for
> WKWebView only, and every connection the app itself makes stays under the
> strict one. The answer to the question the ticket asks is no — a developer's
> browser that silently refuses old vendor docs and an internal service behind a
> tunnel is worse than one that loads them with a warning, and the warning
> already exists and already tested well. Nothing about the ⚠ changed. Both keys
> are asserted by `QuietChromeTests`, reading the real `Resources/Info.plist`,
> because the failure mode here is silence and a deleted key looks like nothing.

`NSAllowsArbitraryLoads=false` in the Info.plist. `http://example.com/` — which
`curl` fetches with 200 from this machine — silently does nothing, and because
of #1 there is no clue why.

What is already right and should not be broken fixing this: **LAN http works**
(`http://192.168.68.50:8731/lan` loaded) with an amber ⚠ before the URL, the ⚠
appears live while you are still typing an `http://` address, and loopback loads
with no warning at all. So the warning design is correct. The question is only
whether a developer's browser should refuse plain http to the public internet —
old docs, a vendor page, an internal service reached through a tunnel — and if
it should not, ATS needs an exception with the ⚠ carrying the weight.

## 3. ⌘L is dead, and the comment saying it is taken is stale — **DONE**

> Landed out of order, with the dock-width fix, because the owner asked for it
> directly mid-task. `Command.editAddress` is declared (⌘L, Navigate menu), the
> pane seam is `PaneController.editAddress()`, and Escape now hands the keyboard
> back to the page instead of to the window. Greyed out on a terminal pane
> rather than beeping, the way "Resize Session to This Lane…" is greyed out on a
> page. Verified by `AddressBarTests`, not by a live keypress: the owner's own
> instance held the front and input was aborted rather than risked. **The rest
> of this ticket is untouched.**

Four attempts, two fresh instances, both focus states: nothing. There is no
`focusAddressBar` in `Commands.swift`. The comment in `WebPaneController` says
⌘L "already means something else here (`newWebLane`)" — it does not; that
binding is gone. **The key is free.**

⌘O is not a substitute: its header reads "→ new lane", because it *adds* a lane
rather than retargeting the one you are reading. So "change where this lane
points" is currently mouse-only.

## 4. ⌘-click and middle-click navigate in place — **DONE**

> `LinkClick.outcome(navigationType:modifiers:buttonNumber:)` reads the click,
> and the existing `decidePolicyFor navigationAction` in `WebPaneAsks.swift`
> acts on it — *that* one, extended, rather than a second copy in another
> extension of the same class, which compiles and then silently wins or loses at
> runtime and takes downloads or ⌘-click with it. A sibling lane is `.cancel`
> plus `newWebLane(near:)` plus a reveal: the same path `target=_blank` already
> takes, as the ticket says, so the lane inherits this one's tag and its ordinal
> placement. Only `.linkActivated` qualifies — a form submission carries state
> the server is waiting for and opening it elsewhere would post it twice — and
> ⌃⌘ and ⌥⌘ are left to the system, which already owns them for right-click and
> download-linked-file. Middle-click needs no modifier. Covered by
> `LinkClickTests`. **Not verified by a live click**: the owner's own instance
> held the front and input was aborted rather than risked.

Confirmed on two instances — `maxpane ls` showed one pane before and after, only
the title changed. The critic's words: *this is the expensive kind: you reach
for "keep my place, open a sibling" and instead you lose your place.*

The capability is already built and correct — WebKit's own context menu item
"Open Link in New Window" produces `window.open … → popup → materialize lane`
and a new lane to the right. Only the modifiers are not wired to it.

## 5. An untitled page keeps the previous page's title — **DONE**

> `didFinish` with an empty title now schedules `BrowserAddress.laneLabel(for:)`
> — host, port and path, without the scheme, `www.` or the query. The port and
> the path are the half that matters here: the host alone makes `/api/users` and
> `/api/orders` the same lane, and two dev servers on one machine differ only by
> port.
>
> It is delayed 400 ms and applied only if the title is *still* empty and the
> page is *still* the same one, and the delay is the design rather than an
> accident. `didFinish` is the document being done, not its `<title>` having
> landed — that routinely arrives a beat later, which is the whole reason
> `titleObservation` exists — so labelling on the spot would flash the bare host
> on every titled page on the way past, twenty times an hour. Nothing waits on
> it that is not already wrong: until it fires the header is showing the
> previous page's title, which is the bug. Covered by `LaneLabelTests`.

`adoptTitle` early-returns on an empty title, so five navigations through pages
with no `<title>` left the header reading `Computer program – Wikipedia`. This
owner's lanes hold localhost dev servers, raw JSON and text files, and the lane
header is what he scans across six columns. Falling back to host plus path would
fix it.

## 6. Smaller

- **No address-bar autocomplete.** `en.wik` offers nothing. ⌘O has the URLs but
  it is a different surface with a different outcome. — **Left open**, and it is
  the largest thing remaining in this ticket: a dropdown under a 26 pt bar in a
  420 pt lane is a surface, not a setting. Carried to its own queue entry.
- **Find has no match count.** ⌘F works well — live filtering, Enter advances,
  ↑/↓, Escape dismisses, `no match` in orange — but with matches there is no
  `3/17`, so one hit and forty look the same. Noted in round 1 as deliberate,
  because `WKWebView.find` has no count and inventing one would be a lie; worth
  revisiting whether it can be counted honestly. — **Re-checked, still true.**
  `WKFindResult` carries `matchFound` and nothing else, so an honest count means
  counting in the page ourselves, in JavaScript, over a DOM the page is free to
  be mutating — a second search that can disagree with the one WebKit is
  highlighting. That is a real piece of work with a real way to be wrong, not a
  line in the find bar. Carried to its own queue entry with the autocomplete.
- **Long URLs clip with no ellipsis**, stopping mid-word. — **DONE.** The cause
  was not a missing setting but an ignored one: the cell's `lineBreakMode` *is*
  `.byTruncatingTail`, and an `NSTextField` ignores it the moment you hand it an
  `attributedStringValue`, taking line breaking from the string's own paragraph
  style instead — and a string with none is laid out as clipping. The address is
  drawn as three coloured runs, so it went through that path every time.
  `AddressField.clipped` now writes the truncation into the string, over every
  run, for all three things the slot says. `QuietChromeTests`.
- **No bookmarks.** The substitute is ⌘O recents plus pinned lanes. A defensible
  model change, and still a thing he uses eight of every day. — **Already its own
  queue entry** ("Bookmarks: a store, a way to add and reach them, then import
  from other browsers"). Not duplicated here.
- **⌘[ / ⌘] collide with Chrome/Safari's back/forward** in the fingers. ⌘← / ⌘→
  do work; the collision is deliberate and documented, but with two lanes open
  ⌘[ silently jumps lanes when he meant back. — **Belongs to "Every shortcut
  configurable, with the current ones as defaults."** Rebinding one pair by hand
  here would be the third place that decides what ⌘[ means, and that entry
  exists to make it one.
- **Right-click is the stock WebKit menu**: "Open Link in New Window" is the
  wrong noun for what happens, and there is no "open right of here". — **Left
  open, and blocked on API rather than on effort.** macOS `WKWebView` has no
  public context-menu hook — `contextMenuConfigurationForElement` is iOS only —
  so the only route is subclassing and overriding `willOpenMenu`, and the one
  web view this app does *not* construct is the adopted popup, which WebKit
  instantiates as a plain `WKWebView` from its own configuration. A menu that is
  right on most panes and stock on OAuth popups is worse than one that is stock
  everywhere. Note that item 4 has taken the pressure off it: the gesture the
  menu item existed to reach is now ⌘-click. Carried to its own queue entry.

## Disputed, re-checked — **no change made**

The critic reports **no zoom readout**; the builder reports a `125%` chip that
fades in whenever zoom is off 100%. The code is intact —
`WebChromeBar.setZoom` sets the glyph and fades the chip in, and
`WebPaneController` calls it both on init and in `setZoom`. Either the chip is
too quiet to find or the critic's zoom presses reached a terminal pane. Look
before changing anything.

> Looked, and the builder is right: `setZoom` computes the glyph, `isHidden`
> tracks whether the level is off 100%, and both call sites are there. Nothing
> was changed, because the one thing that would be wrong here is to "fix" a
> working readout on a report that has a second, likelier explanation — zoom
> presses landing on a terminal pane — sitting next to it. This needs a human
> with the app in front of them, pressing ⌘+ in a web pane, and that is exactly
> the verification a worker cannot do while the owner's instance holds the
> front. Left disputed.
